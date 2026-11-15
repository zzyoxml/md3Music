// 底栏形态交叉过渡（一级常驻条 ↔ 二级悬浮胶囊）的**回归断言**（优化组 O3）。
//
// 性能会诊（2026-10-11）在「无挂机功耗回归」结论之外，点出三处**缺断言守护**的
// 回归风险 + 一处 TV 合规残留，本文件把它们固化成可执行断言：
//   (a) 静止态不写全局进度 [kBottomBarFormProgress]（「静止零帧成本」的前提）。
//   (b) 卸载即减订阅：承载条体的页面进出 N 次后，该 notifier 的订阅者必须回落到
//       基线、不得单调增长（2026-10-10 记录过的 H1 泄漏形状）。
//   (c) 一次 push/pop 交棒结束后，处于「播放中 + 圆盘态 + 可见」的胶囊必须把
//       共享节拍（[PlayerFrameDriver]）订阅**重新建立** —— 飞行期让位会把旋转
//       订阅收口掉（`_setShouldSpin(0, false)`），机制上依赖**端点那次 rebuild**
//       纠正，这里直接钉住该纠正。
//   (d) TV 不变量：形态总开关关闭（= TV 播种态，见 `main.dart` / `app.dart` 的
//       双门控）时，形态目标恒为常驻条（0），任何页面 / 开关 / 导航组合都不翻转。
//
// (a)(b)(d) 的驱动是 `_MainLayoutState` 的逐句复刻（与
// `bottom_bar_form_flight_test.dart` 同源；**改动 app.dart 的形态驱动必须同步
// 这两个复刻**）。(c) 用承载**圆盘态**胶囊的最小 harness 直接驱动全局进度 ——
// 因为经真实导航到达「圆盘态」需要先滚动收起，成本高且与断言目标无关；直接写
// [kBottomBarFormProgress]（= 生产驱动 `_publishBarFormProgress` 的同一动作）
// 能精确复现「让位 → 端点 rebuild」这条链，强度更高、噪声更少。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/page_title_alignment.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/core/theme/motion_constants.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/bottom_bar_morph_overlay.dart';
import 'package:md3music/modules/player/secondary_mini_player.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

class _FakePlayer extends PlayerProvider {
  @override
  Song? get currentSong => const Song(
    id: 's0',
    title: '标题',
    artist: 'artist',
    album: 'album',
    duration: Duration(seconds: 60),
  );

  @override
  bool get isPlaying => true;

  @override
  Duration? get duration => const Duration(seconds: 60);

  @override
  Duration get position => const Duration(seconds: 12);
}

/// harness 的 tab：借真实预设（`pinnedTitle: true` + 默认可见），让
/// `PrimaryPagePersistentBar` 的 `isPrimaryNavPage` 判据成立（常驻条真身在树里）。
const TabItem _kPinnedTab = TabItem(
  id: 'discover',
  label: '发现',
  pinnedTitle: true,
);

/// 非一级导航页（标题居中）：形态目标恒为胶囊。
const TabItem _kUnpinnedTab = TabItem(id: 'charts', label: '排行榜');

const Size _kPhonePortrait = Size(400, 869);

void _setViewport(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
  addTearDown(tester.view.reset);
}

// ───────────────────── (b) 订阅者可观测量 ─────────────────────

/// 让位窗口的订阅者数（挂在树上、监听 [kBarFormFlightActive] 的 builder 个数）。
///
/// **为什么用「翻转开关数反应个数」**：`ValueNotifier` 不暴露公开的 listener 计数，
/// 而三处让位 builder（浮层 `BottomBarMorphOverlay`、常驻条 `MiniPlayer`、胶囊
/// `SecondaryMiniPlayer`）如今都改订阅 [bottomBarFormFlightListenable]（
/// `Listenable.merge([kBarFormFlightActive, kBottomBarFormProgress, ...])`，
/// 非 `ValueListenableBuilder<double>`，无法按类型/值 identity 计数）。翻转
/// [kBarFormFlightActive] 会通知**每一个**挂载中的订阅者，用「值真变化才通知」的
/// 语义统计反应次数即订阅者数：与「这些 builder 的挂载数」一一对应，泄漏形状
/// （host 卸载后 list 不回退）会被原样暴露。
int _formSubscribers(WidgetTester tester) {
  var hits = 0;
  void probe() => hits++;
  kBarFormFlightActive.addListener(probe);
  final bool saved = kBarFormFlightActive.value;
  kBarFormFlightActive.value = !saved; // 翻转 → 每个订阅者收到一次通知
  kBarFormFlightActive.value = saved; // 复位（订阅者再收一次，不计）
  kBarFormFlightActive.removeListener(probe);
  return hits;
}

