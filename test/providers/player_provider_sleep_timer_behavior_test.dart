import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 「定时结束后播完当前歌曲」在真实时间轴上的行为，外加倒计时到点一帧。
///
/// 用 `test()` 而非 `testWidgets()`：本组用例依赖真实时间（睡眠倒计时读的是
/// DateTime.now()，playback 完成还有 3s 的 URL 加载防误报守卫），fake async
/// 时钟推不动它们；改为真实 async zone 后 Timer 与 DateTime 都能正常前进。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortMp3 = Duration(seconds: 60);
  const guardWindow = Duration(seconds: 3);

  void installConnectivityMocks() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const services.MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockStreamHandler(
      const services.EventChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      ),
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
  }

  /// 装载两首歌并让 [startIndex] 进入可播状态。
  Future<void> startPlaylist(
    PlayerProvider player,
    ControlledAudioService audio, {
    int startIndex = 0,
  }) async {
    final play = player.playPlaylist(
      <Song>[
        Song(
          id: 'sleep-a',
          title: 'A',
          artist: 'Artist',
          album: 'Album',
          duration: shortMp3,
          url: 'https://media.example/a.mp3',
          isOnline: true,
        ),
        Song(
          id: 'sleep-b',
          title: 'B',
          artist: 'Artist',
          album: 'Album',
          duration: shortMp3,
          url: 'https://media.example/b.mp3',
          isOnline: true,
        ),
      ],
      startIndex,
    );
    await audio.waitForPlaylistLoads(1);
    await audio.completeSourceLoad(0);
    await play;
    audio.emitPlaying(true);
    await Future<void>.delayed(Duration.zero);
  }

  /// 勾选偏好 + 设 1s 定时并真实等到点，构造 endOfTrack 等待态。
  Future<void> armEndOfTrack(PlayerProvider player) async {
    player.setStopAfterCurrentTrack(true);
    player.setSleepTimer(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(player.sleepTimerMode, SleepTimerMode.endOfTrack);
  }

  test('到点且已勾选：不打断播放，进入等待当前曲播完的到点态', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      await startPlaylist(player, audio);
      audio.pauseCommandCount = 0;

      await armEndOfTrack(player);

      expect(audio.pauseCommandCount, 0, reason: '到点不应打断当前播放');
      expect(player.isSleepTimerActive, isTrue);
      expect(player.sleepTimerRemaining, isNull, reason: '等待态没有倒计时');
      expect(
        player.stopAfterTimerEnds,
        isTrue,
        reason: '偏好到点后保留，供下一次定时沿用',
      );
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('到点后：当前曲（非末曲）播完即暂停，不等队列末曲', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      await startPlaylist(player, audio);
      await armEndOfTrack(player);

      // 到点那一刻正在播的第一首（非末曲）自然播完 → 立即暂停并复位
      await Future<void>.delayed(guardWindow);
      player.debugFeedPositionForTest(shortMp3);
      audio.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(audio.pauseCommandCount, 1, reason: '当前曲播完即暂停，不等末曲');
      expect(player.sleepTimerMode, SleepTimerMode.off);
      expect(player.isSleepTimerActive, isFalse);
      expect(player.currentSong?.id, 'sleep-a', reason: '不应切到下一首');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('到点后：单曲循环下当前首播完即停，不重播', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      await startPlaylist(player, audio);

      // 不循环 → 列表循环 → 单曲循环
      await player.cyclePlayMode();
      await player.cyclePlayMode();
      expect(player.loopMode, AppLoopMode.one);

      await armEndOfTrack(player);
      await Future<void>.delayed(guardWindow);
      player.debugFeedPositionForTest(shortMp3);
      audio.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(audio.pauseCommandCount, 1, reason: '不应无休止重播');
      expect(player.sleepTimerMode, SleepTimerMode.off);
      expect(player.currentSong?.id, 'sleep-a', reason: '没有换歌');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('到点后：异常结束（远未满时长）不算播完，等待态保持挂载', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      // 直接从末曲开始，聚焦「异常结束不消费等待态」
      await startPlaylist(player, audio, startIndex: 1);
      await armEndOfTrack(player);

      await Future<void>.delayed(guardWindow);
      player.debugFeedPositionForTest(const Duration(seconds: 10));
      audio.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(audio.pauseCommandCount, 0, reason: '不应把故障当成播完而停播');
      expect(
        player.sleepTimerMode,
        SleepTimerMode.endOfTrack,
        reason: '本次未真正播完，等待态应保留',
      );
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('到点后取消勾选：撤销等待态，此后播完不再停止', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      await startPlaylist(player, audio, startIndex: 1);
      await armEndOfTrack(player);

      player.setStopAfterCurrentTrack(false);

      expect(player.sleepTimerMode, SleepTimerMode.off);
      expect(player.isSleepTimerActive, isFalse);

      // 撤销后当前曲播完走既有绕回逻辑，不暂停
      await Future<void>.delayed(guardWindow);
      player.debugFeedPositionForTest(shortMp3);
      audio.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(audio.pauseCommandCount, 0);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('到点且未勾选：维持既有行为，立即暂停', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));

      player.setSleepTimer(const Duration(seconds: 1));
      expect(player.sleepTimerMode, SleepTimerMode.countdown);
      await Future<void>.delayed(const Duration(milliseconds: 1300));

      expect(audio.pauseCommandCount, 1, reason: '未勾选时应到点立即暂停');
      expect(player.sleepTimerMode, SleepTimerMode.off);
      expect(player.isSleepTimerActive, isFalse);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}
