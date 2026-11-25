import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/modules/player/full_player.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/widgets/cover_switch_pager.dart';
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

Song _song(int index) => Song(
  id: 'cover-switch-$index',
  title: 'Cover Switch $index',
  artist: 'Switch Artist',
  album: 'Switch Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track-$index.mp3',
  artworkUri: 'https://image.invalid/cover-$index.jpg',
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
  child: const MaterialApp(home: FullPlayer(dockMode: true)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ControlledAudioService audio;
  late PlayerProvider player;
  late KugouProvider kugou;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _mockPlatformChannels();
    // 本地 API 服务置为启动失败：曲目链接/歌词的兜底请求会立即被拒绝，
    // 不会挂在「等本地服务就绪」的 8s 计时器上（widget 测试里没有 Rust 服务）。
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

  testWidgets('封面内横滑：不切页签，切到下一首', (tester) async {
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });

    // 窄屏 tab 顺序是 [播放列表, 封面, 歌词, 评论]，封面页签下标为 1；
    // 不显式钉住就会依赖上一个用例留下的全局值。
    final originalTab = playerTabIndex.value;
    playerTabIndex.value = 1;
    addTearDown(() => playerTabIndex.value = originalTab);

    kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady.timeout(const Duration(seconds: 10));
        final load = player.playPlaylist([_song(0), _song(1), _song(2)], 0);
        await audio.waitForPlaylistLoads(1);
        await audio.completeSourceLoad(0);
        await load;
      });

      await tester.pumpWidget(_host(player, kugou));
      await tester.pumpAndSettle();
      expect(find.byType(CoverSwitchPager), findsOneWidget);

      // 封面内横滑一大段：应被 pager 拿走，页签不动
      await tester.drag(find.byType(CoverSwitchPager), const Offset(-320, 0));
      // 拖动提交会触发一次触感（含 300ms 看门狗计时器），推进过去再断言
      await tester.pump(const Duration(milliseconds: 400));

      // provider 真的去切歌了：第 2 次装载出现
      await tester.runAsync(() async {
        await audio.waitForPlaylistLoads(2);
        await audio.completeSourceLoad(1);
      });
      await tester.pumpAndSettle();

      expect(player.currentIndex, 1);
      expect(playerTabIndex.value, 1);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      kugou.dispose();
      await tester.runAsync(() => HistoryRepository().flush());
    }
  });

  testWidgets('封面之外的横滑仍切换页签', (tester) async {
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });

    final originalTab = playerTabIndex.value;
    playerTabIndex.value = 1;
    addTearDown(() => playerTabIndex.value = originalTab);

    kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady.timeout(const Duration(seconds: 10));
        final load = player.playPlaylist([_song(0), _song(1), _song(2)], 0);
        await audio.waitForPlaylistLoads(1);
        await audio.completeSourceLoad(0);
        await load;
      });

      await tester.pumpWidget(_host(player, kugou));
      await tester.pumpAndSettle();

      // 封面方盒之外（封面页左右各 16dp 的内边距里）横滑：应归 PageView，切到歌词页
      final pager = find.byType(CoverSwitchPager);
      final start = tester.getTopLeft(pager) - const Offset(8, 0);
      await tester.dragFrom(start, const Offset(-320, 0));
      await tester.pumpAndSettle();

      expect(playerTabIndex.value, isNot(originalTab));
      expect(player.currentIndex, 0);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      kugou.dispose();
      await tester.runAsync(() => HistoryRepository().flush());
    }
  });

  testWidgets('横屏左栏封面：接入同一套 CoverSwitchPager', (tester) async {
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    // 800×360 → ResponsiveLayout 判为 medium，走 _buildLandscapeLayout
    // 的常驻左侧栏封面（不在 PageView 里，无手势竞技场冲突）。
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });

    final originalTab = playerTabIndex.value;
    playerTabIndex.value = 1;
    addTearDown(() => playerTabIndex.value = originalTab);

    kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady.timeout(const Duration(seconds: 10));
        final load = player.playPlaylist([_song(0), _song(1), _song(2)], 0);
        await audio.waitForPlaylistLoads(1);
        await audio.completeSourceLoad(0);
        await load;
      });

      await tester.pumpWidget(_host(player, kugou));
      await tester.pumpAndSettle();

      // 横屏左栏的封面槽已接入同一套横向 pager（常驻封面）。
      expect(find.byType(CoverSwitchPager), findsOneWidget);

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      kugou.dispose();
      await tester.runAsync(() => HistoryRepository().flush());
    }
  });
}