/// 浮层那根条是否正在画（生产浮层专有 key；在树 = 正在画）。
Finder get _overlayBarText => find.descendant(
  of: find.byType(BottomBarMorphOverlay),
  matching: find.byKey(const ValueKey<String>('morph-bar-text')),
);

// ───────────────────── 驱动复刻（_MainLayoutState） ─────────────────────

class _BarFormHarness extends StatefulWidget {
  const _BarFormHarness({
    super.key,
    required this.player,
    required this.carMode,
    this.floatingEnabled = true,
    this.railLayout = false,
  });

  final PlayerProvider player;
  final CarModeProvider carMode;

  /// 形态总开关的初始值。false = TV 播种态（见 (d) 用例）。
  final bool floatingEnabled;

  /// 横屏 rail 布局档位（镜像生产 `usesNavigationRail` 读数；默认竖屏）。
  final bool railLayout;

  @override
  State<_BarFormHarness> createState() => _BarFormHarnessState();
}

class _BarFormHarnessState extends State<_BarFormHarness>
    with TickerProviderStateMixin {
  final GlobalKey<ResponsiveShellState> _shellKey =
      GlobalKey<ResponsiveShellState>();

  List<TabItem> _tabs = const <TabItem>[_kPinnedTab];
  final int _selectedIndex = 0;

  /// 推迟上报的二级态（对应生产 `_secondaryPageOnTop`，只喂 hideNavigation）。
  bool _secondaryPageOnTop = false;

  /// 导航时刻的形态事实（对应生产 `_formSecondaryOnTop`）。
  bool _formSecondaryOnTop = false;
  int _lastSyncedTabIndex = 0;

  late final AnimationController _barFormController;
  late final CurvedAnimation _barFormCurve;
  bool _barFormTargetIsCapsule = false;

  @override
  void initState() {
    super.initState();
    kSecondaryPlayerEnabled.value = widget.floatingEnabled;
    kSecondaryPlayerOnPrimaryPages.value = false;
    _barFormTargetIsCapsule = _resolveBarFormTargetIsCapsule();
    _lastSyncedTabIndex = _selectedIndex;
    _barFormController = AnimationController(
      vsync: this,
      duration: kBottomChromeToggleDuration,
      value: _barFormTargetIsCapsule ? 1.0 : 0.0,
    );
    _barFormCurve = CurvedAnimation(
      parent: _barFormController,
      curve: M3ExpressiveMotion.panelCollapseEasing,
      reverseCurve: M3ExpressiveMotion.panelExpandEasing,
    );
    _barFormController.addListener(_publish);
    _barFormController.addStatusListener(_onStatusChanged);
    kSecondaryPlayerEnabled.addListener(_onSettingChanged);
    kSecondaryPlayerOnPrimaryPages.addListener(_onSettingChanged);
    _publish();
  }

  @override
  void dispose() {
    kSecondaryPlayerEnabled.removeListener(_onSettingChanged);
    kSecondaryPlayerOnPrimaryPages.removeListener(_onSettingChanged);
    _barFormController.removeStatusListener(_onStatusChanged);
    _barFormController.removeListener(_publish);
    _barFormController.dispose();
    super.dispose();
  }

  void _publish() {
    kBottomBarFormProgress.value = _barFormCurve.value;
  }

  // ── 以下 _sync* / _start* / _snap* / _verify* 与 app.dart 同名方法逐句对照 ──
  // （kTvBuild 早退不在此复刻：测试构建 kTvBuild 恒 false，且 kTvBuild 分支在
  //  AOT 下被树摇剔除 —— TV 不变量的可运行等价判据见 (d) 用 floatingEnabled=false。）

  bool _resolveBarFormTargetIsCapsule() {
    final tabs = _tabs;
    final tab = tabs.isEmpty
        ? null
        : tabs[_selectedIndex.clamp(0, tabs.length - 1)];
    return resolveBottomBarFormTarget(
          floatingEnabled: kSecondaryPlayerEnabled.value,
          onPrimaryPages: kSecondaryPlayerOnPrimaryPages.value,
          pageIsPrimaryNav: isPrimaryNavTab(
            tab,
            pushedRoute: _formSecondaryOnTop,
          ),
        ) >=
        0.5;
  }

  void _onPageRouteEvent(
    bool hasPushedPage,
    Route<dynamic> route,
    Duration transition,
  ) {
    if (!mounted) return;
    final bool factChanged = hasPushedPage != _formSecondaryOnTop;
    _formSecondaryOnTop = hasPushedPage;
    if (!factChanged) {
      _syncBarFormTarget(cause: BarFormFlipCause.ambient);
      return;
    }
    _syncBarFormTarget(
      cause: BarFormFlipCause.navigation,
      transition: transition,
      navRoute: route,
    );
  }

  void _onSettingChanged() {
    _syncBarFormTarget(cause: BarFormFlipCause.settingsToggle);
  }

  void _syncBarFormTarget({
    BarFormFlipCause? cause,
    Duration? transition,
    Route<dynamic>? navRoute,
  }) {
    if (!mounted) return;
    final int tabIndex = _selectedIndex;
    final bool tabChanged = tabIndex != _lastSyncedTabIndex;
    _lastSyncedTabIndex = tabIndex;
    final resolvedCause =
        cause ??
        (tabChanged ? BarFormFlipCause.tabSwitch : BarFormFlipCause.ambient);
    if (tabChanged) {
      _formSecondaryOnTop =
          _shellKey.currentState?.currentTabHasPushedPage() ?? false;
    }
    final target = _resolveBarFormTargetIsCapsule();
    if (target == _barFormTargetIsCapsule) return;
    _barFormTargetIsCapsule = target;
    switch (resolvedCause) {
      case BarFormFlipCause.navigation:
        final duration = resolveMorphFlightDuration(
          transition: transition ?? Duration.zero,
          navWillToggle: _barFormNavWillToggle(),
        );
        if (target) {
          _startBarFormFlight(
            duration,
            capsuleNavHiddenAtSettle: kHideNavBarOnSecondaryPages.value,
          );
          _verifyPushedPageHasCapsule(navRoute);
        } else {
          if (!BottomBarMorphRegistry.instance.hasCapsuleForRoute(navRoute)) {
            _snapBarFormToTarget();
            return;
          }
          _startBarFormFlight(
            duration,
            capsuleNavHiddenAtSettle: kHideNavBarOnSecondaryPages.value,
          );
        }
      case BarFormFlipCause.settingsToggle:
      case BarFormFlipCause.tabSwitch:
        _startBarFormFlight(
          kBottomChromeToggleDuration,
          capsuleNavHiddenAtSettle: false,
        );
      case BarFormFlipCause.ambient:
        _snapBarFormToTarget();
    }
  }

  // 与 app.dart 生产实现逐句对照：横屏 rail 分支恒随二级页翻转顺延，
  // 竖屏分支受 kHideNavBarOnSecondaryPages 门控。
  bool _barFormNavWillToggle() {
    if (widget.railLayout) {
      return _formSecondaryOnTop != _secondaryPageOnTop;
    }
    return (_formSecondaryOnTop && kHideNavBarOnSecondaryPages.value) !=
        (_secondaryPageOnTop && kHideNavBarOnSecondaryPages.value);
  }

  void _startBarFormFlight(
    Duration duration, {
    required bool capsuleNavHiddenAtSettle,
  }) {
    BottomBarMorphRegistry.instance.freezeResidentRectForFlight(
      capsuleNavHiddenAtSettle: capsuleNavHiddenAtSettle,
    );
    _barFormController.duration = duration;
    if (_barFormTargetIsCapsule) {
      _barFormController.forward();
    } else {
      _barFormController.reverse();
    }
  }

  void _snapBarFormToTarget() {
    _barFormController.stop();
    BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    void apply() {
      if (!mounted) return;
      _barFormController.value = _barFormTargetIsCapsule ? 1.0 : 0.0;
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    }
  }

  void _verifyPushedPageHasCapsule(Route<dynamic>? route) {
    if (route == null) return;
    var attempts = 0;
    void check() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_barFormTargetIsCapsule) return;
        if (BottomBarMorphRegistry.instance.hasCapsuleForRoute(route)) return;
        if (attempts++ == 0) {
          check();
          return;
        }
        _snapBarFormToTarget();
      });
    }

    check();
  }

  // ── 测试钩子 ──

  void debugSetTabs(List<TabItem> tabs) {
    setState(() => _tabs = tabs);
  }

  /// 生产同款：shell 的推迟上报直接落成 hideNavigation 的输入。
  void _onSecondaryReport(bool secondary) {
    if (!mounted || _secondaryPageOnTop == secondary) return;
    setState(() => _secondaryPageOnTop = secondary);
  }

  @override
  Widget build(BuildContext context) {
    // 生产 _MainLayoutState.build 帧末统一重算目标（幂等）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncBarFormTarget();
    });
    final String currentTabId = _tabs.isEmpty
        ? 'discover'
        : _tabs[_selectedIndex.clamp(0, _tabs.length - 1)].id;
    return ResponsiveScaffold(
      destinations: const <NavigationDestination>[
        NavigationDestination(icon: Icon(Icons.explore_outlined), label: '发现'),
        NavigationDestination(icon: Icon(Icons.bar_chart), label: '排行榜'),
      ],
      railDestinations: const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.explore_outlined),
          label: Text('发现'),
        ),
        NavigationRailDestination(icon: Icon(Icons.bar_chart), label: Text('排行榜')),
      ],
      drawerDestinations: const <NavigationDrawerDestination>[],
      selectedIndex: _selectedIndex,
      onDestinationSelected: (_) {},
      hideNavigation: _secondaryPageOnTop && kHideNavBarOnSecondaryPages.value,
      hideRailNavigation: _secondaryPageOnTop,
      body: SecondaryMiniPlayerHost(
        ownsBottomBar: true,
        tabId: currentTabId,
        child: ResponsiveShell(
          key: _shellKey,
          visibleTabs: _tabs,
          selectedIndex: _selectedIndex,
          pageBuilder: (_) => const _LevelOnePage(),
          persistentBarBuilder: (tabId) =>
              PrimaryPagePersistentBar(tabId: tabId),
          onSecondaryRouteChanged: _onSecondaryReport,
          onPageRouteEvent: _onPageRouteEvent,
        ),
      ),
    );
  }
}

