import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/dynamic_cover_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../support/controlled_audio_service.dart';

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextPlayerId = 1;
  int createCount = 0;
  int disposeCount = 0;
  bool failInitialization = false;
  final Set<int> pendingInitializationIds = {};
  double? failingVolume;
  bool? failingLooping;
  final List<double> volumeCalls = [];
  final List<bool> loopingCalls = [];
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Completer<void> firstDisposeCompleted = Completer<void>();

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextPlayerId++;
    createCount++;
    late final StreamController<VideoEvent> events;
    events = StreamController<VideoEvent>(
      onListen: () {
        if (pendingInitializationIds.contains(id)) return;
        if (failInitialization) {
          events.addError(
            services.PlatformException(
              code: 'injected-initialize-failure',
              message: 'injected initialization failure',
            ),
          );
          return;
        }
        events.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 10),
            size: const Size(320, 180),
          ),
        );
      },
    );
    _events[id] = events;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  void completeInitialization(int playerId) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(320, 180),
      ),
    );
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    loopingCalls.add(looping);
    if (looping == failingLooping) {
      throw StateError('injected setLooping failure');
    }
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    volumeCalls.add(volume);
    if (volume == failingVolume) {
      throw StateError('injected setVolume failure');
    }
  }

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async {
    disposeCount++;
    await _events.remove(playerId)?.close();
    if (!firstDisposeCompleted.isCompleted) {
      firstDisposeCompleted.complete();
    }
  }

  @override
  Widget buildView(int playerId) => const SizedBox.expand();
}

