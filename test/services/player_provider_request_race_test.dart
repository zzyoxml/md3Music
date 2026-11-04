import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/player_state_repository.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playback_recovery_budget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter/widgets.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('在线音质解析前显示默认档位，降级后更新为实际音质', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final api = KugouApiClient();
    await api.clearCookies();
    await api.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = api.dio.httpClientAdapter;
    final adapter = _SuccessfulPlaybackRecoveryAdapter(holdPlaybackUrl: true);
    api.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady;
      player.setAudioQuality(AudioQuality.hires);
      final play = player.playSong(Song(
        id: 'quality-label-target', title: 'Quality Target', artist: 'Artist',
        album: 'Album', duration: const Duration(minutes: 3), isOnline: true,
      ));
      await adapter.firstPlaybackUrlRequested.future.timeout(const Duration(seconds: 2));
      expect(player.currentQualityLabel, 'Hi-Res');
      adapter.releasePlaybackUrl();
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await play;
      expect(player.currentQualityLabel, '标准音质');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      api.dio.httpClientAdapter = originalAdapter;
      uninstallFakeSecureStorage();
    }
  });

  test('记忆播放关闭清理尚未完成时重新开启，最终保留最后一次设置', () async {
    SharedPreferences.setMockInitialValues({});
    final clearEntered = Completer<void>();
    final clearRelease = Completer<void>();
    final stateRepository = PlayerStateRepository(
      beforeWrite: (step) async {
        if (step == 'clear.current_song' && !clearEntered.isCompleted) {
          clearEntered.complete();
          await clearRelease.future;
        }
      },
    );
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider(stateRepository: stateRepository);
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));

      final disabling = player.setRestoreMemoryEnabled(false);
      await clearEntered.future.timeout(const Duration(seconds: 2));
      final enabling = player.setRestoreMemoryEnabled(true);
      clearRelease.complete();
      await Future.wait([disabling, enabling]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings_restore_memory'), isTrue);
    } finally {
      if (!clearRelease.isCompleted) clearRelease.complete();
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('自动恢复达到三次预算后暂停会拦截迟到成功且不再启动第四次', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _FailRecoveryThenHoldSuccessAdapter();
    apiClient.dio.httpClientAdapter = adapter;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const connectivityMethodChannel = services.MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEventChannel = services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(connectivityMethodChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    messenger.setMockStreamHandler(
      connectivityEventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final recoveryBudget = PlaybackRecoveryBudget(
      backoff: [Duration.zero, Duration.zero, Duration.zero],
    );
    late final PlayerProvider player;
    try {
      player = PlayerProvider(failedRecoveryBudget: recoveryBudget);
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'recovery-budget-target',
        title: 'Recovery Budget Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/expired-budget.mp3',
        isOnline: true,
      );
      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      await Future<void>.delayed(Duration.zero);
      expect(player.resolveError, '播放失败，请重试');

      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await adapter.heldSuccessRequested.future.timeout(
        const Duration(seconds: 5),
      );
      expect(recoveryBudget.attempts, 3);
      expect(adapter.playbackUrlRequestCount, 7);

      await player.pause();
      adapter.releaseSuccess();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(player.isPlaying, isFalse);
      expect(player.currentSong?.id, song.id);
      expect(audio.playCommandCount, 1);
      expect(adapter.playbackUrlRequestCount, 7);
      expect(recoveryBudget.tryConsume(song.id), isFalse);
    } finally {
      adapter.releaseSuccess();
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      messenger.setMockMethodCallHandler(connectivityMethodChannel, null);
      messenger.setMockStreamHandler(connectivityEventChannel, null);
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('后台三次自动恢复均失败后前后台切换不会重开预算或发起第四次请求', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _CountingFailureAdapter();
    apiClient.dio.httpClientAdapter = adapter;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const connectivityMethodChannel = services.MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEventChannel = services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(connectivityMethodChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    messenger.setMockStreamHandler(
      connectivityEventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final recoveryBudget = PlaybackRecoveryBudget(
      backoff: [Duration.zero, Duration.zero, Duration.zero],
    );
    late final PlayerProvider player;
    try {
      player = PlayerProvider(failedRecoveryBudget: recoveryBudget);
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'recovery-exhausted-target',
        title: 'Recovery Exhausted Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/expired-exhausted.mp3',
        isOnline: true,
      );
      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      await Future<void>.delayed(Duration.zero);

      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await adapter.ninePlaybackUrlRequests.future.timeout(
        const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(recoveryBudget.attempts, 3);
      expect(adapter.playbackUrlRequestCount, 9);
      expect(player.resolveError, '播放失败，请重试');
      expect(player.currentSong?.id, song.id);
      expect(audio.playCommandCount, 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adapter.playbackUrlRequestCount, 9);

      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(recoveryBudget.attempts, 3);
      expect(adapter.playbackUrlRequestCount, 9);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      messenger.setMockMethodCallHandler(connectivityMethodChannel, null);
      messenger.setMockStreamHandler(connectivityEventChannel, null);
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('手动点播接管后台恢复后，旧恢复回包不能覆盖新播放源', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _HoldFirstRecoveryUrlAdapter();
    apiClient.dio.httpClientAdapter = adapter;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const connectivityMethodChannel = services.MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEventChannel = services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(connectivityMethodChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    messenger.setMockStreamHandler(
      connectivityEventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final recoveryBudget = PlaybackRecoveryBudget(
      backoff: [Duration.zero, const Duration(seconds: 60)],
    );
    late final PlayerProvider player;
    try {
      player = PlayerProvider(failedRecoveryBudget: recoveryBudget);
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'manual-takes-over-recovery',
        title: 'Manual Takes Over Recovery',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/initial.mp3',
        isOnline: true,
      );
      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      await Future<void>.delayed(Duration.zero);

      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await adapter.heldRecoveryRequested.future.timeout(
        const Duration(seconds: 3),
      );
      expect(recoveryBudget.attempts, 1);

      final manualPlay = player.playSong(song.copyWith(clearUrl: true));
      await audio.waitForPlaylistLoads(2);
      await audio.completeSourceLoad(1);
      await manualPlay;
      expect(player.currentSong?.url, adapter.manualRecoveryUrl);
      expect(audio.playCommandCount, 2);

      adapter.releaseHeldRecovery();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(player.currentSong?.id, song.id);
      expect(player.currentSong?.url, adapter.manualRecoveryUrl);
      expect(player.resolveError, isNull);
      expect(audio.playlistLoads, hasLength(2));
      expect(audio.playCommandCount, 2);
      expect(adapter.playbackUrlRequestCount, 2);
    } finally {
      adapter.releaseHeldRecovery();
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      messenger.setMockMethodCallHandler(connectivityMethodChannel, null);
      messenger.setMockStreamHandler(connectivityEventChannel, null);
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('鉴权、付费和本地解码失败不会启动在线自动恢复', () async {
    SharedPreferences.setMockInitialValues({'settings_restore_memory': false});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _CountingFailureAdapter();
    apiClient.dio.httpClientAdapter = adapter;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const connectivityMethodChannel = services.MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEventChannel = services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(connectivityMethodChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    messenger.setMockStreamHandler(
      connectivityEventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
    KugouApiClient.markServerReady();

    final cases = <({String name, Song song, bool loggedIn})>[
      (
        name: 'authentication',
        song: Song(
          id: 'auth-recovery-gate',
          title: 'Auth Recovery Gate',
          artist: 'Artist',
          album: 'Album',
          duration: const Duration(minutes: 3),
          url: 'https://media.example/auth-gate.mp3',
          isOnline: true,
        ),
        loggedIn: false,
      ),
      (
        name: 'paid-content',
        song: Song(
          id: 'paid-recovery-gate',
          title: 'Paid Recovery Gate',
          artist: 'Artist',
          album: 'Album',
          duration: const Duration(minutes: 3),
          url: 'https://media.example/paid-gate.mp3',
          isOnline: true,
          isLongAudio: true,
        ),
        loggedIn: true,
      ),
      (
        name: 'local-decode',
        song: Song(
          id: 'local-recovery-gate',
          title: 'Local Recovery Gate',
          artist: 'Artist',
          album: 'Album',
          duration: const Duration(minutes: 3),
          localPath: '/music/local-recovery-gate.flac',
          isOnline: false,
        ),
        loggedIn: true,
      ),
    ];

    try {
      for (final scenario in cases) {
        if (scenario.loggedIn) {
          await apiClient.setLoginCookies('fixture-token', 'fixture-user');
        } else {
          await apiClient.clearCookies();
        }
        final audio = ControlledAudioService();
        AudioServiceLoader.setTestOverride(() async => audio);
        final budget = PlaybackRecoveryBudget(backoff: [Duration.zero]);
        final player = PlayerProvider(failedRecoveryBudget: budget);
        try {
          await player.audioReady.timeout(const Duration(seconds: 10));
          final initialPlay = player.playPlaylist([scenario.song], 0);
          await audio.waitForPlaylistLoads(1);
          await audio.completeSourceLoad(0);
          await initialPlay;
          audio.emitPlaying(true);
          await Future<void>.delayed(Duration.zero);
          audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
          await Future<void>.delayed(Duration.zero);

          player.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(const Duration(milliseconds: 30));

          expect(player.resolveError, '播放失败，请重试', reason: scenario.name);
          expect(budget.attempts, 0, reason: scenario.name);
          expect(adapter.playbackUrlRequestCount, 0, reason: scenario.name);
          expect(player.currentSong?.id, scenario.song.id);
          expect(audio.playCommandCount, 1);
        } finally {
          player.dispose();
          await audio.dispose();
          AudioServiceLoader.setTestOverride(null);
        }
      }
    } finally {
      apiClient.dio.httpClientAdapter = originalAdapter;
      messenger.setMockMethodCallHandler(connectivityMethodChannel, null);
      messenger.setMockStreamHandler(connectivityEventChannel, null);
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('旧歌曲装载晚返回时不派发播放命令覆盖最新点播', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final stateRepository = PlayerStateRepository();
    final player = PlayerProvider(stateRepository: stateRepository);
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final firstSong = Song(
        id: 'first',
        title: 'First',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/first.mp3',
        isOnline: true,
      );
      final latestSong = Song(
        id: 'latest',
        title: 'Latest',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/latest.mp3',
        isOnline: true,
      );

      final firstRequest = player.playSong(firstSong);
      await audio.waitForPlaylistLoads(1);
      final latestRequest = player.playSong(latestSong);
      await audio.waitForPlaylistLoads(2);

      audio.playlistLoads[0].complete();
      await firstRequest;
      expect(audio.playCommandCount, 0);
      expect(player.currentSong?.id, 'latest');

      audio.playlistLoads[1].complete();
      await latestRequest;
      expect(audio.playCommandCount, 1);
      expect(player.currentSong?.id, 'latest');
    } finally {
      // dispose会再排入一次游标保存；先排空播放过程中的写入，再等待dispose写入，
      // 避免下一条用例重置SharedPreferences fake时与旧Provider写入交叠。
      await player.flushPersistence();
      player.dispose();
      await stateRepository.flush();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('暂停后恢复会重载被取消的音源，不靠旧装载补发起播', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'resume-target',
        title: 'Resume Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/resume.mp3',
        isOnline: true,
      );

      final oldRequest = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await player.pause();
      final resumeRequest = player.resume();
      await audio.waitForPlaylistLoads(2);

      await audio.completeSourceLoad(0);
      await oldRequest;
      expect(audio.playCommandCount, 0);

      await audio.completeSourceLoad(1);
      await resumeRequest;
      expect(audio.playCommandCount, 1);
      expect(player.currentSong?.id, 'resume-target');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('手动重试保留当前队列项，且重复点按只启动一次装载', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'local-retry',
        title: 'Local Retry',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        localPath: '/music/local-retry.flac',
      );

      final firstAttempt = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      audio.playlistLoads[0].completeError(StateError('decode failed'));
      await firstAttempt;
      expect(player.resolveError, '播放失败，请重试');

      final retry = player.retryCurrentPlayback();
      await audio.waitForPlaylistLoads(2);
      await player.retryCurrentPlayback();
      expect(audio.playlistLoads, hasLength(2));
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);

      await audio.completeSourceLoad(1);
      await retry;
      expect(audio.playCommandCount, 1);
      expect(player.resolveError, isNull);
      expect(player.isManualRetryInFlight, isFalse);
      expect(player.currentSong?.id, song.id);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('音源总截止后保留当前曲目，迟到装载不能抢占重试', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider(
      audioSourceLoadTimeout: const Duration(milliseconds: 15),
    );
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'load-deadline',
        title: 'Load Deadline',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        localPath: '/music/load-deadline.flac',
      );

      final firstAttempt = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await firstAttempt.timeout(const Duration(seconds: 1));
      expect(player.resolveError, '播放失败，请重试');
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);
      expect(player.isPlaybackNotReady, isTrue);
      expect(audio.playCommandCount, 0);

      final retry = player.retryCurrentPlayback();
      await audio.waitForPlaylistLoads(2);
      audio.playlistLoads[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(audio.playCommandCount, 0);
      expect(player.currentSong?.id, song.id);

      await audio.completeSourceLoad(1);
      await retry;
      expect(audio.playCommandCount, 1);
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('失败后用户明确暂停抑制自动恢复，新播放意图仍可起播', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _CountingFailureAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    final serverGeneration = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(serverGeneration);

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'pause-after-error',
        title: 'Pause After Error',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/pause-after-error.mp3',
        isOnline: true,
      );

      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      await Future<void>.delayed(Duration.zero);
      expect(player.resolveError, '播放失败，请重试');
      expect(player.isPlaying, isFalse);

      await player.pause();
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(adapter.playbackUrlRequestCount, 0);
      expect(player.isPlaying, isFalse);
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);

      final manualPlay = player.playSong(song);
      await audio.waitForPlaylistLoads(2);
      await audio.completeSourceLoad(1);
      await manualPlay;
      expect(audio.playCommandCount, 2);
      expect(player.currentSong?.id, song.id);
      expect(adapter.playbackUrlRequestCount, 0);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('断网恢复到同类Wi-Fi时先更新连通状态再启动唯一恢复', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _SuccessfulPlaybackRecoveryAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MockStreamHandlerEventSink? connectivityEvents;
    final connectivityListenerStarted = Completer<void>();
    const connectivityMethodChannel = services.MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEventChannel = services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(connectivityMethodChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    messenger.setMockStreamHandler(
      connectivityEventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          connectivityEvents = events;
          if (!connectivityListenerStarted.isCompleted) {
            connectivityListenerStarted.complete();
          }
          events.success(<String>['wifi']);
        },
      ),
    );
    final disconnectedEventSeen = Completer<void>();
    final reconnectedEventSeen = Completer<void>();
    final connectivityProbe = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (results.contains(ConnectivityResult.none) &&
          !disconnectedEventSeen.isCompleted) {
        disconnectedEventSeen.complete();
      } else if (results.contains(ConnectivityResult.wifi) &&
          disconnectedEventSeen.isCompleted &&
          !reconnectedEventSeen.isCompleted) {
        reconnectedEventSeen.complete();
      }
    });
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      await connectivityListenerStarted.future.timeout(
        const Duration(seconds: 2),
      );

      final song = Song(
        id: 'network-recovery-target',
        title: 'Network Recovery Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/network-recovery.mp3',
        isOnline: true,
      );
      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      audio.emitPosition(const Duration(seconds: 85));
      await Future<void>.delayed(Duration.zero);
      // Media3 在 Source error 到达 Dart 前可能已把 position 重置为 0。
      audio.emitPosition(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      await Future<void>.delayed(Duration.zero);
      expect(player.resolveError, '播放失败，请重试');

      connectivityEvents!.success(<String>['none']);
      await disconnectedEventSeen.future.timeout(
        const Duration(milliseconds: 200),
      );
      connectivityEvents!.success(<String>['wifi']);
      await reconnectedEventSeen.future.timeout(
        const Duration(milliseconds: 400),
      );

      await adapter.firstPlaybackUrlRequested.future.timeout(
        const Duration(seconds: 2),
      );
      // 网络恢复任务已经进入解析时，前台恢复必须并入同一单飞任务。
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await audio.waitForPlaylistLoads(2);
      expect(audio.sourceInitialPositions[1], const Duration(seconds: 85));
      await audio.completeSourceLoad(1);
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);

      expect(adapter.playbackUrlRequestCount, 1);
      expect(player.currentSong?.id, song.id);
      expect(player.resolveError, isNull);
      expect(player.isPlaying, isTrue);
      expect(audio.playCommandCount, 2);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      messenger.setMockMethodCallHandler(connectivityMethodChannel, null);
      messenger.setMockStreamHandler(connectivityEventChannel, null);
      await connectivityProbe.cancel();
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('CDN换源装载期间用户暂停后，迟到的原生自动续播会被再次暂停', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _SuccessfulPlaybackRecoveryAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'cdn-stall-pause-race',
        title: 'CDN Stall Pause Race',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/cdn-stall-pause-race.mp3',
        isOnline: true,
      );
      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);

      // 首次 setAudioSource 后的 3 秒保护窗内不会运行 CDN 看门狗。
      await Future<void>.delayed(const Duration(milliseconds: 3100));
      player.debugExpireRateCheckGraceForTest();
      audio.autoResumeAfterLoad = true;
      audio.emitPosition(const Duration(seconds: 60));
      await adapter.firstPlaybackUrlRequested.future.timeout(
        const Duration(seconds: 3),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 第二个速率采样只前进100ms，触发使用预取URL的CDN换源装载。
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      audio.emitPosition(const Duration(seconds: 60, milliseconds: 100));
      await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 3));

      await player.pause();
      expect(audio.pauseCommandCount, 1);
      expect(audio.playCommandCount, 1);

      // 模拟原生prepare在旧playWhenReady下收尾并短暂恢复；过期加载必须补发pause。
      await audio.completeSourceLoad(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(audio.pauseCommandCount, 2);
      expect(audio.playing, isFalse);
      expect(player.isPlaying, isFalse);
      expect(audio.playCommandCount, 1);
      expect(player.currentSong?.id, song.id);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('后台退避启动恢复后连网和回前台事件不会创建第二条恢复', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _SuccessfulPlaybackRecoveryAdapter(holdPlaybackUrl: true);
    apiClient.dio.httpClientAdapter = adapter;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MockStreamHandlerEventSink? connectivityEvents;
    final connectivityListenerStarted = Completer<void>();
    final disconnectedEventSeen = Completer<void>();
    final reconnectedEventSeen = Completer<void>();
    const connectivityMethodChannel = services.MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEventChannel = services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(connectivityMethodChannel, (call) async {
      if (call.method == 'check') return <String>['wifi'];
      return null;
    });
    messenger.setMockStreamHandler(
      connectivityEventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          connectivityEvents = events;
          if (!connectivityListenerStarted.isCompleted) {
            connectivityListenerStarted.complete();
          }
          events.success(<String>['wifi']);
        },
      ),
    );
    final connectivityProbe = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (results.contains(ConnectivityResult.none) &&
          !disconnectedEventSeen.isCompleted) {
        disconnectedEventSeen.complete();
      } else if (results.contains(ConnectivityResult.wifi) &&
          disconnectedEventSeen.isCompleted &&
          !reconnectedEventSeen.isCompleted) {
        reconnectedEventSeen.complete();
      }
    });
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final recoveryBudget = PlaybackRecoveryBudget(
      backoff: [
        const Duration(milliseconds: 80),
        const Duration(seconds: 60),
        const Duration(seconds: 120),
      ],
    );
    late final PlayerProvider player;
    try {
      player = PlayerProvider(failedRecoveryBudget: recoveryBudget);
      await player.audioReady.timeout(const Duration(seconds: 10));
      await connectivityListenerStarted.future.timeout(
        const Duration(seconds: 2),
      );

      final song = Song(
        id: 'background-recovery-target',
        title: 'Background Recovery Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/expired-background.mp3',
        isOnline: true,
      );
      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      await Future<void>.delayed(Duration.zero);
      expect(player.resolveError, '播放失败，请重试');

      // 后台失败会按注入的短退避启动受控URL请求，并保持恢复flight在途。
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await adapter.firstPlaybackUrlRequested.future.timeout(
        const Duration(seconds: 2),
      );
      expect(recoveryBudget.attempts, 1);

      connectivityEvents!.success(<String>['none']);
      await disconnectedEventSeen.future.timeout(const Duration(seconds: 2));
      connectivityEvents!.success(<String>['wifi']);
      await reconnectedEventSeen.future.timeout(const Duration(seconds: 2));
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(adapter.playbackUrlRequestCount, 1);
      expect(player.currentSong?.id, song.id);

      adapter.releasePlaybackUrl();
      await audio.waitForPlaylistLoads(2);
      await audio.completeSourceLoad(1);
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);

      expect(adapter.playbackUrlRequestCount, 1);
      expect(player.resolveError, isNull);
      expect(player.currentSong?.id, song.id);
      expect(player.isPlaying, isTrue);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      messenger.setMockMethodCallHandler(connectivityMethodChannel, null);
      messenger.setMockStreamHandler(connectivityEventChannel, null);
      await connectivityProbe.cancel();
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('装载期错误事件不污染状态，当前曲播放期错误保留队列并标记可重试', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'runtime-error-target',
        title: 'Runtime Error Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        localPath: '/music/runtime-error-target.flac',
      );

      final load = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      audio.emitError(just_audio.PlayerException(2, 'loading failed', 0));
      expect(player.resolveError, isNull);

      await audio.completeSourceLoad(0);
      await load;
      audio.emitPlaying(true);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));

      expect(player.resolveError, '播放失败，请重试');
      expect(player.isPlaying, isFalse);
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);
      expect(audio.playCommandCount, 1);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('音源装载Future异常显示安全错误且可在当前歌曲上重试', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService()
      ..nextSetUrlError = StateError(
        'decoder failed: https://secret.invalid/signed',
      );
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'load-exception-target',
        title: 'Load Exception Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        localPath: '/music/load-exception-target.flac',
      );

      await player.playPlaylist([song], 0);

      expect(player.resolveError, '播放失败，请重试');
      expect(player.resolveErrorForDisplay, '播放失败，请重试');
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);
      expect(player.isPlaying, isFalse);
      expect(player.isPlaybackNotReady, isFalse);
      expect(audio.playCommandCount, 0);

      final retry = player.retryCurrentPlayback();
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 2));
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);
      await audio.completeSourceLoad(0);
      await retry;

      expect(player.resolveError, isNull);
      expect(audio.playCommandCount, 1);
      expect(player.currentSong?.id, song.id);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('Android确定性解码兼容错误不会自动重复请求播放URL', () async {
    SharedPreferences.setMockInitialValues({});
    final apiClient = KugouApiClient();
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _CountingFailureAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider(isAndroidForTest: true);
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'unsupported-decoder-target',
        title: 'Unsupported Decoder Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/song.flac',
        isOnline: true,
      );

      final load = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await load;
      audio.emitPlaying(true);
      audio.emitError(
        just_audio.PlayerException(
          4004,
          'decoder does not support format',
          0,
          androidExoType: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(player.resolveError, '播放失败，请重试');
      expect(player.currentSong?.id, song.id);
      expect(adapter.playbackUrlRequestCount, 0);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
    }
  });

  test('Android媒体源HTTP 404在装载阶段分类为资源缺失并停止自动重试', () async {
    SharedPreferences.setMockInitialValues({'settings_restore_memory': false});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _CountingFailureAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService()
      ..nextSetUrlError = just_audio.PlayerException(
        2004,
        'bad media response',
        0,
        httpStatusCode: 404,
      );
    AudioServiceLoader.setTestOverride(() async => audio);
    final budget = PlaybackRecoveryBudget(backoff: [Duration.zero]);
    late final PlayerProvider player;
    try {
      player = PlayerProvider(
        isAndroidForTest: true,
        failedRecoveryBudget: budget,
      );
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'missing-media-resource',
        title: 'Missing Media Resource',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/missing.mp3',
        isOnline: true,
      );

      await player.playPlaylist([song], 0);
      expect(player.resolveError, '播放失败，请重试');

      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(player.currentSong?.id, song.id);
      expect(budget.attempts, 0);
      expect(adapter.playbackUrlRequestCount, 0);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('显式flush后最新队列和游标可立即恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'flush-current-song',
        title: 'Flush Current Song',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        localPath: '/music/flush-current-song.flac',
      );
      final request = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await request;

      await player.flushPersistence();

      final saved = await PlayerStateRepository().restoreState();
      expect(saved?.currentSong.id, song.id);
      expect(saved?.playlist.map((item) => item.id), [song.id]);
      expect(saved?.currentIndex, 0);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('手动重试期间暂停会作废迟到的装载', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'local-retry-cancel',
        title: 'Local Retry Cancel',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        localPath: '/music/local-retry-cancel.flac',
      );

      final firstAttempt = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      audio.playlistLoads[0].completeError(StateError('decode failed'));
      await firstAttempt;
      expect(player.resolveError, '播放失败，请重试');

      final retry = player.retryCurrentPlayback();
      await audio.waitForPlaylistLoads(2);
      await player.pause();
      await audio.completeSourceLoad(1);
      await retry;

      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
      expect(player.isManualRetryInFlight, isFalse);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('seek拖动期间用户明确暂停后，松手不会再次恢复播放', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'seek-pause-target',
        title: 'Seek Pause Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/seek-pause.mp3',
        isOnline: true,
      );
      final playRequest = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await playRequest;

      final seekSession = player.beginSeekSession(wasPlaying: true);
      await player.pause();
      final commandsBeforeSeekEnd = audio.playCommandCount;

      await player.completeSeekSession(
        seekSession,
        const Duration(seconds: 42),
        forceNotify: true,
      );

      expect(audio.lastSeekPosition, const Duration(seconds: 42));
      expect(audio.playCommandCount, commandsBeforeSeekEnd);
      expect(audio.playing, isFalse);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('正常结束seek事务会先暂停、定位，再恢复原先正在播放的歌曲', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'seek-resume-target',
        title: 'Seek Resume Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/seek-resume.mp3',
        isOnline: true,
      );
      final playRequest = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await playRequest;

      final seekSession = player.beginSeekSession(wasPlaying: true);
      await player.completeSeekSession(
        seekSession,
        const Duration(seconds: 35),
      );

      expect(audio.lastSeekPosition, const Duration(seconds: 35));
      expect(audio.playCommandCount, 2);
      expect(audio.playing, isTrue);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('较早的pause在较新的resume之后完成时不会留下暂停态', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'pause-resume-order-target',
        title: 'Pause Resume Order Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/pause-resume-order.mp3',
        isOnline: true,
      );
      final playRequest = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await playRequest;

      audio.pauseCompleter = Completer<void>();
      audio.pauseStarted = Completer<void>();
      final pauseRequest = player.pause();
      await audio.pauseStarted!.future.timeout(const Duration(seconds: 2));
      await player.resume();
      expect(audio.playing, isTrue);

      audio.pauseCompleter!.complete();
      await pauseRequest;

      expect(audio.playing, isTrue);
      expect(audio.playCommandCount, 3);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('淡出中的pause被新resume接管后，不再压低活动播放器音量', () async {
    SharedPreferences.setMockInitialValues({
      'settings_pause_fade_enabled': true,
    });
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'fade-resume-target',
        title: 'Fade Resume Target',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/fade-resume.mp3',
        isOnline: true,
      );
      final playRequest = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await playRequest;

      final volumeChanged = Completer<void>();
      audio.player.volumeChanged = volumeChanged;
      final pauseRequest = player.pause();
      await volumeChanged.future.timeout(const Duration(seconds: 2));
      await player.resume();
      await pauseRequest;

      expect(audio.playing, isTrue);
      expect(audio.player.volume, closeTo(1, 0.001));
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}

class _CountingFailureAdapter implements HttpClientAdapter {
  final Completer<void> ninePlaybackUrlRequests = Completer<void>();
  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
      if (playbackUrlRequestCount >= 9 &&
          !ninePlaybackUrlRequests.isCompleted) {
        ninePlaybackUrlRequests.complete();
      }
    }
    return ResponseBody.fromString(
      '{}',
      503,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SuccessfulPlaybackRecoveryAdapter implements HttpClientAdapter {
  _SuccessfulPlaybackRecoveryAdapter({this.holdPlaybackUrl = false});

  final bool holdPlaybackUrl;
  final Completer<void> firstPlaybackUrlRequested = Completer<void>();
  final Completer<ResponseBody> _heldPlaybackUrl = Completer<ResponseBody>();
  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
      if (!firstPlaybackUrlRequested.isCompleted) {
        firstPlaybackUrlRequested.complete();
      }
      if (holdPlaybackUrl) return _heldPlaybackUrl.future;
      return ResponseBody.fromString(
        jsonEncode({
          'data': {
            'url': ['https://media.example/recovered.mp3'],
            'quality': '128',
          },
        }),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  void releasePlaybackUrl() {
    if (_heldPlaybackUrl.isCompleted) return;
    _heldPlaybackUrl.complete(
      ResponseBody.fromString(
        jsonEncode({
          'data': {
            'url': ['https://media.example/recovered.mp3'],
            'quality': '128',
          },
        }),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FailRecoveryThenHoldSuccessAdapter implements HttpClientAdapter {
  final Completer<void> heldSuccessRequested = Completer<void>();
  final Completer<ResponseBody> _heldSuccess = Completer<ResponseBody>();
  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
      if (playbackUrlRequestCount <= 6) {
        return ResponseBody.fromString(
          '{"error":"temporary"}',
          503,
          headers: const {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
      if (playbackUrlRequestCount == 7) {
        if (!heldSuccessRequested.isCompleted) {
          heldSuccessRequested.complete();
        }
        return _heldSuccess.future;
      }
      return ResponseBody.fromString(
        '{"error":"unexpected extra recovery"}',
        503,
        headers: const {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  void releaseSuccess() {
    if (_heldSuccess.isCompleted) return;
    _heldSuccess.complete(
      ResponseBody.fromString(
        jsonEncode({
          'data': {
            'url': ['https://media.example/late-recovery.mp3'],
            'quality': '128',
          },
        }),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

class _HoldFirstRecoveryUrlAdapter implements HttpClientAdapter {
  final manualRecoveryUrl = 'https://media.example/manual-recovered.mp3';

  final Completer<void> heldRecoveryRequested = Completer<void>();
  final Completer<ResponseBody> _heldRecovery = Completer<ResponseBody>();
  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
      if (playbackUrlRequestCount == 1) {
        heldRecoveryRequested.complete();
        return _heldRecovery.future;
      }
      return _responseFor('manual-recovered.mp3');
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  void releaseHeldRecovery() {
    if (_heldRecovery.isCompleted) return;
    _heldRecovery.complete(_responseFor('stale-background-recovery.mp3'));
  }

  ResponseBody _responseFor(String filename) => ResponseBody.fromString(
    jsonEncode({
      'data': {
        'url': ['https://media.example/$filename'],
        'quality': '128',
      },
    }),
    200,
    headers: const {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
