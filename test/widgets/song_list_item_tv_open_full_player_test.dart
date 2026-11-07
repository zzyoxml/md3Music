// tv: 焦点在「正在播放的歌」行上按 OK 直接进入 FullPlayer。
//
// 语义（kTvBuild 分支，SongListItem._tvSelectAction）：
// - 当前播放行 OK → openFullPlayer（防重复入栈守卫在 openFullPlayer 内）；
// - 非当前行 OK → 维持播放该行（onTap）；
// - 多选模式 OK → 维持切换选中，不进 FullPlayer。
//
// 本用例在 `MD3_TV=true` 下运行（`kTvBuild` 为 const，TV 分支整段树摇剔除）：
// `flutter test --dart-define=MD3_TV=true test/widgets/song_list_item_tv_open_full_player_test.dart`
//
// 入栈断言口径照抄 desktop_input_layer_test：push 后不 pumpAndSettle（本
// harness 不铺 FullPlayer 的全套依赖），tearDown 里移除残留播放页路由。
import 'dart:async' show Zone;
import 'dart:io';

import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
// 行内 InkWell 来自 material_ui，要求 material_ui 自己的 Material 祖先；
// host 的 MaterialApp/Scaffold 必须同为 material_ui（与既有 song_list_item
// 测试一致），用 flutter/material 的 Scaffold 会因同名不同类查不到 Material。
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/main.dart' show appNavigatorKey;
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/providers/blacklist_provider.dart';
import 'package:md3music/providers/car_mode_provider.dart';
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
import 'package:md3music/widgets/song_list_item.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 在 FakeAsync 时区外预热桌面歌词单例。
  ///
  /// FullPlayer 的 initState 会触到 `DesktopLyricService.instance`，其构造器
  /// 启动 5s 周期巡检 Timer；在哪个用例的 FakeAsync 区内首次构造，哪个用例
  /// 收尾就会被判「A Timer is still pending」。照抄
  /// bottom_bar_form_flight_test 的 `_prewarmDesktopLyricServiceOutsideFakeAsync`
  /// 把首次构造挪到根 Zone（真实 Timer 不参与 pending 检查）。
  Zone.root.run<void>(() => DesktopLyricService.instance);

  final song = Song(
    id: 'tv-open-fullplayer-target',
    title: 'TV 测试曲目',
    artist: '歌手',
    album: '专辑',
    duration: const Duration(minutes: 3),
    url: 'https://audio.invalid/tv-open-fullplayer-target.mp3',
    isOnline: true,
  );

  Future<_Env> boot() async {
    SharedPreferences.setMockInitialValues({});
    // FavoritesProvider 初始化会监听 connectivity（与 trailing_actions 测试同口径）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
    // FullPlayer 页面构建会触到的平台通道（照抄 full_player_cover_switch_test）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const services.MethodChannel('com.md3music.md3music/home_widget'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          services.SystemChannels.platform,
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const services.MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getTemporaryDirectory' ||
            'getApplicationSupportDirectory' ||
            'getApplicationDocumentsDirectory' ||
            'getDownloadsDirectory' => Directory.systemTemp.path,
            _ => null,
          },
        );
    // 本地 API 服务置为启动失败：FullPlayer 的歌词/链接兜底请求立即被拒绝，
    // 不会挂在「等本地服务就绪」的计时器上（widget 测试里没有 Rust 服务）。
    KugouApiClient.markServerStartFailed(KugouApiClient.markServerStarting());
    KugouProvider.restoreLyric =
        (_) async => const KugouLyric(
          content: '[00:00.00]test lyric',
          decodedContent: '[00:00.00]test lyric',
        );
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = _TestPlayerProvider();
    await player.audioReady.timeout(const Duration(seconds: 10));
    return _Env(player: player, audio: audio);
  }

  /// 把焦点请求到行的 DpadFocusable 内部节点上。
  ///
  /// TV 构建下行内才有 DpadFocusable（SongListItem 的**后代**而非祖先），
  /// 故在行后代里找第一个带 focusNode 的 Focus——即 DpadFocusable 的
  /// 内部节点（行尾操作已被 excludeChildFocus 排除，不会误中）。
  void focusRow(WidgetTester tester) {
    final focus = tester.widget<Focus>(
      find
          .descendant(
            of: find.byType(SongListItem),
            matching: find.byWidgetPredicate(
              (w) => w is Focus && w.focusNode != null,
            ),
          )
          .first,
    );
    focus.focusNode!.requestFocus();
  }

  testWidgets('当前播放行 OK：进 FullPlayer，不重播该行', (tester) async {
    final env = (await tester.runAsync(boot))!;
    env.player.setTestPlaybackState(currentSong: song, isPlaying: true);
    var tapCalls = 0;
    try {
      await tester.pumpWidget(env.host(
        SongListItem(song: song, onTap: () => tapCalls++),
      ));
      await tester.pump();
      focusRow(tester);
      await tester.pump();

      await tester.sendKeyEvent(services.LogicalKeyboardKey.select);
      // AppHaptics.click 在 Android 路径起 300ms 看门狗 Timer，弹掉避免挂起。
      await tester.pump(const Duration(milliseconds: 300));
      // 不 pumpAndSettle：只验证路由已入栈（activePlayerRoute 在 didPush 置位）。

      expect(activePlayerRoute, isNotNull, reason: 'OK 必须经 openFullPlayer 入栈播放页');
      expect(tapCalls, 0, reason: '当前播放行 OK 不应再触发 onTap 重播');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  }, skip: !kTvBuild);

  testWidgets('非当前行 OK：维持播放该行，不入栈播放页', (tester) async {
    final env = (await tester.runAsync(boot))!;
    env.player.setTestPlaybackState(currentSong: null, isPlaying: false);
    var tapCalls = 0;
    try {
      await tester.pumpWidget(env.host(
        SongListItem(song: song, onTap: () => tapCalls++),
      ));
      await tester.pump();
      focusRow(tester);
      await tester.pump();

      await tester.sendKeyEvent(services.LogicalKeyboardKey.select);
      // AppHaptics.click 的 300ms 看门狗 Timer 弹掉（非当前行也先 click 震动）。
      await tester.pump(const Duration(milliseconds: 300));

      expect(tapCalls, 1, reason: '非当前行 OK 语义不变：播放该行');
      expect(activePlayerRoute, isNull, reason: '普通行 OK 不应打开播放页');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  }, skip: !kTvBuild);

  testWidgets('多选模式下当前播放行 OK：切换选中，不进 FullPlayer', (tester) async {
    final env = (await tester.runAsync(boot))!;
    env.player.setTestPlaybackState(currentSong: song, isPlaying: true);
    var toggleCalls = 0;
    var tapCalls = 0;
    try {
      await tester.pumpWidget(env.host(
        SongListItem(
          song: song,
          isSelectMode: true,
          onSelectToggle: () => toggleCalls++,
          onTap: () => tapCalls++,
        ),
      ));
      await tester.pump();
      focusRow(tester);
      await tester.pump();

      await tester.sendKeyEvent(services.LogicalKeyboardKey.select);
      // AppHaptics.click 的 300ms 看门狗 Timer 弹掉。
      await tester.pump(const Duration(milliseconds: 300));

      expect(toggleCalls, 1, reason: '多选模式 OK 语义不变：切换选中');
      expect(tapCalls, 0);
      expect(activePlayerRoute, isNull, reason: '多选模式不应打开播放页');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  }, skip: !kTvBuild);
}

class _TestPlayerProvider extends PlayerProvider {
  Song? _testCurrentSong;
  bool _testIsPlaying = false;

  @override
  Song? get currentSong => _testCurrentSong;

  @override
  bool get isPlaying => _testIsPlaying;

  void setTestPlaybackState({
    required Song? currentSong,
    required bool isPlaying,
  }) {
    _testCurrentSong = currentSong;
    _testIsPlaying = isPlaying;
    notifyListeners();
  }
}

class _Env {
  _Env({required this.player, required this.audio});

  final _TestPlayerProvider player;
  final ControlledAudioService audio;

  Future<void> dispose(WidgetTester tester) async {
    // 残留的播放页路由会带着根 Navigator 引用活到下一个用例
    //（与 desktop_input_layer_test 的 tearDown 同口径）。
    final DraggablePlayerRoute<dynamic>? route = activePlayerRoute;
    if (route != null) route.navigator?.removeRoute(route);
    activePlayerRoute = null;
    playerExpansion.value = 0.0;
    player.dispose();
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
    KugouProvider.restoreLyric = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const services.MethodChannel('com.md3music.md3music/home_widget'),
      null,
    );
    messenger.setMockMethodCallHandler(services.SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(
      const services.MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  }

  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider<FavoritesProvider>.value(
        value: FavoritesProvider(syncOnStart: false),
      ),
      ChangeNotifierProvider<LocalFavoritesProvider>.value(
        value: LocalFavoritesProvider(),
      ),
      // 更多菜单内的「不感兴趣」tile 读黑名单状态（不拉取、不发请求）
      ChangeNotifierProvider<BlacklistProvider>(create: (_) => BlacklistProvider()),
      // openFullPlayer 读车机守卫；fullPlayerRoute 读播放器样式开关；
      // FullPlayer 页面构建还读设备形态与酷狗/听歌同伴状态（照抄
      // full_player_cover_switch_test 的 provider 清单）。
      ChangeNotifierProvider<CarModeProvider>(create: (_) => CarModeProvider()),
      ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
      ChangeNotifierProvider<KugouProvider>(
        create: (_) => KugouProvider(registerDeviceOnStart: false),
      ),
      ChangeNotifierProvider<CommentDisplayProvider>(
        create: (_) => CommentDisplayProvider(),
      ),
      ChangeNotifierProvider<ListenTogetherProvider>(
        create: (_) => ListenTogetherProvider(),
      ),
    ],
    child: MaterialApp(
      // openFullPlayer 走 rootNavigator 入栈，必须给 MaterialApp 挂全局 key。
      navigatorKey: appNavigatorKey,
      home: Scaffold(body: child),
    ),
  );
}