Future<void> _expectDynamicCoverInitializationFailure(
  WidgetTester tester, {
  required String songId,
  bool failInitialization = false,
  double? failingVolume,
  bool? failingLooping,
  required List<double> expectedVolumeCalls,
  required List<bool> expectedLoopingCalls,
}) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
        const services.EventChannel(
          'dev.fluttercommunity.plus/connectivity_status',
        ),
        MockStreamHandler.inline(
          onListen: (_, events) => events.success(<String>['wifi']),
        ),
      );
  final previousPlatform = VideoPlayerPlatform.instance;
  final platform = _FakeVideoPlayerPlatform()
    ..failInitialization = failInitialization
    ..failingVolume = failingVolume
    ..failingLooping = failingLooping;
  VideoPlayerPlatform.instance = platform;
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  DynamicCoverView.resolveLocalPath = (_) async => 'C:/fake/dynamic.mp4';
  PlayerProvider? player;
  try {
    await tester.runAsync(() async {
      player = PlayerProvider();
      await player!.audioReady.timeout(const Duration(seconds: 10));
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<PlayerProvider>.value(
        value: player!,
        child: MaterialApp(
          home: SizedBox(
            width: 120,
            height: 120,
            child: DynamicCoverView(
              song: Song(
                id: songId,
                title: songId,
                artist: 'Artist',
                album: 'Album',
                duration: const Duration(minutes: 1),
                url: 'https://audio.invalid/song.mp3',
                albumAudioId: 'dynamic-id',
                isOnline: true,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(platform.createCount, 1);
    expect(platform.volumeCalls, expectedVolumeCalls);
    expect(platform.loopingCalls, expectedLoopingCalls);
    expect(platform.disposeCount, 1);
    expect(platform.firstDisposeCompleted.isCompleted, isTrue);
    expect(find.byType(VideoPlayer), findsNothing);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    player?.dispose();
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
    DynamicCoverView.resolveLocalPath = null;
    VideoPlayerPlatform.instance = previousPlatform;
  }
}

void main() {
  // 回归背景：暂停状态下息屏再解锁，ExoPlayer 的渲染表面已失效而暂停的视频不会
  // 渲染新帧 → 留下黑屏盖住静态封面（表现为「没有兜底」）。策略是真正进入后台时
  // 释放视频层，回前台重建；这两条用例把策略钉住。
  group('shouldReleaseVideoOnLifecycle', () {
    test('真正进入后台 → 必须释放视频层', () {
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.paused), isTrue);
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.hidden), isTrue);
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.detached), isTrue);
    });

    test('前台与临时失焦（下拉通知栏 / 权限弹窗）→ 不释放，避免反复重建闪烁', () {
      expect(shouldReleaseVideoOnLifecycle(AppLifecycleState.resumed), isFalse);
      expect(
        shouldReleaseVideoOnLifecycle(AppLifecycleState.inactive),
        isFalse,
      );
    });
  });

  testWidgets('后台释放动态封面，回前台重新创建控制器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
    final previousPlatform = VideoPlayerPlatform.instance;
    final platform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    DynamicCoverView.resolveLocalPath = (_) async => 'C:/fake/dynamic.mp4';
    PlayerProvider? player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player!.audioReady.timeout(const Duration(seconds: 10));
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<PlayerProvider>.value(
          value: player!,
          child: const MaterialApp(
            home: SizedBox(
              width: 120,
              height: 120,
              child: DynamicCoverView(
                song: Song(
                  id: 'dynamic-cover-lifecycle',
                  title: 'Lifecycle',
                  artist: 'Artist',
                  album: 'Album',
                  duration: Duration(minutes: 1),
                  url: 'https://audio.invalid/song.mp3',
                  albumAudioId: 'dynamic-id',
                  isOnline: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(platform.createCount, 1);
      expect(platform.disposeCount, 0);
      expect(find.byType(VideoPlayer), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(platform.disposeCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(platform.disposeCount, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(platform.createCount, 2);
      expect(platform.disposeCount, 1);
      expect(find.byType(VideoPlayer), findsOneWidget);

      for (var cycle = 2; cycle <= 100; cycle++) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump();
        expect(platform.disposeCount, cycle);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump();
        expect(platform.createCount, cycle + 1);
        expect(platform.disposeCount, cycle);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player?.dispose();
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
      DynamicCoverView.resolveLocalPath = null;
      VideoPlayerPlatform.instance = previousPlatform;
    }
  });

  testWidgets('静音设置失败后释放临时控制器并保留静态封面', (tester) async {
    await _expectDynamicCoverInitializationFailure(
      tester,
      songId: 'dynamic-cover-volume-failure',
      failingVolume: 0,
      expectedVolumeCalls: [1, 0],
      expectedLoopingCalls: [false],
    );
  });

  testWidgets('循环设置失败后释放临时控制器并保留静态封面', (tester) async {
    await _expectDynamicCoverInitializationFailure(
      tester,
      songId: 'dynamic-cover-looping-failure',
      failingLooping: true,
      expectedVolumeCalls: [1, 0],
      expectedLoopingCalls: [false, true],
    );
  });

  testWidgets('初始化事件失败后释放临时控制器并保留静态封面', (tester) async {
    await _expectDynamicCoverInitializationFailure(
      tester,
      songId: 'dynamic-cover-initialize-failure',
      failInitialization: true,
      expectedVolumeCalls: [],
      expectedLoopingCalls: [],
    );
  });

  testWidgets('100轮初始化失败与切歌、后台前台交替后均释放控制器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
    final previousPlatform = VideoPlayerPlatform.instance;
    final platform = _FakeVideoPlayerPlatform()..failInitialization = true;
    VideoPlayerPlatform.instance = platform;
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    DynamicCoverView.resolveLocalPath = (_) async => 'C:/fake/dynamic.mp4';
    PlayerProvider? player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player!.audioReady.timeout(const Duration(seconds: 10));
      });

      Future<void> showCover(int cycle) => tester.pumpWidget(
        ChangeNotifierProvider<PlayerProvider>.value(
          value: player!,
          child: MaterialApp(
            home: SizedBox(
              width: 120,
              height: 120,
              child: DynamicCoverView(
                key: ValueKey(cycle),
                song: Song(
                  id: 'dynamic-failure-$cycle',
                  title: 'Failure $cycle',
                  artist: 'Artist',
                  album: 'Album',
                  duration: const Duration(minutes: 1),
                  url: 'https://audio.invalid/song.mp3',
                  albumAudioId: 'dynamic-$cycle',
                  isOnline: true,
                ),
              ),
            ),
          ),
        ),
      );

      for (var cycle = 1; cycle <= 100; cycle++) {
        final createsBeforeCycle = platform.createCount;
        await showCover(cycle);
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(find.byType(VideoPlayer), findsNothing);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(platform.createCount, greaterThan(createsBeforeCycle));
        expect(platform.disposeCount, platform.createCount);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player?.dispose();
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
      DynamicCoverView.resolveLocalPath = null;
      VideoPlayerPlatform.instance = previousPlatform;
    }
  });

  testWidgets('切歌时旧封面初始化迟到会释放旧控制器并解析新歌曲', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
    final previousPlatform = VideoPlayerPlatform.instance;
    final platform = _FakeVideoPlayerPlatform()
      ..pendingInitializationIds.add(1);
    VideoPlayerPlatform.instance = platform;
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    DynamicCoverView.resolveLocalPath = (_) async => 'C:/fake/dynamic.mp4';
    PlayerProvider? player;

    Song song(String id) => Song(
      id: id,
      title: id,
      artist: 'Artist',
      album: 'Album',
      duration: const Duration(minutes: 1),
      url: 'https://audio.invalid/song.mp3',
      albumAudioId: id,
      isOnline: true,
    );

    Widget host(Song current) => ChangeNotifierProvider<PlayerProvider>.value(
      value: player!,
      child: MaterialApp(
        home: SizedBox(
          width: 120,
          height: 120,
          child: DynamicCoverView(
            key: const ValueKey('same-cover-state'),
            song: current,
          ),
        ),
      ),
    );

    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player!.audioReady.timeout(const Duration(seconds: 10));
      });
      await tester.pumpWidget(host(song('old-song')));
      await tester.pumpAndSettle();
      expect(platform.createCount, 1);
      expect(platform.disposeCount, 0);

      // 同一个State切到新歌曲时，旧initialize仍挂起；完成旧事件后必须丢弃旧源，
      // 再解析当前歌曲，不能把旧封面接纳为新歌的动态封面。
      await tester.pumpWidget(host(song('new-song')));
      await tester.pumpAndSettle();
      expect(platform.createCount, 1);
      platform.completeInitialization(1);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(platform.createCount, 2);
      expect(platform.disposeCount, 1);
      expect(find.byType(VideoPlayer), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.disposeCount, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player?.dispose();
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
      DynamicCoverView.resolveLocalPath = null;
      VideoPlayerPlatform.instance = previousPlatform;
    }
  });
}