/// 一级页面：一个 push 入口（挂条的二级页面）。
class _LevelOnePage extends StatelessWidget {
  const _LevelOnePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const _LevelTwoPage()),
          ),
          child: const Text('push'),
        ),
      ),
    );
  }
}

/// 二级页面：生产形态 = 页面自包裹 SecondaryMiniPlayerHost。
class _LevelTwoPage extends StatelessWidget {
  const _LevelTwoPage();

  @override
  Widget build(BuildContext context) {
    return SecondaryMiniPlayerHost(
      tabId: 'discover',
      child: Scaffold(
        backgroundColor: const Color(0xFF303030),
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('back'),
          ),
        ),
      ),
    );
  }
}

void main() {
  late _FakePlayer player;
  late CarModeProvider carMode;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    kBottomBarFormProgress.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = false;
    kHideNavBarOnSecondaryPages.value = true;
    // 双栏开关三端通用后，discover tab 的双栏形态需显式开启（生产播种 true）。
    kWindowsTwoPaneEnabled.value = true;
    BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    player = _FakePlayer();
    // 生产不变量：`_updatePosition` 把 `_position` 与 `positionNotifier` 一起写
    // （player_provider.dart:733-738），两者永远同值。假播放器只覆写 `position`
    // getter，这里显式同步 notifier。
    player.positionNotifier.value = player.position;
    carMode = CarModeProvider();
  });

  tearDown(() {
    kBottomBarFormProgress.value = 0.0;
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = true;
    kHideNavBarOnSecondaryPages.value = true;
    kWindowsTwoPaneEnabled.value = false;
    player.dispose();
    carMode.dispose();
  });

  /// 启动 harness 并稳定（tab 配置装载、导航栏就位），返回 host State 句柄。
  Future<GlobalKey<_BarFormHarnessState>> pumpHarness(
    WidgetTester tester, {
    bool floatingEnabled = true,
  }) async {
    _setViewport(tester, _kPhonePortrait);
    final key = GlobalKey<_BarFormHarnessState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: <SingleChildWidget>[
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
          ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<TabConfigProvider>(
            create: (_) => TabConfigProvider(),
          ),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: _kPhonePortrait),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _BarFormHarness(
                  key: key,
                  player: player,
                  carMode: carMode,
                  floatingEnabled: floatingEnabled,
                  // 本文件只覆盖竖屏档位；横屏 rail 档位的镜像见
                  // bottom_bar_form_flight_test.dart 的横屏用例。
                  railLayout: false,
                ),
                const BottomBarMorphOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return key;
  }

  // ═══════════════════════ (a) 静止态不写全局进度 ═══════════════════════
  testWidgets('(a) 静止态（无飞行）不写全局进度：60 帧零通知、值恒为端点', (tester) async {
    await pumpHarness(tester);
    expect(kBottomBarFormProgress.value, 0.0, reason: '一级页面停在常驻条端点');

    // 探针挂在**真实** notifier 上，统计 notifyListeners 次数。
    var notifications = 0;
    void probe() => notifications++;
    kBottomBarFormProgress.addListener(probe);
    addTearDown(() => kBottomBarFormProgress.removeListener(probe));

    final values = <double>[];
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      values.add(kBottomBarFormProgress.value);
    }

    expect(values.every((v) => v == 0.0), isTrue,
        reason: '静止态进度被写成非端点值：$values');
    debugPrint('[O3-a] 静止 60 帧：值恒为端点 0.0，通知次数=$notifications');
    expect(notifications, 0,
        reason: '静止态仍有进度通知（$notifications 次）——静止零帧成本的前提被破坏');

    // 探针自检（证明它捕获的是"值真的变了"而非恒不响）：手动写一个不同值必须
    // 触发一次通知，写回端点再触发一次。
    // 见下方报告里的强度边界：ValueNotifier 的 `value=` 对**同值写入短路**
    // （不 notify、不重建），故"同值写入"既不产生成本、也不可观测 —— 本探针
    // 统计的正是**有成本的那类写入**。
    kBottomBarFormProgress.value = 0.25;
    expect(notifications, 1, reason: '探针自检失败：写入不同值必须通知一次');
    kBottomBarFormProgress.value = 0.0;
    expect(notifications, 2, reason: '探针自检失败：写回端点必须再通知一次');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ═══════════════════════ (b) 卸载即减订阅（H1 泄漏形状） ═══════════════════════
  testWidgets('(b) 进出承载条体的页面 N 次：notifier 订阅者回落到基线、不单调增长',
      (tester) async {
    await pumpHarness(tester);
    await tester.pumpAndSettle();

    final int baseline = _formSubscribers(tester);
    expect(baseline, greaterThanOrEqualTo(2),
        reason: '基线至少含浮层 + 一级常驻条两个订阅者，实测 $baseline');

    final pushCounts = <int>[];
    final popCounts = <int>[];
    for (var cycle = 0; cycle < 3; cycle++) {
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      final int onSecondary = _formSubscribers(tester);
      pushCounts.add(onSecondary);
      // push 后多一个二级宿主让位订阅者（上限，不硬等 —— 挂载点数量随宿主叠层
      // 变化）；关键是**不单调增长**（下一轮 push 仍应是同值，见下方 toSet 断言）。
      expect(onSecondary, lessThanOrEqualTo(baseline + 1),
          reason: '第 $cycle 次 push 后订阅者超上限（基线 $baseline，实测 $onSecondary）');

      await tester.tap(find.text('back'));
      await tester.pumpAndSettle();
      final int backHome = _formSubscribers(tester);
      popCounts.add(backHome);
      expect(backHome, baseline,
          reason: '第 $cycle 次 pop 后订阅者必须回落到基线（$baseline），实测 $backHome'
              ' —— 不回退即 H1 泄漏形状（2026-10-10 记录过）');
    }

    expect(pushCounts.toSet().length, 1,
        reason: 'push 后订阅者数逐轮漂移：$pushCounts（单调增长即泄漏）');
    expect(popCounts.toSet().length, 1,
        reason: 'pop 后订阅者数逐轮漂移：$popCounts');
    debugPrint('[O3-b] 订阅者基线=$baseline push计数=$pushCounts pop计数=$popCounts');

    // 端到端行为判据：卸载后对 notifier 写一个不同值，不得有任何已卸载订阅者
    // 抛错（`setState() called after dispose()` 之类会在这里现形）。
    kBottomBarFormProgress.value = 0.5;
    await tester.pump();
    kBottomBarFormProgress.value = 0.0;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ═══════════════════════ (c) 交棒结束后圆盘恢复旋转 ═══════════════════════
  testWidgets('(c) 交棒让位收口旋转订阅，端点 rebuild 必须重新挂共享节拍', (tester) async {
    // 前置不变量：本组用例前驱动无订阅残留（(a)(b) 的胶囊是展开态，不挂节拍）。
    expect(PlayerFrameDriver.instance.hasListeners, isFalse,
        reason: '前置：上一用例必须已解绑共享节拍');

    final collapsed = ValueNotifier<bool>(true); // 圆盘态
    addTearDown(collapsed.dispose);
    final discPlayer = _FakePlayer();
    addTearDown(discPlayer.dispose);
    final discCarMode = CarModeProvider();
    addTearDown(discCarMode.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: <SingleChildWidget>[
          ChangeNotifierProvider<PlayerProvider>.value(value: discPlayer),
          ChangeNotifierProvider<CarModeProvider>.value(value: discCarMode),
          ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: _kPhonePortrait),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                SecondaryMiniPlayer(
                  collapsed: collapsed,
                  onRequestExpand: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 起飞态：播放中 + 圆盘态 + 可见 → 已挂共享节拍。
    expect(PlayerFrameDriver.instance.hasListeners, isTrue,
        reason: '播放中 + 圆盘态 + 可见的胶囊必须挂共享节拍');
    expect(PlayerFrameDriver.instance.isRunning, isTrue,
        reason: '有订阅者时共享节拍定时器必须在跑');

    // 交棒飞行中：让位 → 旋转订阅必须收口（否则不可见仍在产帧，§10.4.3）。
    kBottomBarFormProgress.value = 0.5;
    kBarFormFlightActive.value = true;
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isFalse,
        reason: '飞行让位期必须解绑共享节拍（_setShouldSpin(0, false)）');

    // 飞行结束到胶囊端点：**端点那次 rebuild** 必须重新建立订阅 —— 这正是会诊
    // 指出的"依赖端点那次 rebuild 纠正 `_lastSpinPlaying=false`"的那一步。
    kBarFormFlightActive.value = false;
    kBottomBarFormProgress.value = 1.0;
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isTrue,
        reason: '交棒结束后圆盘必须恢复旋转（端点 rebuild 未重挂共享节拍 = O3(c) 回归）');

    // 行为判据：共享节拍真的在推进圆盘角度（Transform.rotate 的矩阵 m10 = sin(角)）。
    double? discSin() {
      final f = find.descendant(
        of: find.byType(SecondaryMiniPlayer),
        matching: find.byWidgetPredicate(
          (w) => w is Transform && w.transform.storage[1] != 0.0,
        ),
      );
      if (f.evaluate().isEmpty) return null;
      return tester.widget<Transform>(f.first).transform.storage[1];
    }

    await tester.pump(const Duration(milliseconds: 16));
    final double? s0 = discSin();
    expect(s0, isNotNull, reason: '共享节拍首拍后圆盘角度应为非零（封面正在转）');
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final double? s1 = discSin();
    expect(s1, isNotNull);
    debugPrint('[O3-c] 圆盘旋转矩阵 m10(sin)：交棒后 $s0 → 4 拍后 $s1');
    expect((s1! - s0!).abs(), greaterThan(1e-3),
        reason: '共享节拍未推进圆盘角度（$s0 → $s1）：订阅在但没在转');

    // 卸载即回落（与 (b) 同一泄漏形状的单元级判据）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(PlayerFrameDriver.instance.hasListeners, isFalse,
        reason: '胶囊卸载后共享节拍订阅必须回落到零');
    expect(tester.takeException(), isNull);
  });

  // ═══════════════════════ (d) TV 不变量：总开关关闭 ⇒ 恒不翻转 ═══════════════════════
  //
  // TV 版形态总开关在装载处被**双门控强制 false**（`main.dart:241` 与
  // `app.dart:1756` 的 `effective = kTvBuild ? false : enabled`），设置页开关在
  // `kTvBuild` 下 `onChanged: null` 置灰（`settings_page.dart:2559`），从属项随
  // 总开关关闭一并置灰（同文件 2576/2591）。于是 TV 的可运行后果 = 形态总开关恒
  // false。故这里用 `floatingEnabled: false` 的 harness 钉住该后果的直接推论：
  // **无论页面层级 / tab 配置 / 开关组合 / 导航如何变，形态目标恒为常驻条（0）、
  // 进度恒 0、浮层恒不渲染**。这条断言在普通构建即可跑（kTvBuild 是编译期常量，
  // 无法在测试里翻转），是 TV 不变量的最强可运行等价判据。
  testWidgets('(d) 总开关关闭（TV 播种态）：任何组合下形态目标恒为常驻条、进度恒 0',
      (tester) async {
    // 纯函数判据（全组合）。
    for (final bool onPrimary in <bool>[true, false]) {
      for (final bool primaryNav in <bool>[true, false]) {
        expect(
          resolveBottomBarFormTarget(
            floatingEnabled: false,
            onPrimaryPages: onPrimary,
            pageIsPrimaryNav: primaryNav,
          ),
          0.0,
          reason: '总开关关闭时必须恒取常驻条端点（onPrimary=$onPrimary primaryNav=$primaryNav）',
        );
      }
    }

    final key = await pumpHarness(tester, floatingEnabled: false);
    await tester.pumpAndSettle();
    expect(kBottomBarFormProgress.value, 0.0);

    // ① 切到标题居中的 tab（目标本会翻转成胶囊）。
    key.currentState!.debugSetTabs(const <TabItem>[_kUnpinnedTab]);
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(kBottomBarFormProgress.value, 0.0, reason: 'tab 配置不得让 TV 翻转');
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(_overlayBarText, findsNothing, reason: 'TV 恒不渲染形态过渡浮层');

    // ② push 一个挂播放条的二级页（目标本会翻转成胶囊 + 交棒）。
    await tester.tap(find.text('push'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(kBottomBarFormProgress.value, 0.0,
          reason: '导航不得让 TV 翻转（目标恒 0）');
    }
    await tester.pumpAndSettle();
    expect(_overlayBarText, findsNothing);

    // ③ 用户切换从属开关（TV 下置灰，但即便被写也不得翻转）。
    kSecondaryPlayerOnPrimaryPages.value = true;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(kBottomBarFormProgress.value, 0.0,
          reason: '从属开关不得让 TV 翻转');
    }
    expect(tester.takeException(), isNull);
  });
}
