import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/modules/player/am_transport_controls.dart';
import 'package:md3music/modules/player/full_player.dart';
import 'package:md3music/modules/player/full_player_am.dart';
import 'package:md3music/modules/player/lyrics_view.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/player_tab_strip.dart';
import 'package:md3music/widgets/md3e_transport_row.dart';
import 'package:md3music/widgets/playback_status_feedback.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/dynamic_cover_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../support/controlled_audio_service.dart';

Song _song({
  String? artworkUri,
  String id = 'narrow-page-target',
  String? albumAudioId,
}) => Song(
  id: id,
  title: id == 'narrow-page-target'
      ? 'Narrow Layout Playback Target'
      : 'Narrow Layout Playback Target $id',
  artist: 'Layout Artist',
  album: 'Layout Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track.mp3',
  artworkUri: artworkUri,
  albumAudioId: albumAudioId,
  isOnline: true,
);

class _FailingVideoPlayerPlatform extends VideoPlayerPlatform {
  int createCount = 0;
  int disposeCount = 0;
  int _nextId = 0;
  final Map<int, StreamController<VideoEvent>> _events = {};

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    createCount++;
    late final StreamController<VideoEvent> events;
    events = StreamController<VideoEvent>(
      onListen: () => events.addError(
        services.PlatformException(
          code: 'injected-cover-init-failure',
          message: 'injected dynamic cover initialization failure',
        ),
      ),
    );
    _events[id] = events;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

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
  }

  @override
  Widget buildView(int playerId) => const SizedBox.expand();
}

class _ThrowingLyricProvider extends KugouProvider {
  _ThrowingLyricProvider() : super(registerDeviceOnStart: false);

  int requestCount = 0;

  @override
  Future<KugouLyric?> getLyric(
    String hash, {
    String? songName,
    String fmt = 'lrc',
    String? localIdentity,
    bool forceRefresh = false,
    void Function(KugouLyric lyric)? onProgress,
  }) async {
    requestCount++;
    throw StateError('simulated lyric transport failure');
  }
}

class _DelayedLyricProvider extends KugouProvider {
  _DelayedLyricProvider() : super(registerDeviceOnStart: false);
  final requests = <Completer<KugouLyric?>>[];
  final progressCallbacks = <void Function(KugouLyric)?>[];
  @override
  Future<KugouLyric?> getLyric(String hash, {String? songName,
    String fmt = 'lrc', String? localIdentity, bool forceRefresh = false,
    void Function(KugouLyric lyric)? onProgress}) {
    final request = Completer<KugouLyric?>();
    requests.add(request);
    progressCallbacks.add(onProgress);
    return request.future;
  }
}

class _FailingArtworkCacheManager implements BaseCacheManager {
  int requestCount = 0;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    requestCount++;
    return Stream<FileResponse>.error(StateError('simulated artwork failure'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _mockPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    const services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    ),
    MockStreamHandler.inline(
      onListen: (_, events) => events.success(<String>['wifi']),
    ),
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('com.md3music.md3music/home_widget'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    services.SystemChannels.platform,
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' => Directory.systemTemp.path,
      _ => null,
    },
  );
}

