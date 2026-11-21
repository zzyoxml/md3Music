import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/modules/player/full_player_am.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/widgets/cover_flip_crossfade.dart';
import 'package:md3music/modules/player/widgets/low_res_blur.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 造一张最小 PNG（1×1）落到临时目录，返回 `file://` URI。
///
/// 自动翻转（按钮切歌路径）的就绪门控按同键 provider 探测，只有真实可加载
/// 的封面才放行翻转；占位 http URI 会走「不演过渡」的直换路径。
String _writeCoverFile(String name) {
  const pngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  final dir = Directory.systemTemp.createTempSync('md3_cover_swipe');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/$name.png')
    ..writeAsBytesSync(base64Decode(pngBase64));
  return Uri.file(file.path).toString();
}

Song _song(int index) => Song(
  id: 'am-swipe-$index',
  title: 'AM Swipe $index',
  artist: 'Swipe Artist',
  album: 'Swipe Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track-$index.mp3',
  artworkUri: 'https://image.invalid/swipe-cover-$index.jpg',
  isOnline: true,
);

Song _songWithCover(int index, String artworkUri) => Song(
  id: 'am-swipe-$index',
  title: 'AM Swipe $index',
  artist: 'Swipe Artist',
  album: 'Swipe Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track-$index.mp3',
  artworkUri: artworkUri,
  isOnline: true,
);

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

Widget _host(PlayerProvider player, KugouProvider kugou) => MultiProvider(
  providers: [
    ChangeNotifierProvider<PlayerProvider>.value(value: player),
    ChangeNotifierProvider<KugouProvider>.value(value: kugou),
    ChangeNotifierProvider(create: (_) => DeviceProvider()),
    ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ChangeNotifierProvider(create: (_) => FavoritesProvider(syncOnStart: false)),
    ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
    ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
    ChangeNotifierProvider(create: (_) => ListenTogetherProvider()),
  ],
  child: const MaterialApp(home: AmStyleFullPlayer()),
);

/// 翻转组件下是否挂着模糊层（自动过渡进行中的判据）。
///
/// 两种形态都算「在糊」：低分辨率快照就绪前是阶梯 [ImageFiltered] 兜底，
/// 就绪后换成 [LowResBlurPainter] 的 CustomPaint α 叠层。
bool _flipBlurring(WidgetTester tester) {
  return find
          .descendant(
            of: find.byType(CoverFlipCrossfade),
            matching: find.byType(ImageFiltered),
          )
          .evaluate()
          .isNotEmpty ||
      find
          .descendant(
            of: find.byType(CoverFlipCrossfade),
            matching: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is LowResBlurPainter,
            ),
          )
          .evaluate()
          .isNotEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ControlledAudioService audio;
  late PlayerProvider player;
  late KugouProvider kugou;

  setUp(() async {
    // 频谱动态取色默认 true，开启时会挂 PaletteGenerator 15s 超时定时器；
    // 本用例只关心封面手势，显式关掉避开该定时器。
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'settings_spectrum_dynamic_color': false,
    });
    _mockPlatformChannels();
    // 本地 API 服务置为启动失败：曲目链接/歌词的兜底请求立即被拒绝。
    KugouApiClient.markServerStartFailed(KugouApiClient.markServerStarting());
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
  });

  tearDown(() async {
    AudioServiceLoader.setTestOverride(null);
    KugouProvider.restoreLyric = null;
    await audio.dispose();
  });

  /// 起一台 AM 播放页（窄屏、停在封面 tab）。
  Future<(PlayerProvider, KugouProvider)> pumpAmPlayer(
    WidgetTester tester, {
    required List<Song> songs,
  }) async {
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });
    // 窄屏 tab 顺序 [播放列表, 封面, 歌词, ...]：封面 tab 下标 1。
    final originalTab = playerTabIndex.value;
    playerTabIndex.value = 1;
    addTearDown(() => playerTabIndex.value = originalTab);

    kugou = KugouProvider(registerDeviceOnStart: false);
    await tester.runAsync(() async {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      final load = player.playPlaylist(songs, 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await load;
      audio.emitPlaying(true);
    });
    await tester.pumpWidget(_host(player, kugou));
    // 本页有 AnimatedScale / 频谱设置读取等异步，不用 pumpAndSettle；
    // AM 页可能挂 PlayerFrameDriver，有界推进即可。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AmStyleFullPlayer), findsOneWidget);
    return (player, kugou);
  }

  Future<void> tearDownPlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      player.dispose();
      kugou.dispose();
      await HistoryRepository().flush();
    });
  }

  testWidgets('封面内横滑：不切页签，切到下一首', (tester) async {
    await pumpAmPlayer(tester, songs: [_song(0), _song(1), _song(2)]);
    try {
      expect(find.byType(CoverFlipCrossfade), findsOneWidget);
      await tester.drag(find.byType(CoverFlipCrossfade), const Offset(-220, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(playerTabIndex.value, 1); // 页签没被 PageView 抢走
      await tester.runAsync(() async {
        // 加超时：手势没提交时不会出现第 2 次装载，否则会白等到 testWidgets
        // 的 10 分钟默认超时，失败信息也只剩「TimeoutException: null」。
        await audio
            .waitForPlaylistLoads(2)
            .timeout(const Duration(seconds: 10));
        await audio.completeSourceLoad(1);
      });
      // AM 页可能挂 PlayerFrameDriver，pumpAndSettle 不收敛；有界推进。
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.currentSong?.id, 'am-swipe-1');
    } finally {
      await tearDownPlayer(tester);
    }
  });

  testWidgets('新增横滑手势不吞掉封面点击（仍跳歌词页）', (tester) async {
    await pumpAmPlayer(tester, songs: [_song(0), _song(1), _song(2)]);
    try {
      await tester.tap(find.byType(CoverFlipCrossfade));
      await tester.pump(const Duration(milliseconds: 100));
      // 封面 tab 的 onTap → _goToTab(lyricsIndex)；窄屏 tab 顺序
      // [播放列表, 封面, 歌词, ...]，故下标由 1 变 2。
      expect(playerTabIndex.value, 2);
    } finally {
      await tearDownPlayer(tester);
    }
  });

  testWidgets('按钮切歌仍演自动翻转（模糊层在场）', (tester) async {
    final coverA = _writeCoverFile('btn-a');
    final coverB = _writeCoverFile('btn-b');
    await pumpAmPlayer(
      tester,
      songs: [
        _songWithCover(0, coverA),
        _songWithCover(1, coverB),
      ],
    );
    try {
      await tester.runAsync(() async {
        // 不 await next()：其内部可能等音频装载，与下面的 completeSourceLoad
        // 形成死锁（与 full_player_am_cover_flip_test 同款驱动方式）。
        // ignore: discarded_futures
        player.next();
        await audio
            .waitForPlaylistLoads(2)
            .timeout(const Duration(seconds: 10));
        await audio.completeSourceLoad(1);
      });
      var blurred = false;
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 25));
        if (_flipBlurring(tester)) {
          blurred = true;
          break;
        }
      }
      expect(blurred, isTrue, reason: '按钮切歌未进入「模糊 + 翻转」过渡');
    } finally {
      await tearDownPlayer(tester);
    }
  });
}
