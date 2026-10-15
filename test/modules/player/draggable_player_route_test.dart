import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:md3music/core/layout/bottom_chrome_dimens.dart';
import 'package:md3music/core/theme/motion_constants.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_panel_frame.dart';
import 'package:md3music/providers/theme_provider.dart';

/// [DraggablePlayerRoute] 转场层回归测试。
///
/// 只测路由本身：builder 给一个空页面，不挂 PlayerProvider / ThemeProvider，
/// 否则就退化成集成测试（那套环境见 `test/widgets/full_player_narrow_layout_test.dart`）。
///
/// 锁死两处最容易被改回去的行为：
/// 1. [DraggablePlayerRoute.didPop] 不得同步把全局 [playerExpansion] 硬跳 0。
///    旧实现在 pop 瞬间置 0，下一帧又被 `buildTransitions` 的进度回写拉回接近 1，
///    迷你条因此闪一帧「全亮」；形变层的端点判据（p<=0 不绘制）也被整段跳过。
///    归零收口在 [DraggablePlayerRoute.dispose]。
/// 2. 进入 / 退出时长只有 [kPlayerExpandDuration] / [kPlayerCollapseDuration] 一个
///    来源：`transitionDuration` / `reverseTransitionDuration` 与
///    `createAnimationController` 都不得再各写一份数字，且退出必须快于进入。
void main() {
  const Key pageKey = Key('player-route-page');

  /// 生产环境里 ThemeProvider 是 MaterialApp 的祖先（`MaterialApp.providers`），
  /// 过渡态底色由 PlayerPanelFrame 自行解析；测试的裸 MaterialApp 也要补上，
  /// 否则会 ProviderNotFoundException。
  Widget hostApp({required GlobalKey<NavigatorState> navigatorKey}) =>
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Center(child: Text('首页'))),
        ),
      );

  setUp(() {
    // playerExpansion / activePlayerRoute 是跨用例共享的全局信号，必须复位。
    playerExpansion.value = 0.0;
    activePlayerRoute = null;
    // 锚点同样是全局：留残值会让「锚点未知时合成起点」那条用例失真。
    playerDragOriginTop = 0;
    playerDragOriginBottom = 0;
  });

  tearDown(() {
    playerExpansion.value = 0.0;
    activePlayerRoute = null;
    playerDragOriginTop = 0;
    playerDragOriginBottom = 0;
  });

  testWidgets('系统返回收起：pop 瞬间不硬跳 0，全程单调回落到 0', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      hostApp(navigatorKey: navigatorKey),
    );

    // 非拖拽模式（tap 模式）：dragOriginTop / screenHeight 均不传
    final DraggablePlayerRoute<void> route = DraggablePlayerRoute<void>(
      builder: (_) => const SizedBox.expand(key: pageKey),
    );
    navigatorKey.currentState!.push(route);
    await tester.pumpAndSettle();

    expect(find.byKey(pageKey), findsOneWidget);
    expect(
      playerExpansion.value,
      1.0,
      reason: '入场动画结束后应停在全屏态（tap 模式的位移/淡入/playerExpansion 同一条进度）',
    );
    // 控制器时长与常量同源，防止 createAnimationController 里再硬写一份
    expect(route.controller.duration, kPlayerExpandDuration);
    expect(route.controller.reverseDuration, kPlayerCollapseDuration);

    // 逐帧记录 playerExpansion 的每一次写入：只断言最终值看不出中间的「全亮帧」
    final List<double> samples = <double>[];
    void record() => samples.add(playerExpansion.value);
    playerExpansion.addListener(record);
    addTearDown(() => playerExpansion.removeListener(record));

    navigatorKey.currentState!.pop();
    expect(
      playerExpansion.value,
      1.0,
      reason: 'didPop 只登记方向与起点；当场归零即回归（迷你条全亮帧根因）',
    );

    // 收起动画确实在跑：既不是没动，也没有一步跳到底
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(samples, isNotEmpty, reason: '两帧内没有任何回写 = 收起动画没跑起来');
    expect(playerExpansion.value, lessThan(1.0));
    expect(
      samples.where((double v) => v <= 0.0),
      isEmpty,
      reason: '收起途中出现 0：pop 瞬间被硬跳 0 后又被动画回写拉回，即全亮帧闪烁',
    );
    for (int i = 1; i < samples.length; i++) {
      expect(
        samples[i],
        lessThanOrEqualTo(samples[i - 1]),
        reason: '收起过程出现回升（$samples），全亮帧闪烁',
      );
    }

    await tester.pumpAndSettle();
    expect(playerExpansion.value, 0.0, reason: '归零收口在 dispose()');
    expect(find.byKey(pageKey), findsNothing, reason: '路由应已销毁');
    expect(activePlayerRoute, isNull, reason: 'dispose 应复位全局栈顶路由');
  });

  testWidgets('dismiss() 收起同样逐帧回落，不硬跳 0', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      hostApp(navigatorKey: navigatorKey),
    );
    final DraggablePlayerRoute<void> route = DraggablePlayerRoute<void>(
      builder: (_) => const SizedBox.expand(key: pageKey),
    );
    navigatorKey.currentState!.push(route);
    await tester.pumpAndSettle();

    final List<double> samples = <double>[];
    void record() => samples.add(playerExpansion.value);
    playerExpansion.addListener(record);
    addTearDown(() => playerExpansion.removeListener(record));

    // 页内下拉/返回按钮走这条路（removeRoute，不经过 didPop）
    route.dismiss();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      samples.where((double v) => v <= 0.0),
      isEmpty,
      reason: 'dismiss 路径（removeRoute，不经过 didPop）同样不得硬跳 0',
    );

    await tester.pumpAndSettle();
    expect(playerExpansion.value, 0.0);
    expect(find.byKey(pageKey), findsNothing);
  });

  test('退出快于进入：时长比 0.55~0.75，且路由 getter 与常量同源', () {
    expect(
      kPlayerCollapseDuration < kPlayerExpandDuration,
      isTrue,
      reason: '动效准则：退出应快于进入',
    );
    final double ratio =
        kPlayerCollapseDuration.inMilliseconds /
        kPlayerExpandDuration.inMilliseconds;
    expect(
      ratio,
      inInclusiveRange(0.55, 0.75),
      reason: '退出/进入时长比应停在约 0.65，偏离过多即观感退化',
    );

    final DraggablePlayerRoute<void> route = DraggablePlayerRoute<void>(
      builder: (_) => const SizedBox.shrink(),
    );
    expect(route.transitionDuration, kPlayerExpandDuration);
    expect(route.reverseTransitionDuration, kPlayerCollapseDuration);
  });

  test('曲线库常量性质：expressive 前置冲刺、accelerate 加速离场仍成立', () {
    // 这两条曲线已不再用于播放页转场（见 panelExpandEasing / panelCollapseEasing），
    // 但 tab 切换 / 卡片入场等处仍在引用，此处只锁曲线库本身的性质。
    expect(
      M3ExpressiveMotion.expressiveEasing.transform(0.5),
      greaterThan(0.5),
      reason: 'expressive 是前置冲刺型（半程 >0.5），正是它不适合面板落位的原因',
    );
    expect(
      M3ExpressiveMotion.emphasizedAccelerateEasing.transform(0.5),
      lessThan(0.5),
      reason: 'emphasized-accelerate 是加速离场型，半程 <0.5、末端冲走',
    );
    // 端点必须严格 0/1：任何被形变层引用的曲线都靠端点做封面/槽位交接
    expect(M3ExpressiveMotion.expressiveEasing.transform(0.0), 0.0);
    expect(M3ExpressiveMotion.expressiveEasing.transform(1.0), 1.0);
    expect(M3ExpressiveMotion.emphasizedAccelerateEasing.transform(0.0), 0.0);
    expect(M3ExpressiveMotion.emphasizedAccelerateEasing.transform(1.0), 1.0);
  });

  test('面板新曲线：端点严格 0/1、位移铺满全程、末端趋缓', () {
    // 展开与收起都是“落位”过程（收起的终点是封面交接回迷你条槽位），
    // 两端都必须严格 0/1：形变层的绘制窗口与封面/文字槽位的让位判据靠端点交接。
    for (final c in [
      M3ExpressiveMotion.panelExpandEasing,
      M3ExpressiveMotion.panelCollapseEasing,
    ]) {
      expect(c.transform(0.0), 0.0);
      expect(c.transform(1.0), 1.0);
      // 半程完成度 0.6~0.9：既不能像 expressive（半程 ~0.94，冲完定格），
      // 也不能慢于线性起步。
      expect(
        c.transform(0.5),
        inInclusiveRange(0.6, 0.9),
        reason: '位移必须铺满全程，消除两端速度突变（掉帧感的来源）',
      );
      // 3/4 程 ≤0.985：末端仍有可见的减速尾巴（软着陆），但不是静止。
      expect(
        c.transform(0.75),
        lessThanOrEqualTo(0.985),
        reason: '末端趋零但要留可见落位尾巴，否则等于提前定格',
      );
    }
  });

  testWidgets('展开位移铺满全程：半程进度落在 0.5~0.9（不再前置冲刺）', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(hostApp(navigatorKey: navigatorKey));

    final DraggablePlayerRoute<void> route = DraggablePlayerRoute<void>(
      builder: (_) => const SizedBox.expand(key: pageKey),
    );
    navigatorKey.currentState!.push(route);
    await tester.pump(); // 启动 didPush 的 forward 动画
    await tester.pump(const Duration(milliseconds: 200)); // 半程（400ms）
    expect(
      playerExpansion.value,
      inInclusiveRange(0.5, 0.9),
      reason: '旧组合（300ms + expressive）此刻已 ~0.98：前 150ms 冲完、'
          '后 150ms 静止，封面/文字形变因此像冲完掉帧',
    );
    await tester.pumpAndSettle();
    expect(playerExpansion.value, 1.0);
    expect(route.controller.duration, kPlayerExpandDuration);
  });

  testWidgets('收起末端不再冲刺：半程进度已低于 0.5', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(hostApp(navigatorKey: navigatorKey));

    final DraggablePlayerRoute<void> route = DraggablePlayerRoute<void>(
      builder: (_) => const SizedBox.expand(key: pageKey),
    );
    navigatorKey.currentState!.push(route);
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump(); // 启动 reverse
    await tester.pump(const Duration(milliseconds: 130)); // 半程（260ms）
    expect(
      playerExpansion.value,
      lessThan(0.5),
      reason: '旧 emphasized-accelerate 此刻仍在 ~0.8（前半程几乎没动，'
          '全靠末端 4 倍均速冲刺交接给迷你条封面）；新曲线位移全程铺开',
    );
    await tester.pumpAndSettle();
    expect(playerExpansion.value, 0.0, reason: '归零收口仍在 dispose');
  });

  group('全部进出路径统一走双向展开面板', () {
    testWidgets('点击进入（不传 dragOriginTop）也渲染 PlayerPanelFrame', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        hostApp(navigatorKey: navigatorKey),
      );

      // 点击进入：既不传 dragOriginTop 也不传 screenHeight
      final DraggablePlayerRoute<void> route = DraggablePlayerRoute<void>(
        builder: (_) => const SizedBox.expand(key: pageKey),
      );
      navigatorKey.currentState!.push(route);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      // push 期间整条路由还挂在 Offstage 里（find 默认跳过），要显式穿透。
      // 按「页面的祖先链」判定，避免命中 MaterialApp 自带的过渡控件。
      final page = find.byKey(pageKey);
      expect(
        find.ancestor(
          of: page,
          matching: find.byType(PlayerPanelFrame, skipOffstage: false),
        ),
        findsOneWidget,
        reason: '非拖拽进入的**过渡过程中**也必须是面板，否则点击与上滑是两套观感',
      );
      expect(
        find.ancestor(
          of: page,
          matching: find.byType(FractionalTranslation, skipOffstage: false),
        ),
        findsNothing,
        reason: '抽屉上滑（15% FractionalTranslation）已被面板取代',
      );

      await tester.pumpAndSettle();
      expect(find.byType(PlayerPanelFrame), findsOneWidget);
      expect(playerExpansion.value, 1.0);
    });

    testWidgets('点击进入后的收起（返回键）同样走面板', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        hostApp(navigatorKey: navigatorKey),
      );
      final DraggablePlayerRoute<void> route = DraggablePlayerRoute<void>(
        builder: (_) => const SizedBox.expand(key: pageKey),
      );
      navigatorKey.currentState!.push(route);
      await tester.pumpAndSettle();

      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byType(PlayerPanelFrame),
        findsOneWidget,
        reason: '收起途中必须仍是面板（否则展开/收起来回切两套动画）',
      );
      await tester.pumpAndSettle();
    });

    test('panelAnchorFor：拖拽模式取捕获的测量值', () {
      final route = DraggablePlayerRoute<void>(
        builder: (_) => const SizedBox.shrink(),
        dragOriginTop: 700,
        dragOriginBottom: 780,
        screenHeight: 869,
      );
      expect(route.panelAnchorFor(869).top, 700);
      expect(route.panelAnchorFor(869).height, 80);
    });

    test('panelAnchorFor：点击进入读全局锚点', () {
      playerDragOriginTop = 640;
      playerDragOriginBottom = 720;
      addTearDown(() {
        playerDragOriginTop = 0;
        playerDragOriginBottom = 0;
      });
      final route = DraggablePlayerRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      expect(route.panelAnchorFor(869).top, 640);
      expect(route.panelAnchorFor(869).height, 80);
    });

    test('panelAnchorFor：锚点未知时合成一条贴底的胶囊几何起点', () {
      // 从歌单卡片等处直接进播放页：这次会话没碰过迷你条，拿不到测量值。
      // 仍必须走面板路径，只是起点合成；p=0 完全透明，起点估不准观感不可见。
      // 兜底**只**在移动端布局下生效，故取胶囊几何（discReservedBottom），
      // 不再用桌面播放栏高（旧 72）冒充。
      playerDragOriginTop = 0;
      playerDragOriginBottom = 0;
      final route = DraggablePlayerRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      final anchor = route.panelAnchorFor(869);
      expect(anchor.height, BottomChromeDimens.discReservedBottom);
      expect(anchor.top + anchor.height, closeTo(869, 1e-9));
      expect(anchor.top, greaterThan(0), reason: '不能合成到屏幕顶端那一条');
    });

    test('panelAnchorFor：合成起点与几何仍满足 top == dy 的不变量', () {
      playerDragOriginTop = 0;
      playerDragOriginBottom = 0;
      final route = DraggablePlayerRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      final anchor = route.panelAnchorFor(869);
      for (final p in [0.0, 0.5, 1.0]) {
        final g = playerPanelGeometry(
          progress: p,
          origin: anchor.top,
          miniHeight: anchor.height,
          screenHeight: 869,
        );
        expect(
          g.top,
          closeTo(
            playerPanelPageOffset(
              progress: p,
              origin: anchor.top,
              screenHeight: 869,
            ).dy,
            1e-9,
          ),
          reason: 'p=$p：合成起点也必须让窗口上沿与页面上沿重合',
        );
      }
    });
  });
}