Widget _host(PlayerProvider player, KugouProvider kugou, Widget page) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<KugouProvider>.value(value: kugou),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(
          create: (_) => FavoritesProvider(syncOnStart: false),
        ),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
        ChangeNotifierProvider(create: (_) => ListenTogetherProvider()),
      ],
      child: MaterialApp(home: page),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, page) in <(String, Widget Function())>[
    ('MD3', () => const FullPlayer(dockMode: true)),
    ('AM', () => const AmStyleFullPlayer(dockMode: true)),
  ]) {
    for (final (layout, viewport, textScale) in <(String, Size, double)>[
      ('窄屏2倍字', const Size(320, 640), 2),
      ('常规屏1倍字', const Size(360, 800), 1),
      ('横屏1点3倍字', const Size(800, 360), 1.3),
    ]) {
      testWidgets('$name $layout 失败提示与传输控件可见且无溢出', (tester) async {
        final originalTabIndex = playerTabIndex.value;
        addTearDown(() => playerTabIndex.value = originalTabIndex);
        final originalPhysicalSize = tester.view.physicalSize;
        final originalDevicePixelRatio = tester.view.devicePixelRatio;
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        SharedPreferences.setMockInitialValues({});
        _mockPlatformChannels();
        KugouProvider.restoreLyric = (_) async => const KugouLyric(
          content: '[00:00.00]test lyric',
          decodedContent: '[00:00.00]test lyric',
        );
        final audio = ControlledAudioService();
        AudioServiceLoader.setTestOverride(() async => audio);
        PlayerProvider? player;
        final kugou = KugouProvider(registerDeviceOnStart: false);
        try {
          await tester.runAsync(() async {
            final activePlayer = PlayerProvider();
            player = activePlayer;
            await activePlayer.audioReady.timeout(const Duration(seconds: 10));
            final load = activePlayer.playPlaylist([_song()], 0);
            await audio.waitForPlaylistLoads(1);
            await audio.completeSourceLoad(0);
            await load;
            audio.emitPlaying(true);
            audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
          });

          await tester.pumpWidget(
            _host(
              player!,
              kugou,
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: viewport.width > viewport.height
                      ? (name == 'MD3'
                            ? const FullPlayer(dockMode: false)
                            : const AmStyleFullPlayer(dockMode: false))
                      : page(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 100));

          expect(tester.takeException(), isNull);
          // 宽屏（横屏）默认档：控制带常驻右栏底部，尺/传输/音量与歌词同屏，
          // **不用切页**就能看到失败提示与传输控件（切回「横屏控制面板独立页」
          // 开关才走独立页签，见 full_player_landscape_controls_test 的 detached 组）。
          expect(tester.takeException(), isNull);
          expect(find.text('播放失败，请重试'), findsOneWidget);
          final controls = name == 'MD3'
              ? find.byType(MD3ETransportRow)
              : find.byType(AMTransportControls);
          expect(controls, findsOneWidget);
          expect(find.byType(PlaybackStatusFeedback), findsOneWidget);
          final semantics = tester.ensureSemantics();
          final pauseButton = name == 'MD3'
              ? find.bySemanticsLabel('暂停')
              : find.byTooltip('暂停');
          expect(pauseButton, findsOneWidget);
          final previousButton = name == 'MD3'
              ? find.bySemanticsLabel('上一首')
              : find.byTooltip('上一首');
          final nextButton = name == 'MD3'
              ? find.bySemanticsLabel('下一首')
              : find.byTooltip('下一首');
          expect(previousButton, findsOneWidget);
          expect(nextButton, findsOneWidget);
          for (final button in <Finder>[
            previousButton,
            pauseButton,
            nextButton,
          ]) {
            expect(
              tester
                  .getSemantics(button)
                  .getSemanticsData()
                  .hasAction(SemanticsAction.tap),
              isTrue,
            );
          }
          for (final (label, target) in <(String, Finder)>[
            ('播放状态提示', find.byType(PlaybackStatusFeedback)),
            ('切歌控制区', controls),
          ]) {
            final bounds = tester.getRect(target);
            expect(bounds.left, greaterThanOrEqualTo(0), reason: label);
            expect(
              bounds.right,
              lessThanOrEqualTo(viewport.width),
              reason: label,
            );
            expect(
              bounds.bottom,
              lessThanOrEqualTo(viewport.height),
              reason: label,
            );
          }
          semantics.dispose();

          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          player?.dispose();
          kugou.dispose();
          await tester.runAsync(() => HistoryRepository().flush());
          await audio.dispose();
          AudioServiceLoader.setTestOverride(null);
          KugouProvider.restoreLyric = null;
          tester.view.physicalSize = originalPhysicalSize;
          tester.view.devicePixelRatio = originalDevicePixelRatio;
        }
      });
    }
  }

  for (final (name, page) in <(String, Widget Function())>[
    ('MD3', () => const FullPlayer(dockMode: true)),
    ('AM', () => const AmStyleFullPlayer(dockMode: true)),
  ]) {
    testWidgets('$name 歌词请求异常后播放页仍可操作', (tester) async {
      final originalPhysicalSize = tester.view.physicalSize;
      final originalDevicePixelRatio = tester.view.devicePixelRatio;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      SharedPreferences.setMockInitialValues({});
      _mockPlatformChannels();
      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      KugouProvider.restoreLyric = null;
      final kugou = _ThrowingLyricProvider();
      PlayerProvider? player;
      try {
        await tester.runAsync(() async {
          final activePlayer = PlayerProvider();
          player = activePlayer;
          await activePlayer.audioReady.timeout(const Duration(seconds: 10));
          final load = activePlayer.playPlaylist([_song()], 0);
          await audio.waitForPlaylistLoads(1);
          await audio.completeSourceLoad(0);
          await load;
          audio.emitPlaying(true);
        });

        await tester.pumpWidget(_host(player!, kugou, page()));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(kugou.requestCount, greaterThan(0));
        expect(tester.takeException(), isNull);

        final controls = name == 'MD3'
            ? find.byType(MD3ETransportRow)
            : find.byType(AMTransportControls);
        expect(controls, findsOneWidget);
        final semantics = tester.ensureSemantics();
        final buttons = name == 'MD3'
            ? <Finder>[
                find.bySemanticsLabel('上一首'),
                find.bySemanticsLabel('暂停'),
                find.bySemanticsLabel('下一首'),
              ]
            : <Finder>[
                find.byTooltip('上一首'),
                find.byTooltip('暂停'),
                find.byTooltip('下一首'),
              ];
        for (final button in buttons) {
          expect(button, findsWidgets);
          expect(
            tester
                .getSemantics(button.first)
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
        }
        semantics.dispose();

        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        player?.dispose();
        kugou.dispose();
        await tester.runAsync(() => HistoryRepository().flush());
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
        KugouProvider.restoreLyric = null;
        tester.view.physicalSize = originalPhysicalSize;
        tester.view.devicePixelRatio = originalDevicePixelRatio;
      }
    });
  }

  for (final (name, page) in <(String, Widget Function())>[
    ('MD3', () => const FullPlayer(dockMode: true)),
    ('AM', () => const AmStyleFullPlayer(dockMode: true)),
  ]) {
    for (final (source, artworkUri) in <(String, String)>[
      ('本地封面文件缺失', 'file:///md3music_test_missing/cover.jpg'),
      ('在线封面请求失败', 'https://cover-failure.invalid/cover.jpg'),
    ]) {
      testWidgets('$name $source回退占位且播放器控件保持可用', (tester) async {
        final originalPhysicalSize = tester.view.physicalSize;
        final originalDevicePixelRatio = tester.view.devicePixelRatio;
        final originalCacheManager =
            CachedNetworkImageProvider.defaultCacheManager;
        final failingCacheManager = _FailingArtworkCacheManager();
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        SharedPreferences.setMockInitialValues({
          'settings_spectrum_dynamic_color': false,
        });
        _mockPlatformChannels();
        final lyricPreferences = LyricPreferences.instance;
        final originalDynamicLyricColor = lyricPreferences.useDynamicLyricColor;
        await lyricPreferences.setUseDynamicLyricColor(false);
        KugouProvider.restoreLyric = (_) async => const KugouLyric(
          content: '[00:00.00]test lyric',
          decodedContent: '[00:00.00]test lyric',
        );
        final audio = ControlledAudioService();
        AudioServiceLoader.setTestOverride(() async => audio);
        final kugou = KugouProvider(registerDeviceOnStart: false);
        PlayerProvider? player;
        try {
          if (artworkUri.startsWith('http')) {
            CachedNetworkImageProvider.defaultCacheManager =
                failingCacheManager;
          }
          await tester.runAsync(() async {
            final activePlayer = PlayerProvider();
            player = activePlayer;
            await activePlayer.audioReady.timeout(const Duration(seconds: 10));
            final load = activePlayer.playPlaylist([
              _song(artworkUri: artworkUri),
            ], 0);
            await audio.waitForPlaylistLoads(1);
            await audio.completeSourceLoad(0);
            await load;
            audio.emitPlaying(true);
          });

          await tester.pumpWidget(_host(player!, kugou, page()));
          await tester.pump(const Duration(milliseconds: 100));
          final coverTab = find.descendant(
            of: find.byType(PlayerTabStrip),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.label == '封面',
            ),
          );
          expect(coverTab, findsOneWidget);
          await tester.tap(coverTab);
          await tester.pump(const Duration(milliseconds: 600));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));

          expect(tester.takeException(), isNull);
          expect(find.byIcon(Icons.music_note), findsWidgets);
          if (artworkUri.startsWith('http')) {
            expect(
              failingCacheManager.requestCount,
              1,
              reason: '同一封面失败只应有一条图片取数路径',
            );
            expect(find.textContaining('cover-failure'), findsNothing);
            expect(
              find.textContaining('simulated artwork failure'),
              findsNothing,
            );
          }
          final controls = name == 'MD3'
              ? find.byType(MD3ETransportRow)
              : find.byType(AMTransportControls);
          expect(controls, findsOneWidget);
          final semantics = tester.ensureSemantics();
          final nextButton = name == 'MD3'
              ? find.bySemanticsLabel('下一首').first
              : find.byTooltip('下一首');
          expect(
            tester
                .getSemantics(nextButton)
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
          semantics.dispose();

          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          player?.dispose();
          kugou.dispose();
          await tester.runAsync(() => HistoryRepository().flush());
          await audio.dispose();
          AudioServiceLoader.setTestOverride(null);
          KugouProvider.restoreLyric = null;
          CachedNetworkImageProvider.defaultCacheManager = originalCacheManager;
          await lyricPreferences.setUseDynamicLyricColor(
            originalDynamicLyricColor,
          );
          tester.view.physicalSize = originalPhysicalSize;
          tester.view.devicePixelRatio = originalDevicePixelRatio;
        }
      });
    }
  }

  for (final (name, page) in <(String, Widget Function())>[
    ('MD3', () => const FullPlayer(dockMode: true)),
    ('AM', () => const AmStyleFullPlayer(dockMode: true)),
  ]) {
    testWidgets('$name 同曲元数据变化重取歌词且旧请求不能覆盖新结果', (tester) async {
      final originalTabIndex = playerTabIndex.value;
      addTearDown(() => playerTabIndex.value = originalTabIndex);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      _mockPlatformChannels();
      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      final kugou = _DelayedLyricProvider();
      late PlayerProvider player;
      try {
        await tester.runAsync(() async {
          player = PlayerProvider();
          await player.audioReady;
          final load = player.playPlaylist([_song()], 0);
          await audio.waitForPlaylistLoads(1);
          await audio.completeSourceLoad(0);
          await load;
        });
        await tester.pumpWidget(_host(player, kugou, page()));
        await tester.pump(const Duration(milliseconds: 100));
        final strip = tester.widget<PlayerTabStrip>(find.byType(PlayerTabStrip).first);
        strip.controller.index = strip.items.indexWhere((item) => item.label == '歌词');
        await tester.pump();
        expect(kugou.requests, hasLength(1));
        await tester.runAsync(() async {
          final load = player.playPlaylist([_song(albumAudioId: 'enriched')], 0);
          await audio.waitForPlaylistLoads(2);
          await audio.completeSourceLoad(1);
          await load;
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(kugou.requests, hasLength(2));
        kugou.progressCallbacks.last?.call(const KugouLyric(
          content: '[00:01.00]new lyric', decodedContent: '[00:01.00]new lyric'));
        kugou.progressCallbacks.first?.call(const KugouLyric(
          content: '[00:01.00]old lyric', decodedContent: '[00:01.00]old lyric'));
        await tester.pump(const Duration(seconds: 9));
        if (name == 'MD3') {
          expect(tester.widget<LyricsView>(find.byType(LyricsView, skipOffstage: false).first).lyrics,
            contains('new lyric'));
        } else {
          expect(tester.widget<AppleLyricsView>(find.byType(AppleLyricsView, skipOffstage: false).first)
            .lines.map((line) => line.text), contains('new lyric'));
        }
        kugou.requests.last.complete(const KugouLyric(
          content: '[00:01.00]new lyric', decodedContent: '[00:01.00]new lyric'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        kugou.requests.first.complete(const KugouLyric(
          content: '[00:01.00]old lyric', decodedContent: '[00:01.00]old lyric'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        if (name == 'MD3') {
          expect(tester.widget<LyricsView>(find.byType(LyricsView, skipOffstage: false).first).lyrics,
            contains('new lyric'));
        } else {
          expect(tester.widget<AppleLyricsView>(find.byType(AppleLyricsView, skipOffstage: false).first)
            .lines.map((line) => line.text), contains('new lyric'));
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        player.dispose();
        kugou.dispose();
        await tester.runAsync(() => HistoryRepository().flush());
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
      }
    });
  }

  testWidgets('全屏页切歌与后台恢复时动态封面失败资源均释放', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    SharedPreferences.setMockInitialValues({});
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    final originalPlatform = VideoPlayerPlatform.instance;
    final videoPlatform = _FailingVideoPlayerPlatform();
    VideoPlayerPlatform.instance = videoPlatform;
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    DynamicCoverView.resolveLocalPath = (_) async => 'C:/fake/dynamic.mp4';
    final kugou = KugouProvider(registerDeviceOnStart: false);
    PlayerProvider? player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player!.audioReady.timeout(const Duration(seconds: 10));
        final loading = player!.playPlaylist([
          _song(id: 'cover-first', albumAudioId: 'dynamic-first'),
        ], 0);
        await audio.waitForPlaylistLoads(1);
        await audio.completeSourceLoad(0);
        await loading;
      });

      await tester.pumpWidget(
        _host(
          player!,
          kugou,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FullPlayer(dockMode: true),
                    ),
                  ),
                  child: const Text('打开全屏'),
                ),
              ),
            ),
          ),
        ),
      );

      for (var cycle = 1; cycle <= 100; cycle++) {
        final createsBeforeCycle = videoPlatform.createCount;
        await tester.tap(find.text('打开全屏'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(find.byType(VideoPlayer), findsNothing);
        expect(videoPlatform.createCount, greaterThan(createsBeforeCycle));
        expect(videoPlatform.disposeCount, videoPlatform.createCount);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(videoPlatform.disposeCount, videoPlatform.createCount);

        await tester.runAsync(() async {
          final loading = player!.playPlaylist([
            _song(
              id: 'cover-cycle-$cycle',
              albumAudioId: 'dynamic-cycle-$cycle',
            ),
          ], 0);
          await audio.waitForPlaylistLoads(cycle + 1);
          await audio.completeSourceLoad(cycle);
          await loading;
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(find.byType(VideoPlayer), findsNothing);
        expect(
          videoPlatform.createCount,
          greaterThanOrEqualTo(createsBeforeCycle + 2),
        );
        expect(videoPlatform.disposeCount, videoPlatform.createCount);

        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();
        expect(videoPlatform.disposeCount, videoPlatform.createCount);
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player?.dispose();
      kugou.dispose();
      await tester.runAsync(audio.dispose);
      await tester.runAsync(() => HistoryRepository().flush());
      AudioServiceLoader.setTestOverride(null);
      DynamicCoverView.resolveLocalPath = null;
      KugouProvider.restoreLyric = null;
      VideoPlayerPlatform.instance = originalPlatform;
      tester.view.physicalSize = originalPhysicalSize;
      tester.view.devicePixelRatio = originalDevicePixelRatio;
    }
  });
}
