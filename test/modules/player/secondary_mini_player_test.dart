import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/mini_player.dart';
import 'package:md3music/modules/player/player_morph_scene.dart';
import 'package:md3music/modules/player/secondary_mini_player.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';

/// 只覆写播放态相关 getter 的假 provider。
///
/// 测试环境没有音频平台实现，真实 `playPlaylist` 起不了播（`isPlaying` 恒 false），
/// 故沿用本仓既有做法（见 `test/modules/personal_fm/personal_fm_section_test.dart`
/// 的 `_FakePlayer`）直接注入播放态。
class _FakePlayer extends PlayerProvider {
  Song? _song;
  bool _playing = false;
  Duration? _duration;

  @override
  Song? get currentSong => _song;

  @override
  bool get isPlaying => _playing;

  @override
  Duration? get duration => _duration;

  void simulate({Song? song, bool? playing}) {
    if (song != null) _song = song;
    if (playing != null) _playing = playing;
    notifyListeners();
  }

  /// 时长可以置 null（模拟尚未取到时长），故单独开一个入口。
  void setDuration(Duration? value) {
    _duration = value;
    notifyListeners();
  }
}

/// ⚠️ Flutter 测试默认视口是 800×600，其 `shortestSide` **恰好 = 600** →
/// `isPadLayout` 会判为 true。所以凡涉及布局分支的用例都必须显式指定视口。
void _setViewport(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
  addTearDown(tester.view.reset);
}

/// 手机（最短边 400 < 600）：竖屏。
const Size _kPhonePortrait = Size(400, 869);

/// Pad（最短边 800 ≥ 600）：竖屏。
const Size _kPadPortrait = Size(800, 1280);

/// [SecondaryMiniPlayer] 的既有约定：
/// - 帧率：唱片旋转必须走共享 60fps 节拍（不得用 Ticker），不可见时必须解绑（AGENTS.md §10）；
/// - 停靠：手机水平居中（原行为），Pad 右下停靠且限宽；
/// - 几何：封面圆与胶囊左半圆**同心**，四周留等宽背景，不得顶穿/溢出圆角；
/// - 收缩：滚动自动收缩只作用于**二级页面**，一级页面常驻展开态。
void main() {
  Song song(String id) => Song(
    id: id,
    title: '标题',
    artist: 'artist',
    album: 'album',
    duration: const Duration(seconds: 60),
  );

  late _FakePlayer player;
  late CarModeProvider carMode;
  late ValueNotifier<bool> collapsed;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 全局开关/进度是跨用例共享的 ValueNotifier，必须显式复位。
    playerExpansion.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerProgressEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    collapsed = ValueNotifier<bool>(true);
    player = _FakePlayer()..simulate(song: song('s0'), playing: true);
    carMode = CarModeProvider();
  });

  tearDown(() {
    collapsed.dispose();
    player.dispose();
    carMode.dispose();
    playerExpansion.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerProgressEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
  });

  Widget host({
    bool tickerEnabled = true,
    VoidCallback? onRequestExpand,
    bool reduceMotion = false,
  }) {
    Widget playerWidget = TickerMode(
      enabled: tickerEnabled,
      child: SecondaryMiniPlayer(
        collapsed: collapsed,
        onRequestExpand: onRequestExpand ?? () {},
      ),
    );
    if (reduceMotion) {
      // 用 Builder 取到 MaterialApp 注入的 MediaQuery 后覆盖 disableAnimations，
      // 使 [SecondaryMiniPlayer] 的 didChangeDependencies 读到
      // MediaQuery.disableAnimationsOf == true（reduced-motion 分支）。
      // 先快照内层控件再用 final 捕获：闭包若直接引用可变的 playerWidget，
      // 重赋值后 builder 会把自己套进自己（无限重建）。
      final Widget inner = playerWidget;
      playerWidget = Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: inner,
        ),
      );
    }
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          // 与生产一致：宿主 SecondaryMiniPlayerHost 把播放器放在
          // Stack 的 Positioned(left:0,right:0,bottom:0) 里。
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: playerWidget,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 挂在**二级路由**上的宿主：悬浮播放器只在二级页面渲染
  /// （`isSecondaryRoutePage` 判据），故必须用 push 出来的路由承载。
  ///
  /// [child] 用于探测宿主注入的底部预留 padding（默认空盒子）。
  /// [imeInset] 注入到宿主祖先的 `MediaQuery.viewInsets.bottom`，用于模拟键盘
  /// 弹出。用 [ValueNotifier] 而不是「重新 pumpWidget 换参数」：路由内容由
  /// Navigator 缓存，根 widget 重建并不会重跑 `/detail` 的 builder，只有路由**内部**
  /// 的监听器能真正把新读数喂给宿主（flutter_test 也无法伪造真实视口的
  /// viewInsets —— `handleMetricsChanged` 只重建 RenderView 配置，不重建树根
  /// MediaQuery）。
  Widget hostOnSecondaryRoute({
    Widget? child,
    ValueNotifier<double>? imeInset,
  }) {
    Widget content = SecondaryMiniPlayerHost(child: child ?? const SizedBox());
    if (imeInset != null) {
      final Widget host = content;
      content = ValueListenableBuilder<double>(
        valueListenable: imeInset,
        builder: (BuildContext context, double inset, Widget? _) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: EdgeInsets.only(bottom: inset)),
          child: host,
        ),
      );
    }
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        initialRoute: '/detail',
        routes: <String, WidgetBuilder>{
          '/': (_) => const SizedBox(),
          '/detail': (_) => Scaffold(
            body: Stack(
              children: <Widget>[
                // 注在 Scaffold body 之下：只喂给宿主与播放条判据，不与
                // Scaffold 自身的键盘避让叠加，读数才唯一。
                Positioned.fill(child: content),
              ],
            ),
          ),
        },
      ),
    );
  }

  /// 挂在**一级路由**（栈底 `home:`）上的宿主：主页（tab 页）同样由悬浮播放器承载。
  ///
  /// [tabId] 决定"一级页面"判据（`isPinnedNavPage` = 标题左对齐）：默认
  /// `discover` 在 `kDefaultTabs` 里 → 算一级页面；传 `search`（可选 tab，默认隐藏）
  /// → 标题居中 → 按二级页面处理。
  Widget hostOnPrimaryRoute({Widget? child, String? tabId = 'discover'}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<TabConfigProvider>(
          create: (_) => TabConfigProvider(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned.fill(
                child: SecondaryMiniPlayerHost(
                  tabId: tabId,
                  child: child ?? const SizedBox(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 胶囊本体：按 32dp 胶囊圆角定位，不依赖视觉 elevation。
  Finder capsule(WidgetTester tester) {
    final f = find.descendant(
      of: find.byType(SecondaryMiniPlayer),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.borderRadius == BorderRadius.circular(32),
      ),
    );
    expect(f, findsOneWidget, reason: '胶囊应唯一可定位');
    return f;
  }

  testWidgets('浮动迷你播放器的歌曲名和歌手居中对齐', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(host());
    await tester.pump();

    expect(tester.widget<Text>(find.text('标题')).textAlign, TextAlign.center);
    expect(tester.widget<Text>(find.text('artist')).textAlign, TextAlign.center);

    await tester.pumpWidget(const SizedBox());
  });

  // —— 帧率约定（AGENTS.md §10）——

  testWidgets('播放中且可见：挂共享 60fps 驱动，且不启动 Ticker', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '唱片旋转应挂共享 60fps 节拍（§10.3）',
    );
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '唱片旋转不得由 Ticker 驱动（AGENTS.md §10.4.1）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('暂停：解绑驱动（保留当前角度）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    player.simulate(playing: false);
    await tester.pump();

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('全屏播放器已展开（卡片 opacity=0）：解绑驱动', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    playerExpansion.value = 1.0;
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: 'DraggablePlayerRoute 是 opaque=false，TickerMode 不会自动关，'
          '必须按 playerExpansion 停帧（§10.4.3）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 关闭（被覆盖 / 切走）：解绑驱动', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(host(tickerEnabled: false));
    await tester.pump();

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dispose 后解绑，不留 pending timer', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(const SizedBox());

    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });

  // —— 停靠位置（手机居中 / Pad 右下限宽）——

  testWidgets('手机竖屏：维持原样（展开态撑满可用宽、水平居中）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false; // 展开态
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 形变收敛到展开态

    final rect = tester.getRect(capsule(tester));
    // 可用宽 = 视口宽 - 左右各 16 内边距
    expect(rect.width, closeTo(_kPhonePortrait.width - 32, 0.5));
    expect(
      rect.center.dx,
      closeTo(_kPhonePortrait.width / 2, 0.5),
      reason: '手机必须保持水平居中（上游约束：手机竖屏/横屏完全不变）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Pad：展开态胶囊限宽 400 且贴右下角', (tester) async {
    _setViewport(tester, _kPadPortrait);
    collapsed.value = false; // 展开态
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.right; // 单测无启动装载，显式设默认
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rect = tester.getRect(capsule(tester));
    expect(
      rect.width,
      closeTo(kSecondaryPlayerPadMaxWidth, 0.5),
      reason: 'Pad 下轨道限宽，胶囊不再横贯全屏',
    );
    expect(
      rect.right,
      closeTo(_kPadPortrait.width - 16, 0.5),
      reason: '右缘贴容器右内边距（16dp）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Pad 收起态：圆盘贴右缘（不再居中）', (tester) async {
    _setViewport(tester, _kPadPortrait);
    collapsed.value = true; // 初始即收起
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.right; // 单测无启动装载，显式设默认
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rect = tester.getRect(capsule(tester));
    expect(rect.width, closeTo(64.0, 0.5), reason: '收起态直径 = _disc(64)');
    expect(
      rect.right,
      closeTo(_kPadPortrait.width - 16, 0.5),
      reason: '收起态圆盘应贴右下角，而不是屏幕中央',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— 悬浮播放器总开关（设置页可关）——

  testWidgets('默认开启：宿主渲染悬浮条并注入底部预留（+76）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnSecondaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();

    expect(kSecondaryPlayerEnabled.value, isTrue);
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);
    expect(
      probedBottom,
      closeTo(76.0, 0.5),
      reason: '宿主应注入 _kReservedBottom，否则列表末项会被悬浮栏遮挡',
    );

    await tester.pumpWidget(const SizedBox());
  });

  /// 键盘弹出（`windowSoftInputMode=adjustResize` 会把 body 整块抬高）时，播放条
  /// 不应骑在键盘上沿：整条收没、且宿主注入的底部预留同步归零。
  ///
  /// 收起是 260ms 的一次性转场动画，用显式 pump 推进——悬浮条的唱片旋转挂在
  /// 共享 60fps 节拍上，`pumpAndSettle` 永远等不到静止帧。
  testWidgets('键盘弹出：悬浮条整条收没且不预留底部高度', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    double probedBottom = -1;
    final ValueNotifier<double> ime = ValueNotifier<double>(0);
    addTearDown(ime.dispose);

    await tester.pumpWidget(
      hostOnSecondaryRoute(
        imeInset: ime,
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);
    expect(probedBottom, closeTo(76.0, 0.5));

    ime.value = 300;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byType(SecondaryMiniPlayer),
      findsNothing,
      reason: '键盘弹出期间悬浮条应离开树，而不是透明占位',
    );
    expect(
      probedBottom,
      closeTo(0.0, 0.5),
      reason: '悬浮条收没后那段 76dp 预留要让回给列表',
    );

    ime.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);
    expect(probedBottom, closeTo(76.0, 0.5));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('键盘弹出（常驻条形态）：回落的底部常驻条同样收没', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerEnabled.value = false;
    final ValueNotifier<double> ime = ValueNotifier<double>(0);
    addTearDown(ime.dispose);

    await tester.pumpWidget(hostOnSecondaryRoute(imeInset: ime));
    await tester.pump();
    expect(find.byType(MiniPlayer), findsOneWidget);

    ime.value = 300;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MiniPlayer), findsNothing);

    ime.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MiniPlayer), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('关闭开关（二级页面）：回退为底部常驻播放条', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerEnabled.value = false;
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnSecondaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(SecondaryMiniPlayer),
      findsNothing,
      reason: '关闭后二级页面不再渲染悬浮播放器',
    );
    expect(
      find.byType(MiniPlayer),
      findsOneWidget,
      reason: '关闭后二级页面应回退为底部常驻播放条（与主页同一条）',
    );
    expect(
      probedBottom,
      closeTo(0.0, 0.5),
      reason: '回落形态用 Column（真实布局空间）承载，无需注入底部预留',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('运行时切换开关：即时生效（无需重建整页）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(hostOnSecondaryRoute());
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);

    kSecondaryPlayerEnabled.value = false;
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsNothing);

    kSecondaryPlayerEnabled.value = true;
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // —— 一级页面（主页）同样由悬浮播放器承载，受同一开关控制 ——

  testWidgets('一级页面 + 开关开启：渲染悬浮播放器（不再退化为透传）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnPrimaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(SecondaryMiniPlayer),
      findsOneWidget,
      reason: '主页（栈底路由）也应渲染悬浮播放器，统一受开关控制',
    );
    expect(
      probedBottom,
      closeTo(76.0, 0.5),
      reason: '主页底部同样需要预留悬浮条高度',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('一级页面 + 开关关闭：不渲染悬浮播放器（底部条由 shell 承载）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerEnabled.value = false;
    await tester.pumpWidget(hostOnPrimaryRoute());
    await tester.pump();

    expect(find.byType(SecondaryMiniPlayer), findsNothing);
    // 主页的底部常驻条由 _MainLayout 的 shell 渲染（不在本测试宿主内），
    // 宿主不得再补一条，否则主页会出现两条播放器。
    expect(find.byType(MiniPlayer), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  // —— 折叠态拖拽 + 三点吸附 ——

  /// 把圆盘水平拖动 [dx] 并松手（一次拖拽含触发吸附）。
  Future<void> dragDisc(WidgetTester tester, double dx) async {
    await tester.drag(capsule(tester), Offset(dx, 0));
    // 吸附动画 220ms，用固定时长 pump 而非 pumpAndSettle：
    // 播放中时共享帧驱动（PlayerFrameDriver 的 Timer）会让 pumpAndSettle 难以收敛。
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('手机默认停靠位为中下（折叠态圆盘居中）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final rect = tester.getRect(capsule(tester));
    expect(rect.width, closeTo(64.0, 0.5));
    expect(
      rect.center.dx,
      closeTo(_kPhonePortrait.width / 2, 0.5),
      reason: '手机默认停靠位 = 中下',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('向右拖动后吸附到右下，并持久化', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await dragDisc(tester, 200);

    final rect = tester.getRect(capsule(tester));
    expect(
      rect.right,
      closeTo(_kPhonePortrait.width - 16, 0.5),
      reason: '吸附到右下：右缘 = 视口宽 - 16',
    );
    expect(
      kSecondaryPlayerDock.value,
      SecondaryPlayerDockSide.right,
      reason: '吸附后应更新全局停靠位',
    );
    expect(
      await SettingsRepository().getSecondaryPlayerDockRaw(),
      'right',
      reason: '吸附结果应持久化（重启保持）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('向左拖动后吸附到左下', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await dragDisc(tester, -200);

    final rect = tester.getRect(capsule(tester));
    expect(rect.left, closeTo(16.0, 0.5), reason: '吸附到左下：左缘 = 16');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('拖拽超出轨道边界：被钳制，不会跑出屏幕', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await dragDisc(tester, -5000);

    final rect = tester.getRect(capsule(tester));
    expect(rect.left, closeTo(16.0, 0.5), reason: '钳制到左缘 16');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('展开态拖拽无效（胶囊不随拖拽移动）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false; // 展开态
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final before = tester.getRect(capsule(tester));
    await tester.drag(capsule(tester), Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 300));
    final after = tester.getRect(capsule(tester));

    expect(after, before, reason: '拖拽语义只针对折叠态圆盘');

    await tester.pumpWidget(const SizedBox());
  });

  // —— 可拖拽态反馈：浮起 + 震动（直接拖动 / 长按拾起，同一套语义）——

  /// 胶囊**绘制后**的矩形。
  ///
  /// 不能用 `tester.getRect`：它给的是「变换后的左上角 + 未变换的尺寸」，浮起动画带
  /// [Transform.scale] 时两者混用会同时错掉宽高与中心。本层只有平移与等比缩放
  /// （没有旋转），按矩阵两端点换算即可。
  Rect capsulePaintRect(WidgetTester tester) {
    final ro = tester.renderObject<RenderBox>(capsule(tester));
    final m = ro.getTransformTo(null);
    return Rect.fromPoints(
      MatrixUtils.transformPoint(m, Offset.zero),
      MatrixUtils.transformPoint(m, ro.size.bottomRight(Offset.zero)),
    );
  }

  /// 「已拾起」态的投影层：只在浮起进度 >0 时给出 boxShadow。
  Finder liftShadow(WidgetTester tester) => find.descendant(
    of: find.byType(SecondaryMiniPlayer),
    matching: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).boxShadow?.isNotEmpty == true,
    ),
  );

  testWidgets('长按拾起圆盘：浮起（上移 + 放大 + 投影），松手落回原位', (
    tester,
  ) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true; // 折叠态圆盘才可拖拽
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final resting = capsulePaintRect(tester);
    expect(liftShadow(tester), findsNothing, reason: '未拾起时不该有浮起投影');

    final gesture = await tester.startGesture(resting.center);
    // 500ms 后才算长按；再 pump 一段让 140ms 的浮起动画跑完。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));

    final lifted = capsulePaintRect(tester);
    expect(
      lifted.center.dy,
      closeTo(resting.center.dy - 6.0, 0.6),
      reason: '可拖拽态：拾起时上移 6dp',
    );
    expect(
      lifted.width,
      closeTo(resting.width * 1.035, 0.6),
      reason: '可拖拽态：放大 3.5%',
    );
    expect(liftShadow(tester), findsOneWidget, reason: '拾起应建立投影');

    await gesture.up();
    // 回落要两帧：Ticker 起跳后的第一帧 elapsed≈0（_pendingElapsed 被扣掉），
    // 再 pump 一帧才真的跑完 220ms。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final settled = capsulePaintRect(tester);
    expect(settled.center.dy, closeTo(resting.center.dy, 0.6));
    expect(settled.width, closeTo(resting.width, 0.6));
    expect(liftShadow(tester), findsNothing, reason: '松手必须落回，不残留投影');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('长按拾起后手指仍能拖动圆盘（长按不得锁死拖拽）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final resting = capsulePaintRect(tester);
    final gesture = await tester.startGesture(resting.center);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));

    // 冲突回归点：长按被识别后拖动识别器已被淘汰，若这段位移没人接手，
    // 圆盘就纹丝不动 —— 而浮起明明在说"现在可以拖"。
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();

    final moved = capsulePaintRect(tester);
    expect(
      moved.center.dx,
      closeTo(resting.center.dx + 150, 1.0),
      reason: '拾起后的手指位移必须跟着圆盘走',
    );
    expect(liftShadow(tester), findsOneWidget, reason: '拖动过程中保持在可拖拽态');

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      kSecondaryPlayerDock.value,
      SecondaryPlayerDockSide.right,
      reason: '长按拾起再拖动，松手照样吸附到最近槽位',
    );
    expect(
      await SettingsRepository().getSecondaryPlayerDockRaw(),
      'right',
      reason: '与直接拖动的持久化行为一致',
    );
    expect(liftShadow(tester), findsNothing, reason: '吸附后退出可拖拽态');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('直接拖动圆盘也进入同一可拖拽态（拖动期间浮起，松手落回）', (
    tester,
  ) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final resting = capsulePaintRect(tester);
    final gesture = await tester.startGesture(resting.center);
    // 第一次 move 只负责越过 slop 触发 onStart（那段位移被识别器吃掉，不上报 update），
    // 所以必须再 move 一次才看得到跟手 —— 一次 moveBy 断言跟手是假失败。
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 200)); // 浮起 140ms 跑完

    final moved = capsulePaintRect(tester);
    expect(
      moved.center.dx,
      closeTo(resting.center.dx + 60, 1.0),
      reason: '原拖动语义不变：update 增量跟手',
    );
    expect(
      moved.center.dy,
      closeTo(resting.center.dy - 6.0, 0.6),
      reason: '拖动即拾起，浮起不再只属于长按',
    );
    expect(liftShadow(tester), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(liftShadow(tester), findsNothing, reason: '松手落回，不残留投影');
    expect(
      capsulePaintRect(tester).center.dy,
      closeTo(resting.center.dy, 0.6),
    );

    await tester.pumpWidget(const SizedBox());
  });

  /// 卡片自己的 GestureDetector。
  ///
  /// 用「同时有 onTap 和 onHorizontalDragStart」判定：子树里还有别的 opaque + onTap
  /// 手势（封面一类），但只有卡片这一个既 clickable 又 draggable。
  Finder cardGesture(WidgetTester tester) => find.descendant(
    of: find.byType(SecondaryMiniPlayer),
    matching: find.byWidgetPredicate(
      (w) =>
          w is GestureDetector &&
          w.onTap != null &&
          w.onHorizontalDragStart != null,
    ),
  );

  GestureDetector cardGestureOf(WidgetTester tester) =>
      tester.widget<GestureDetector>(cardGesture(tester));

  testWidgets('展开态长按不浮起：胶囊不可拖拽就不给"可拖拽"反馈', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false; // 展开态胶囊：拖拽语义本来就被禁用
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final resting = capsulePaintRect(tester);
    final gesture = await tester.startGesture(resting.center);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));

    expect(liftShadow(tester), findsNothing, reason: '不该谎称可拖拽');
    expect(capsulePaintRect(tester).center.dy, closeTo(resting.center.dy, 0.01));
    // 长按回调压根没注册 → 识别器不进 arena → 按住满 500ms 再松手，tap 照常派发
    // （否则会变成"按住播放条就再也进不了播放页"的新 bug）。实测把这句改成 up()
    // 就会真的拉起 FullPlayer（本宿主没注册 LocalFavoritesProvider，会抛异常），
    // 正好反证 tap 没被吞；这里用 cancel 收尾，只断言结构。
    expect(cardGestureOf(tester).onLongPressStart, isNull);
    expect(cardGestureOf(tester).onLongPressMoveUpdate, isNull);

    await gesture.cancel();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('折叠态才注册长按：圆盘可拖拽，所以该有拾起入口', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(cardGestureOf(tester).onLongPressStart, isNotNull);
    expect(cardGestureOf(tester).onLongPressMoveUpdate, isNotNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('长按识别后松手不算点击（圆盘不会因此展开）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true; // 折叠态：点击=展开，长按不该顺带展开
    var expands = 0;
    await tester.pumpWidget(host(onRequestExpand: () => expands++));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final center = tester.getRect(capsule(tester)).center;
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(expands, 0, reason: '长按与点击互斥：识别到长按就不再派发 tap');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('浮起是一次性动画：只在拾起/回落期间占 Ticker', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '静止态不得为浮起预留 Ticker（AGENTS §10.4.1）',
    );

    final gesture = await tester.startGesture(
      tester.getRect(capsule(tester)).center,
    );
    await tester.pump(const Duration(milliseconds: 600)); // 触发长按 + 浮起中
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: '拾起反馈要跟手，动画期间走满帧 Ticker 是对的',
    );

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 回落 220ms 已跑完
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '回落收敛后必须停表，不能留常驻动画（AGENTS §10.4.3）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— 封面与胶囊圆角的几何贴合（左侧突出溢出背景的回归）——

  /// 封面圆的**可视**矩形（外接正方形）。
  ///
  /// 不能直接用 `tester.getRect(ClipOval)`：它返回「变换后的左上角 + 未变换的尺寸」，
  /// 而封面外层有 `Transform.scale`（收起态 scale≠1）与 `Transform.rotate`（圆盘随
  /// 播放旋转），混用得到的矩形既不对称也不可信。这里从祖先变换矩阵取**缩放分量**
  /// （旋转不影响圆：旋转后的圆仍是圆），圆心取裁剪盒中心——它在旋转轴上，
  /// 因此旋转后仍映射到同一位置。
  Rect coverVisualRect(WidgetTester tester) {
    final ro = tester.renderObject<RenderBox>(
      find.descendant(of: capsule(tester), matching: find.byType(ClipOval)),
    );
    final m = ro.getTransformTo(null);
    final centerLocal = ro.size.center(Offset.zero);
    final center = MatrixUtils.transformPoint(m, centerLocal);
    // 相似变换（rotate + uniform scale + translate）的缩放分量 = 第一列的模长。
    final scale = math.sqrt(
      m.entry(0, 0) * m.entry(0, 0) + m.entry(1, 0) * m.entry(1, 0),
    );
    final visual = ro.size.width * scale;
    return Rect.fromCenter(
      center: center,
      width: visual,
      height: visual,
    );
  }

  /// 封面当前旋转角（度，0–360 归一）：从祖先变换矩阵第一列的极角还原。
  double coverAngleOf(WidgetTester tester) {
    final m = tester
        .renderObject<RenderBox>(
          find.descendant(of: capsule(tester), matching: find.byType(ClipOval)),
        )
        .getTransformTo(null);
    final a = math.atan2(m.entry(1, 0), m.entry(0, 0)) * 180 / math.pi;
    return (a + 360) % 360;
  }

  testWidgets('展开态：封面圆与胶囊左半圆同心，四周留等宽背景（不顶穿圆角）', (
    tester,
  ) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final pill = tester.getRect(capsule(tester));
    final cover = coverVisualRect(tester);

    // 直径 58：旧实现里外层 64×64 是**紧**约束、Transform 不改约束，
    // ClipOval 于是按 64 裁圆 → 封面与胶囊等高、上下边缘相切（顶穿背景圆角）。
    expect(cover.width, closeTo(58.0, 0.5), reason: '封面直径应为可见尺寸 58');
    expect(cover.height, closeTo(58.0, 0.5));

    // 圆心 = 胶囊左半圆圆心（左缘 + 半径 32）→ 圆角与封面「采样」同一圆。
    expect(cover.center.dx, closeTo(pill.left + 32.0, 0.5));
    expect(cover.center.dy, closeTo(pill.center.dy, 0.5));

    // 同心 + 半径差 3 → 左/上/下留白等宽，封面完全落在背景之内（右缘深入胶囊，
    // 与上述三条同心判定一起构成「不外溢」的完整证据）。
    expect(cover.left - pill.left, closeTo(3.0, 0.5));
    expect(cover.top - pill.top, closeTo(3.0, 0.5));
    expect(pill.bottom - cover.bottom, closeTo(3.0, 0.5));
    expect(cover.right, lessThan(pill.right - 100));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收起态：圆盘封面居中，背景环等宽 4dp', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final disc = tester.getRect(capsule(tester));
    final cover = coverVisualRect(tester);

    expect(cover.width, closeTo(56.0, 0.5), reason: '收起态可见尺寸应为 56');
    expect(cover.height, closeTo(56.0, 0.5));
    expect(cover.center.dx, closeTo(disc.center.dx, 0.5));
    expect(cover.center.dy, closeTo(disc.center.dy, 0.5));
    expect(disc.width - cover.width, closeTo(8.0, 0.5), reason: '四周各 4dp 环');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('形变全程：封面圆逐帧与胶囊左半圆同心（中段不浮空）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    kSecondaryPlayerDock.value = SecondaryPlayerDockSide.center;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    collapsed.value = true; // 开始形变，逐帧采样中间过程
    var samples = 0;
    var worst = 0.0;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final pill = tester.getRect(capsule(tester));
      if ((pill.width - 64).abs() < 0.05) break; // 已到位，后面是收敛尾段
      final cover = coverVisualRect(tester);
      worst = math.max(
        worst,
        (cover.center.dx - (pill.left + 32)).abs(),
      );
      worst = math.max(worst, (cover.center.dy - pill.center.dy).abs());
      samples++;
    }

    expect(samples, greaterThan(5), reason: '必须真的采到形变中间帧才有意义');
    expect(
      worst,
      lessThan(0.6),
      reason: '旧写法 left = t·(w-64)/2 只在两端同心，中段封面偏离左半圆圆心实测 38dp',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— 形变收敛与帧数 ——

  testWidgets('形变收敛：画面到位后必须尽快停机，不得空转整段弹簧尾振', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    collapsed.value = true;
    var arrived = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if ((tester.getRect(capsule(tester)).width - 64).abs() < 0.05) {
        arrived = true;
        break;
      }
    }
    expect(arrived, isTrue, reason: '形变应在有限帧内到达目标宽度');

    var tailMs = 0.0;
    while (tester.binding.transientCallbackCount > 0 && tailMs < 1000) {
      await tester.pump(const Duration(milliseconds: 16));
      tailMs += 16;
    }

    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '弹簧必须自行停机，否则 Ticker 永久产帧',
    );
    expect(
      tailMs,
      lessThan(250.0),
      reason: '宽度到位到停机之间的空转必须很短：旧写法实测 464ms/58 帧，'
          '收紧容差 + snapToEnd 后应 ≤ 约 180ms',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— 封面旋转与形变进度解耦 ——

  testWidgets('展开后封面角度不回退（旧写法会被形变进度强行扫过再倒带）', (
    tester,
  ) async {
    // ⚠️ 必须**逐帧 pump**：圆盘旋转挂在共享 16ms 节拍上，单次 `pump(900ms)`
    // 不会推进它（实测两种实现都读出 0°，断言就失去区分力）。
    // 逐帧下实测：旧写法收起后 280.8°，新实现 24.3°。
    Future<void> step(int frames) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(host());
    await tester.pump();
    await step(30);

    // 播放 ~3s 让圆盘积累相位（旧写法会把这份相位在收起瞬间当成角度）
    await step(190);
    collapsed.value = true;
    await step(60);
    final collapsedAngle = coverAngleOf(tester);
    expect(
      collapsedAngle,
      lessThan(60.0),
      reason: '收起过程只允许按转速渐入推进少量角度；旧写法此处实测 280.8°'
          '（= 当时的播放相位 × 360°），且展开时原路倒回',
    );

    collapsed.value = false;
    await step(60);
    // 展开过程中圆盘仍在转（转速随 t 渐出），所以角度允许**继续向前**走一点；
    // 关键是不许倒退。取环形差：旧写法此处 280.8° → 0°，环形前向量为 79.2°。
    final forward = ((coverAngleOf(tester) - collapsedAngle) % 360 + 360) % 360;
    expect(
      forward,
      lessThan(20.0),
      reason: '展开必须停在当前角度继续向前，不能把封面倒回原位',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('共存：一级退回常驻条不得连带抑制内层导航的二级路由（双栏详情面板）', (
    tester,
  ) async {
    // DesktopTwoPane 的详情面板 = 另一条内层 Navigator 上 push 出来的路由，
    // 它在元素树上仍是外壳宿主的后代。所以退回分支**不能**打 scope 标记，
    // 否则右栏的悬浮条会被一起抑制，共存形态消失。
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerOnPrimaryPages.value = false;
    final detailNav = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      hostOnPrimaryRoute(
        child: Navigator(
          key: detailNav,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(SecondaryMiniPlayer),
      findsNothing,
      reason: '一级页面已退回常驻条，外壳宿主不该渲染悬浮条',
    );

    detailNav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const SecondaryMiniPlayerHost(child: SizedBox()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(SecondaryMiniPlayer),
      findsOneWidget,
      reason: '内层导航的二级路由（详情面板）必须无视一级的退回，照常出悬浮条',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— 自动收缩的作用域：只给二级页面 ——

  /// 足够长的列表，保证滚动位移能超过收起阈值（24dp）。
  Widget scrollList() => ListView(
    children: [
      for (var i = 0; i < 60; i++) SizedBox(height: 60, child: Text('$i')),
    ],
  );

  testWidgets('一级页面：向下滚动不收缩（常驻展开态胶囊）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(hostOnPrimaryRoute(child: scrollList()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final expanded = tester.getRect(capsule(tester));
    expect(expanded.width, closeTo(_kPhonePortrait.width - 32.0, 0.5));

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getRect(capsule(tester)).width,
      closeTo(expanded.width, 0.5),
      reason: '主页下方已有导航栏，再收成圆盘等于长期藏起播放信息，一级页面必须常驻展开',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('标题居中的 tab（可选 tab 未显示，如搜索）按二级页面处理：仍可收缩', (
    tester,
  ) async {
    // 判据与页面标题同源：只有**左对齐**才算一级页面。search 属 kOptionalTabs、
    // 默认隐藏 → visibleIndexOf 为 -1 → 标题居中 → 该照常收缩。
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(
      hostOnPrimaryRoute(child: scrollList(), tabId: 'search'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getRect(capsule(tester)).width,
      closeTo(_kPhonePortrait.width - 32.0, 0.5),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getRect(capsule(tester)).width,
      closeTo(64.0, 0.5),
      reason: '居中标题的页面不是"一级页面"，滚动仍应收成圆盘',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('标题居中的**可见** tab（排行榜）仍按二级页面处理：可收缩', (
    tester,
  ) async {
    // 判据与「不回缩」同源，且**不能只看 tab 是否可见**：charts 在 kOptionalTabs 里
    // 默认隐藏，这里显式把它放进 settings_tab_order 让它**在导航栏可见**，同时它的
    // pinnedTitle 仍为 false（标题居中）→ 只有标题对齐判据能把它归到二级、照常收缩。
    // 这正是与上一条「未显示的 search」用例的区别：本例覆盖的是「可见但居中」这一档。
    // （历史用例用 library，但 0d5851d 后 library 已改标 pinnedTitle=true，不再适配，
    //  故换成仍保持标题居中的 charts。）
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings_tab_order': <String>['discover', 'charts'],
      'settings_hidden_tabs': <String>[],
    });
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(
      hostOnPrimaryRoute(child: scrollList(), tabId: 'charts'),
    );
    await tester.pump();
    // 多 pump 两帧让 TabConfigProvider 的异步 _load 落地（charts 进入 visibleTabs），
    // 确保断言发生在「charts 确实可见」之后，才真正测到「可见但居中」这一档。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getRect(capsule(tester)).width,
      closeTo(_kPhonePortrait.width - 32.0, 0.5),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getRect(capsule(tester)).width,
      closeTo(64.0, 0.5),
      reason: '标题居中的可见 tab 不是"一级页面"，滚动应收成圆盘',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('二级页面：向下滚动收起为圆盘、向上滚动再展开（原行为不变）', (
    tester,
  ) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    await tester.pumpWidget(hostOnSecondaryRoute(child: scrollList()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getRect(capsule(tester)).width,
      closeTo(64.0, 0.5),
      reason: '二级页面仍需让位给正文',
    );

    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getRect(capsule(tester)).width,
      closeTo(_kPhonePortrait.width - 32.0, 0.5),
      reason: '向上滚动应回到展开态',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— 进度指示（设置页开关 + 2fps 采样）——

  Finder progressLayer(WidgetTester t) => find.descendant(
    of: find.byType(SecondaryMiniPlayer),
    matching: find.byKey(const ValueKey('secondary-player-progress')),
  );

  testWidgets('进度指示：开关开 + 时长已知才绘制；关开关或时长未知即撤', (
    tester,
  ) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = false;
    player.setDuration(const Duration(seconds: 120));
    await tester.pumpWidget(host());
    await tester.pump();
    expect(progressLayer(tester), findsOneWidget);

    kSecondaryPlayerProgressEnabled.value = false;
    await tester.pump();
    expect(
      progressLayer(tester),
      findsNothing,
      reason: '设置页关掉后不得再画进度（运行时即时生效）',
    );

    kSecondaryPlayerProgressEnabled.value = true;
    player.setDuration(null);
    await tester.pump();
    expect(
      progressLayer(tester),
      findsNothing,
      reason: '时长未知时进度无意义，既不绘制也不采样',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('进度采样：播放中建的 2fps 定时器，卸载时必须取消', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    player.setDuration(const Duration(seconds: 120));
    await tester.pumpWidget(host());
    await tester.pump();
    // 跑几拍让定时器确实建起来
    await tester.pump(const Duration(milliseconds: 1200));
    expect(progressLayer(tester), findsOneWidget);

    // 若 dispose 没 cancel Timer，flutter_test 会在用例结束时判失败
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('进度采样：暂停 / 全屏播放器覆盖时不保留定时器', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    collapsed.value = true;
    player.setDuration(const Duration(seconds: 120));
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    player.simulate(playing: false);
    await tester.pump();
    playerExpansion.value = 1.0;
    await tester.pump();
    // 同样：未取消的 Timer 会让这条用例以 "A Timer is still pending" 失败
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpWidget(const SizedBox());
    playerExpansion.value = 0.0;
  });

  // —— 一级页面形态分级（设置项：一级页面是否使用悬浮底栏）——

  /// 在一级页面宿主下挂一个探针，读出宿主注入的底部预留（渲染悬浮条 = 76，透传 = 0）。
  Future<double> probePrimaryRouteBottom(WidgetTester tester) async {
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnPrimaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();
    return probedBottom;
  }

  testWidgets('一级页面退回常驻条：不渲染悬浮播放器也不注入底部预留', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerOnPrimaryPages.value = false;

    final probedBottom = await probePrimaryRouteBottom(tester);

    expect(
      find.byType(SecondaryMiniPlayer),
      findsNothing,
      reason: '关掉一级页面悬浮底栏后，主页应由 shell 的常驻条承载',
    );
    // 常驻条占真实布局空间（Column），宿主不该再注入预留，否则底部空出一条
    expect(probedBottom, closeTo(0.0, 0.5));
    // 常驻条由 _MainLayout 渲染，不在本测试宿主内；宿主也不该自己补一条
    expect(find.byType(MiniPlayer), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('一级页面退回常驻条：自包裹的 tab 页同样被抑制', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerOnPrimaryPages.value = false;

    // 模拟 DiscoverPage / ChartsPage：页面自身又包了一层宿主。
    // 一二级归属是**按路由**判定的，内层宿主同属栈底路由 → 自行得出同样结论。
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnPrimaryRoute(
        child: SecondaryMiniPlayerHost(
          // DiscoverPage 与其 AppBar 同源声明 tabId（否则会被判成二级页面）
          tabId: 'discover',
          child: Builder(
            builder: (context) {
              probedBottom = MediaQuery.paddingOf(context).bottom;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(SecondaryMiniPlayer),
      findsNothing,
      reason: '内层自包裹的宿主也必须透传，否则主页会出现两条播放器',
    );
    expect(probedBottom, closeTo(0.0, 0.5));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('退回常驻条时，标题居中的可见 tab 仍用悬浮条（判据与不回缩同源）', (
    tester,
  ) async {
    // charts 在导航栏可见（下方显式把它放进 tab_order）但标题居中 → 归二级。
    // 若退回条件只看栈底路由，它会被 shell 补一条常驻条、自己又画一条悬浮条 → 同屏两条。
    // （历史用例用 library，但 library 已改标 pinnedTitle=true → 归一级，不再适配，
    //  换成仍保持标题居中的 charts，覆盖「可见但居中」这一档。）
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings_tab_order': <String>['discover', 'charts'],
      'settings_hidden_tabs': <String>[],
    });
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerOnPrimaryPages.value = false;
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnPrimaryRoute(
        tabId: 'charts',
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();
    // 让 TabConfigProvider 异步 _load 落地，charts 进入 visibleTabs 后再断言。
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(SecondaryMiniPlayer),
      findsOneWidget,
      reason: '居中标题 = 二级页面，设置关着也该保留悬浮条',
    );
    expect(
      probedBottom,
      closeTo(76.0, 0.5),
      reason: '渲染了悬浮条就必须注入底部预留，否则末项被遮挡',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('二级页面不受该开关影响：仍渲染悬浮条并预留底部', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerOnPrimaryPages.value = false;
    double probedBottom = -1;
    await tester.pumpWidget(
      hostOnSecondaryRoute(
        child: Builder(
          builder: (context) {
            probedBottom = MediaQuery.paddingOf(context).bottom;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);
    expect(probedBottom, closeTo(76.0, 0.5));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('运行时切换该开关：一级页面形态即时生效', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await probePrimaryRouteBottom(tester);
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);

    kSecondaryPlayerOnPrimaryPages.value = false;
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsNothing);

    kSecondaryPlayerOnPrimaryPages.value = true;
    await tester.pump();
    expect(find.byType(SecondaryMiniPlayer), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // —— 退回常驻条时的槽位（PrimaryPagePersistentBar，挂在每个 tab 根内容底部）——

  /// 与 [hostOnPrimaryRoute] 同一套 provider，但内容放进 tab 根路由的 Column 里。
  ///
  /// [navigatorKey] 非空时用它建 MaterialApp，便于再 push 一条二级路由验证槽位
  /// 会自动让位（二级页面归自己的悬浮条承载）。
  Widget persistentBarRoute({
    String tabId = 'discover',
    GlobalKey<NavigatorState>? navigatorKey,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<TabConfigProvider>(
          create: (_) => TabConfigProvider(),
        ),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              PrimaryPagePersistentBar(tabId: tabId),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('槽位只在「总开关开 + 一级退回 + 该 tab 为一级页面」时渲染常驻条', (
    tester,
  ) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerOnPrimaryPages.value = false;

    await tester.pumpWidget(persistentBarRoute());
    await tester.pump();
    expect(
      find.byType(MiniPlayer),
      findsOneWidget,
      reason: '一级页面退回常驻条，槽位必须真的把 MiniPlayer 画出来',
    );

    // 一级页面改用悬浮条：常驻条整条消失，由外层宿主画悬浮条。
    kSecondaryPlayerOnPrimaryPages.value = true;
    await tester.pump();
    expect(find.byType(MiniPlayer), findsNothing);

    // 总开关关：常驻条由壳层最外层统一承载，槽位不能再各挂一份。
    kSecondaryPlayerOnPrimaryPages.value = false;
    kSecondaryPlayerEnabled.value = false;
    await tester.pump();
    expect(find.byType(MiniPlayer), findsNothing);

    kSecondaryPlayerEnabled.value = true;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('槽位对标题居中的 tab 与二级路由都让位（改由悬浮条承载）', (
    tester,
  ) async {
    _setViewport(tester, _kPhonePortrait);
    kSecondaryPlayerOnPrimaryPages.value = false;

    // charts 标题居中 → 归二级，常驻条槽位必须让位，否则与它的悬浮条同屏两条。
    await tester.pumpWidget(persistentBarRoute(tabId: 'charts'));
    await tester.pump();
    expect(find.byType(MiniPlayer), findsNothing);

    // 同一个一级 tab，被 push 成二级路由后同样要让位。
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(persistentBarRoute(navigatorKey: navKey));
    await tester.pump();
    expect(find.byType(MiniPlayer), findsOneWidget);

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              PrimaryPagePersistentBar(tabId: 'discover'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(MiniPlayer),
      findsNothing,
      reason: '二级页面的可见树里不得再有常驻条，否则与它的悬浮条同屏两条',
    );
    expect(
      find.byType(MiniPlayer, skipOffstage: false),
      findsOneWidget,
      reason: '栈底那条只是被不透明路由盖住，返回时原样露出',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // —— H2 绑定/解绑矩阵（批次 0：形变维度收口 + 收敛解绑 + 折半角速度）——

  group('H2 旋转驱动绑定/解绑矩阵', () {
    testWidgets('展开态（_morph=0）播放：不挂旋转驱动', (tester) async {
      // 展开态圆盘角度被 morph 乘成 0，本不该产帧；批次 0 前 _spin 作为唯一
      // 通知源仍每 16ms 提交一帧。收口条件加了 `_morph.value > 0`，展开态必须不订阅。
      _setViewport(tester, _kPhonePortrait);
      collapsed.value = false; // 展开态
      await tester.pumpWidget(host());
      await tester.pump();

      expect(
        PlayerFrameDriver.instance.hasListeners,
        isFalse,
        reason: '展开态圆盘不转，不得挂共享 60fps 节拍（否则画面静止仍每 16ms 产帧）',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('圆盘态（_morph=1）播放：挂旋转驱动', (tester) async {
      _setViewport(tester, _kPhonePortrait);
      collapsed.value = true; // 圆盘态（setUp 默认也是 true，显式写明语义）
      await tester.pumpWidget(host());
      await tester.pump();

      expect(
        PlayerFrameDriver.instance.hasListeners,
        isTrue,
        reason: '圆盘真在转才挂共享节拍（§10.3）',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('从圆盘切到展开、弹簧收敛后自动解绑（末帧无 build 的收口）', (
      tester,
    ) async {
      // 展开动画收敛不保证伴随末帧 build，[_onMorphStatusChanged]（completed/dismissed）
      // 是唯一解绑时机——漏掉即共享节拍绑定残留（§10.4.3，批次 0 修复点）。
      _setViewport(tester, _kPhonePortrait);
      collapsed.value = true;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(PlayerFrameDriver.instance.hasListeners, isTrue);

      // 切到展开：弹簧把 _morph 收敛到 0。播放中共享 Timer 会让 pumpAndSettle 不
      // 收敛，故逐帧 pump 并以其退出循环（收敛即解绑）。
      collapsed.value = false;
      var guard = 0;
      while (PlayerFrameDriver.instance.hasListeners && guard < 200) {
        await tester.pump(const Duration(milliseconds: 16));
        guard++;
      }

      expect(
        PlayerFrameDriver.instance.hasListeners,
        isFalse,
        reason: '形变收敛到 0 后必须以同一组输入重算收口并解绑驱动',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('折半角速度不变：奇数 tick 丢弃、偶数 tick 用 2×stepRatio 步进', (
      tester,
    ) async {
      // 圆盘 12s/圈。60fps 下单帧角度差远小于视觉分辨力，故奇数 tick 整帧丢弃、
      // 偶数 tick 用 2×stepRatio 同时步进 _spin.value 与 _discAngle：帧提交减半、
      // 角速度守恒（每产出帧 = 60fps 两帧的量）。用 [coverAngleOf]（读渲染矩阵）
      // 观测 _discAngle，避免依赖真实挂钟。
      const int spinMs = 12 * 1000; // = _spin 的 duration（见被测源码）
      final double degPerProducedFrame =
          (2 * PlayerFrameDriver.step.inMilliseconds / spinMs) * 360;

      _setViewport(tester, _kPhonePortrait);
      collapsed.value = true; // 圆盘态
      player.simulate(playing: true);
      await tester.pumpWidget(host());
      // pumpWidget 与无参 pump 都不推进 fake 时钟：此刻共享节拍计时器刚随绑定建立
      // （首拍在 t=16ms），_spinTickCount 仍为 0（首拍必为偶数→步进）。
      await tester.pump();
      expect(PlayerFrameDriver.instance.hasListeners, isTrue);

      final a0 = coverAngleOf(tester); // 起始 0°
      await tester.pump(const Duration(milliseconds: 16)); // tick#1 偶→步进
      final a1 = coverAngleOf(tester);
      await tester.pump(const Duration(milliseconds: 16)); // tick#2 奇→丢弃
      final a2 = coverAngleOf(tester);
      await tester.pump(const Duration(milliseconds: 16)); // tick#3 偶→步进
      final a3 = coverAngleOf(tester);

      final forward = (double v) => ((v % 360) + 360) % 360;
      expect(
        forward(a1 - a0),
        closeTo(degPerProducedFrame, 0.2),
        reason: '单个产出帧步进 2×stepRatio（60fps 两帧的量），角速度守恒',
      );
      expect(
        forward(a2 - a1),
        closeTo(0.0, 0.05),
        reason: '奇数 tick 整帧丢弃：不产生任何角度推进',
      );
      expect(
        forward(a3 - a2),
        closeTo(degPerProducedFrame, 0.2),
        reason: '下一个偶数 tick 再步进同样的一份，帧提交减半而速率不变',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  // —— reduced-motion 代表性用例（计划 §1.3 矩阵）——

  group('reduced-motion 瞬时落位', () {
    testWidgets('_morph 在 disableAnimations 下切 collapsed 单帧即达端点', (
      tester,
    ) async {
      // 系统「移除动画」：[_onCollapsedChanged] 走 `_morph.value = target` jump，
      // 不播 320ms 弹簧。断言「pump 一帧内即落到端点值」而非动画时长。
      _setViewport(tester, _kPhonePortrait);
      collapsed.value = false; // 展开态
      await tester.pumpWidget(host(reduceMotion: true));
      await tester.pump();
      expect(
        tester.getRect(capsule(tester)).width,
        closeTo(_kPhonePortrait.width - 32.0, 0.5),
        reason: '前置：展开态胶囊撑满可用宽',
      );

      collapsed.value = true; // 请求收成圆盘
      await tester.pump(); // 仅一帧
      expect(
        tester.getRect(capsule(tester)).width,
        closeTo(64.0, 0.5),
        reason: 'reduced-motion 下形变瞬时落位，单帧即达圆盘端点（不播弹簧）',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  // —— 展开链路：场景登记（起点几何）+ 交接语义（底色/文字 vs 封面）——

  /// 封面交接层的让位透明度（[_buildMorph] 里 `key = 'secondary-player-cover-handoff'`
  /// 的那个 Opacity）。
  double coverHandoffOpacity(WidgetTester t) => t
      .widget<Opacity>(
        find.descendant(
          of: find.byType(SecondaryMiniPlayer),
          matching: find.byKey(
            const ValueKey('secondary-player-cover-handoff'),
          ),
        ),
      )
      .opacity;

  group('展开起点与交接', () {
    test('场景采集纯函数：panelRect 原样透传，形态随 collapsed 判定', () {
      const Rect panel = Rect.fromLTRB(0, 700, 400, 869);
      final PlayerMorphScene capsule = capsuleMorphScene(
        panelRect: panel,
        screenHeight: 869,
        collapsed: false,
      );
      expect(capsule.form, PlayerBarForm.floatingCapsule);
      expect(capsule.panelRect, panel, reason: '矩形不做任何二次换算');
      expect(capsule.panelTop, 700);
      expect(capsule.panelHeight, 169);
      expect(capsule.screenHeight, 869);

      final PlayerMorphScene disc = capsuleMorphScene(
        panelRect: panel,
        screenHeight: 869,
        collapsed: true,
      );
      expect(disc.form, PlayerBarForm.floatingDisc);
      expect(disc.panelRect, panel);
    });

    test('交接透明度纯函数：底色/文字 p∈[0,0.15] 内淡出，封面二进制让位', () {
      // 底色/文字：端点 1 → 0，中点 0.5，之后恒 0。
      expect(capsuleChromeOpacity(0.0), 1.0);
      expect(capsuleChromeOpacity(0.075), closeTo(0.5, 1e-9));
      expect(capsuleChromeOpacity(kCapsuleChromeFadeProgress), 0.0);
      expect(capsuleChromeOpacity(0.5), 0.0);
      expect(capsuleChromeOpacity(1.0), 0.0);

      // 封面：飞行层接管即让位（p>0 → 0），p=0 保持可见。
      expect(capsuleCoverOpacity(0.0, layerWillDraw: true), 1.0);
      expect(capsuleCoverOpacity(0.05, layerWillDraw: true), 0.0);
      expect(capsuleCoverOpacity(0.5, layerWillDraw: true), 0.0);
      // 飞行层不接管（频谱圆盘 / 减弱动画）时中途仍可见，但远端端点必须收干净。
      expect(capsuleCoverOpacity(0.5, layerWillDraw: false), 1.0);
      expect(capsuleCoverOpacity(0.98, layerWillDraw: false), 1.0);
      expect(
        capsuleCoverOpacity(kCapsuleInvisibleExpansion, layerWillDraw: false),
        0.0,
      );
      expect(capsuleCoverOpacity(1.0, layerWillDraw: false), 0.0);
    });

    testWidgets('展开态点击：push 的路由拿到「胶囊自身矩形」作为展开起点', (
      tester,
    ) async {
      _setViewport(tester, _kPhonePortrait);
      addTearDown(() => activePlayerRoute = null);
      collapsed.value = false; // 展开态
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 胶囊所在宿主 render box（与采集口径相同：锚点空间、含 SafeArea + 12dp
      // 底距，底端到屏底）。本 harness 不在 DisplayScaleScope 内，锚点空间 ≡ 根空间。
      final RenderBox box = tester.renderObject<RenderBox>(
        find.byType(SecondaryMiniPlayer),
      );
      final Rect boxRect = box.localToGlobal(Offset.zero) & box.size;
      expect(
        boxRect.bottom,
        closeTo(_kPhonePortrait.height, 0.5),
        reason: '前置：宿主底端即屏底（含底部净空的整块）',
      );
      expect(
        boxRect.height,
        closeTo(76.0, 0.5),
        reason: '前置：胶囊 64 + 12dp 底距（测试视口无底部安全区）',
      );

      await tester.tap(capsule(tester));
      // 不 pump：路由页面（FullPlayer）需要一整套 provider，本 harness 只提供
      // 播放态。push 在 tap 回调里同步完成（didPush 同步赋值 activePlayerRoute）。
      final DraggablePlayerRoute<dynamic>? route = activePlayerRoute;
      expect(route, isNotNull, reason: '展开态点击必须 push 播放页路由');
      final PlayerMorphScene? scene = route!.scene;
      expect(scene, isNotNull, reason: '胶囊点开必须带形态快照（不再什么都不传）');
      expect(scene!.form, PlayerBarForm.floatingCapsule);
      expect(
        scene.panelRect,
        boxRect,
        reason: 'panelRect 必须等于胶囊自身矩形（同空间同值），否则面板从偏低处长出',
      );
      expect(scene.screenHeight, closeTo(_kPhonePortrait.height, 0.5));
      // 面板锚点消费端：起点 = 胶囊顶端、高度 = 胶囊宿主高（含底部净空）。
      expect(
        route.panelAnchorFor(_kPhonePortrait.height),
        (top: boxRect.top, height: boxRect.height),
      );

      // 清理：把尚未构建的路由移除，避免收尾 pump 时真的 build FullPlayer。
      // 再推进 400ms 让 onTap 里 AppHaptics.click 的 300ms 定时器落地
      // （fire-and-forget，flush 掉才不会被 flutter_test 判为 pending timer）。
      route.navigator?.removeRoute(route);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('交接端点：p=0 胶囊可见、p=1 整条不可见（现状不变）', (tester) async {
      _setViewport(tester, _kPhonePortrait);
      collapsed.value = false; // 展开态
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // p=0：底色不透明、封面不透明 —— 与改动前（整条 opacity=1）逐像素等价。
      expect(
        tester.widget<Material>(capsule(tester)).color!.a,
        closeTo(1.0, 0.001),
        reason: 'p=0 底色必须满不透明',
      );
      expect(coverHandoffOpacity(tester), 1.0);

      playerExpansion.value = 1.0;
      await tester.pump();

      // p=1：底色透明 + 封面收干净 → 整条不可见（与改动前的 (1-p)=0 等价）。
      expect(
        tester.widget<Material>(capsule(tester)).color!.a,
        closeTo(0.0, 0.001),
        reason: 'p=1 底色必须回到全透明',
      );
      expect(coverHandoffOpacity(tester), 0.0, reason: 'p=1 封面也必须收干净');

      await tester.pumpWidget(const SizedBox());
    });
  });
}
