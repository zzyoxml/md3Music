import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';

import '../../providers/tab_config_provider.dart';
import '../build_flags.dart';
import '../remote/tv_edge_nested_handoff.dart';
import '../remote/tv_focus_debug.dart';
import 'adaptive_navigator.dart';
import 'page_layout.dart';
import 'tv_fab_focus_bridge.dart';
import 'tv_nav_focus_bridge.dart';
import 'tv_player_bar_focus_bridge.dart';

/// 手机与平板共用的懒建 Tab 栈。播放页始终通过根 Navigator 覆盖整个壳层。
class ResponsiveShell extends StatefulWidget {
  const ResponsiveShell({
    super.key,
    required this.visibleTabs,
    required this.selectedIndex,
    required this.pageBuilder,
    this.persistentBarBuilder,
    this.onSecondaryRouteChanged,
    this.onPageRouteEvent,
  });

  final List<TabItem> visibleTabs;
  final int selectedIndex;
  final Widget Function(String) pageBuilder;

  /// 一级页面退回常驻条时的槽位构造器（按 tab id 生成，null = 不承载常驻条）。
  ///
  /// **必须挂在每个 tab 的根内容里**，而不是壳层 Column 底部：壳层位于每 tab 的
  /// 内层 Navigator 之外，感知不到内层 push，从「发现」打开搜索页 / 每日推荐详情时
  /// 会出现「常驻条 + 二级页悬浮条」同屏两条。挂在根内容里，不透明的二级路由自然
  /// 把它整块盖住，返回时原样露出，无需监听路由栈。
  ///
  /// 双栏 tab 交给 [DesktopTwoPane.masterFooter]（只占左栏宽度，与右栏悬浮条共存），
  /// 其余 tab 直接贴在内容底部。返回的控件自行决定是否真正渲染，因此可以无条件
  /// 挂给每个 tab —— 路由内容在 push 时就固定了，传「算好的值」会读不到后续设置变更。
  final Widget Function(String tabId)? persistentBarBuilder;

  /// 当前选中 tab 是否停在**二级页面（及以后）**时回调。
  ///
  /// 底部 NavigationBar 挂在壳层**之外**（`ResponsiveScaffold` 的
  /// `bottomNavigationBar`），二级页只能盖住 body、盖不住底栏 —— 所以必须由能看见
  /// 各 tab 内层路由栈的本组件上报，主布局据此收起底栏。
  ///
  /// 根据中央栈深度和单栏态独占整宽的详情面板判断，主导航根页面始终保留底栏；
  /// 遮罩弹层（托盘/对话框等 PopupRoute）不计入深度。
  /// 标题对齐与播放条样式不影响导航层级；封面流沉浸由主布局单独处理。
  ///
  /// **注意时机**：本上报经 [_scheduleDepthReport] 推迟到转场收敛（底栏收起会
  /// 当场改变 Tab 栈高度，撞框架 Hero 的飞行盒子，见该方法的说明）。形态交棒
  /// （底栏两形态交叉过渡）**不能**用本信号 —— 它必须在导航那一刻开跑，走
  /// [onPageRouteEvent]。
  final ValueChanged<bool>? onSecondaryRouteChanged;

  /// 中央栈**发生页面路由事件（push/pop/remove/replace）的当下**立即上报，
  /// 不经 [_scheduleDepthReport] 的 `transitionSettling` 推迟。
  ///
  /// 为什么必须另开一条：[onSecondaryRouteChanged] 的推迟是给「底栏收起改变
  /// Tab 栈高度 → 撞框架 Hero 飞行盒子」用的闸门（见 [_scheduleDepthReport]），
  /// 而底栏形态交叉过渡（常驻条 ↔ 悬浮胶囊）的飞行窗口必须在**导航时刻**开跑，
  /// 否则转场全程形态进度仍贴旧端点、转场收敛后才让位 —— 真机上表现为
  /// 「胶囊已就位后常驻条凭空长出再变回胶囊」（2026-10-11 会诊结论 D1/D3）。
  ///
  /// 参数：
  /// - `hasPushedPage`：本 tab 的中央栈**此刻**（事件已入栈/出栈后）是否停着
  ///   push 出来的页面路由（不含 PopupRoute 弹层）；
  /// - `route`：本次事件的页面路由本身（push 是新路由、pop 是被弹出的路由），
  ///   供订阅方核对「这一页挂不挂播放条」；
  /// - `transition`：该路由的转场时长（非 TransitionRoute / 测试里的直推路由
  ///   为 [Duration.zero]）。
  final void Function(
    bool hasPushedPage,
    Route<dynamic> route,
    Duration transition,
  )?
  onPageRouteEvent;

  @override
  State<ResponsiveShell> createState() => ResponsiveShellState();
}

class ResponsiveShellState extends State<ResponsiveShell> {
  final Map<String, GlobalKey<NavigatorState>> _navKeys = {};
  final Map<String, GlobalKey<NavigatorState>> _detailKeys = {};
  final Set<String> _visited = {};
  final Map<String, _TabRouteDepthObserver> _depths = {};

  /// 每个 Tab 内容栈自己的框架 Hero 控制器（与 [_navKeys] 一一对应）。
  ///
  /// 见 [_buildTab] 里的说明：MaterialApp 的那个只订阅根 Navigator。
  final Map<String, HeroController> _tabHeroControllers = {};

  /// 各双栏 tab 的「详情面板独占整宽」态（由 `DesktopTwoPane` 上报）。
  ///
  /// 双栏 tab 的详情经 `AdaptiveNav.openDetail` 挂在**详情面板自己的 Navigator**
  /// 上，[_TabRouteDepthObserver] 挂在中央 Navigator，看不见它 —— 不单独收集就会
  /// 漏判「收藏 → 歌单详情」这类单栏整屏的二级页面。窄宽退化成单栏时详情盖住
  /// master，等价于二级；真双栏（master 仍在场）不算。
  final Map<String, bool> _detailExclusive = {};

  /// tv: 详情面板 Navigator 的观察者（**每个 tab 一个实例**）——只在路由变化后
  /// 触发一次焦点校正。
  ///
  /// 必须按 tab 分别创建：`IndexedStack` 保活让 favorites / library 两个双列 tab
  /// 同时挂着 `DesktopTwoPane`，若共用一个实例，同一个 `NavigatorObserver` 会被
  /// 挂到两个 Navigator 上，触发 Flutter 断言
  /// `'observer.navigator == null': is not true`（navigator.dart:3835），
  /// 页面整块被兜底错误组件替换（2026-10-04 实测，日志见 AGENTS 排查手法）。
  final Map<String, _TvFocusRecheckObserver> _tvFocusRecheckObservers = {};

  /// tv: 各 tab 内容区的 DpadRegion key，用于读它的 lastFocused 回原位。
  final Map<String, GlobalKey<DpadRegionState>> _tvTabRegionKeys = {};

  /// tv: 焦点校正去抖标记（短时间内的多次校正请求合并成一次）。
  bool _focusHandoffDebounce = false;

  @override
  void initState() {
    super.initState();
    // tv: 监听焦点变化，专门捕捉"焦点逃逸到本 tab 内的空范围节点"。
    //
    // 这是按键触发的现象（不是路由/切 tab 事件），事件钩子捕不到：在详情面板
    // 里按右键、右侧无候选时，dpad 返回未处理 → Flutter 默认遍历按
    // `ModalRoute.traversalEdgeBehavior == parentScope` 把焦点"上交"给路由
    // scope → 焦点框消失、方向键失灵，只能按返回键恢复（2026-10-04 实测日志：
    // `primaryFocus=Scope label=_ModalScopeState Focus Scope`）。
    //
    // 只在"焦点落在本 tab 内的 scope 节点"时动作：对话框/根 scope 不在本 tab
    // 子树内，不受影响。
    if (kTvBuild) FocusManager.instance.addListener(_onFocusChangedTv);
  }

  @override
  void dispose() {
    if (kTvBuild) FocusManager.instance.removeListener(_onFocusChangedTv);
    for (final controller in _tabHeroControllers.values) {
      controller.dispose();
    }
    _tabHeroControllers.clear();
    super.dispose();
  }

  void _onFocusChangedTv() {
    if (!kTvBuild || !mounted) return;
    if (widget.visibleTabs.isEmpty) return;
    final index = widget.selectedIndex.clamp(0, widget.visibleTabs.length - 1);
    final activeId = widget.visibleTabs[index].id;
    final focus = FocusManager.instance.primaryFocus;
    // 只处理"逃逸到本 tab 内空范围节点"这一确定信号。
    if (focus is! FocusScopeNode) return;
    if (!_isInTab(focus, activeId) && !_isInDetailOf(focus, activeId)) return;
    _ensureFocusNotStuck();
  }

  /// [node] 是否位于 [tabId] 的详情面板栈内。
  bool _isInDetailOf(FocusNode node, String tabId) {
    final detail = _detailKeys[tabId]?.currentState;
    if (detail == null) return false;
    final scope = detail.focusNode;
    var current = node;
    while (true) {
      if (identical(current, scope)) return true;
      final next = current.parent;
      if (next == null || identical(next, current)) return false;
      current = next;
    }
  }

  /// 已上报的「处于二级页」状态，用于去重；以及把通知推迟到帧末的调度标记。
  bool _reportedSecondary = false;
  bool _notifyScheduled = false;

  @override
  void didUpdateWidget(covariant ResponsiveShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切 tab 后「哪个栈算当前栈」变了，但不会有路由事件进来，必须主动重算一次。
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.visibleTabs != widget.visibleTabs) {
      _scheduleDepthReport();
    }
  }

  void _onRouteDepthChanged(String tabId) {
    _scheduleDepthReport();
    // tv: 二级页 push/pop 同样会让焦点冻结在 ExcludeFocus 排除的子树里
    // （返回歌单详情后焦点丢失、按键无效），故每次路由深度变化都做一次
    // 「焦点卡死检测 + 移交」。理由见 [_ensureFocusAfterTabSwitch]。
    if (kTvBuild) _ensureFocusNotStuck();
  }

  /// 页面路由事件的**当下**上报（不过闸门）——仅当前选中 tab 的事件参与，
  /// 后台 tab 的栈变化不影响前台形态（切过去时 [didUpdateWidget] 会重算）。
  void _onPageRouteEventForTab(String tabId, Route<dynamic> route) {
    final tabs = widget.visibleTabs;
    if (tabs.isEmpty) return;
    final index = widget.selectedIndex.clamp(0, tabs.length - 1);
    if (tabs[index].id != tabId) return;
    final hasPushedPage = _depths[tabId]?.hasPushedRoute ?? false;
    final transition = route is TransitionRoute
        ? route.transitionDuration
        : Duration.zero;
    widget.onPageRouteEvent?.call(hasPushedPage, route, transition);
  }

  /// tv: 检测焦点是否落在"当前可见 tab 之外"，是则交回该 tab。
  ///
  /// ## 为什么需要
  ///
  /// [ExcludeFocus] 不清焦点，被排除节点仍 `hasFocus == true`——切 tab 时焦点
  /// 会冻结在看不见的旧 tab 上；二级页 pop 时焦点所在的节点已随详情页卸载。
  /// 两种情况都表现为「焦点丢失、按键无效」（2026-10-04 真机实测：首次进入
  /// 「我的收藏」双列网格、点进歌单详情后返回）。
  ///
  /// dpad 的 `DpadEnterBehavior.restore` 救不了：它依赖 region 曾记录过焦点矩形
  /// （`_lastFocusedRect` 非空，dpad `region.dart:293`），而新 tab 首帧还是
  /// `SizedBox.shrink`，从未记录过。
  ///
  /// ## 为什么要把详情面板算作"可用"
  ///
  /// 双栏 tab（`kTwoPaneTabs`：favorites / library）的详情页挂在
  /// [_detailKeys] 那个**与中央 Navigator 平级**的 Navigator 上。若只认中央
  /// scope，用户在详情面板内操作时会被判为"焦点在外"、焦点被抢回 master，
  /// 双栏导航直接不可用。故两者都算合法落点。
  void _ensureFocusNotStuck() {
    // 去抖：焦点监听 + 路由事件会在同一瞬间多次触发，合并成一次。
    if (_focusHandoffDebounce) return;
    _focusHandoffDebounce = true;
    _runFocusHandoffCheck();
    // 时序（2026-10-04 实测确认，见
    // test/core/remote/dpad_route_pop_focus_test.dart）：pop 路由后
    // `primaryFocus` 会变成 **null**，但那发生在**转场动画结束、路由子树被
    // dispose 之后**——`didPop` 当帧焦点仍然有效。所以只在事件当帧检查会误判
    // "一切正常"而放过，这正是按返回键退出歌单详情后焦点仍丢失的原因。
    // 转场（约 300ms）结束后补一次检查。
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      _focusHandoffDebounce = false;
      if (mounted) _runFocusHandoffCheck();
    });
  }

  /// 执行一次「焦点是否可用」检查，不可用则移交回当前 tab。
  void _runFocusHandoffCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.visibleTabs.isEmpty) return;
      final index = widget.selectedIndex.clamp(
        0,
        widget.visibleTabs.length - 1,
      );
      final activeId = widget.visibleTabs[index].id;
      final focus = FocusManager.instance.primaryFocus;
      if (_isFocusUsable(focus, activeId)) {
        TvFocusDebug.logHandoff(
          'skip',
          'tab=$activeId ${TvFocusDebug.describe(focus)}',
        );
        return;
      }
      // 逃逸发生在右栏（详情面板）时优先回右栏——否则会把用户从左栏"拽回"，
      // 在双列布局里表现为焦点莫名跳到左半边。
      final candidates = _handoffCandidates(
        activeId,
        preferDetail: focus != null && _isInDetailOf(focus, activeId),
      );
      TvFocusDebug.logHandoff(
        'handoff',
        'tab=$activeId from=${TvFocusDebug.describe(focus)} '
            'candidates=${candidates.length} '
            'labels=${candidates.take(3).map((n) => n.debugLabel ?? "(无标签)").join(",")}',
      );
      _tryFocusInOrder(candidates, 0);
    });
  }

  /// 校正候选，按"最贴近用户上次位置"排序：
  ///
  /// 1. 该 tab 区域内**上次聚焦的那一项**（dpad 的 `lastFocused` 只返回仍可用的
  ///    节点，已随页面卸载的会是 null）——回到原位，体验最好；
  /// 2. 中央 Navigator 子树内的可聚焦项（上限若干，避免大列表下遍历过久）；
  /// 3. 详情面板 Navigator 子树内的可聚焦项（双列 tab 右栏正在显示详情时）。
  ///
  /// 返回的候选会按序尝试，逐个确认是否真的拿到焦点（见 [_tryFocusInOrder]）——
  /// 仅靠 `canRequestFocus` 过滤不够：位于 `ExcludeFocus` 子树内的节点该属性仍为
  /// true，但实际不可聚焦，直接 requestFocus 会静默失败、焦点仍然丢失。
  List<FocusNode> _handoffCandidates(
    String activeId, {
    bool preferDetail = false,
  }) {
    final result = <FocusNode>[];
    final remembered = _tvTabRegionKeys[activeId]?.currentState?.lastFocused;
    if (remembered != null && remembered is! FocusScopeNode) {
      result.add(remembered);
    }
    final central = _focusablesIn(
      _navKeys[activeId]?.currentState?.focusNode,
      limit: 8,
    );
    final detail = _focusablesIn(
      _detailKeys[activeId]?.currentState?.focusNode,
      limit: 8,
    );
    if (preferDetail) {
      result.addAll(detail);
      result.addAll(central);
    } else {
      result.addAll(central);
      result.addAll(detail);
    }
    return result;
  }

  /// 按序尝试候选：当前候选请求焦点后，下一帧确认是否真的落位，未落位则试下一个。
  ///
  /// [FocusNode.requestFocus] 异步生效，故必须跨帧确认；这样即便首个候选因
  /// `ExcludeFocus`、已卸载等原因静默失败，也能自动退到下一个可用项。
  void _tryFocusInOrder(List<FocusNode> candidates, int index) {
    if (!mounted || index >= candidates.length) return;
    final node = candidates[index];
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 校正期间弹层抢到了焦点（对话框/底部弹层打开并主动落位）→ 立刻收手。
      // 不加这句会静默吞掉弹层焦点：首候选 requestFocus 生效的同一帧，弹层
      // 路由也会 requestFocus；下一帧这里校验时 primaryFocus 已是弹层节点，
      // 于是判定「首候选没落位」继续试下一个，把用户从弹层里拽回页面
      // （2026-10-05 真机实测：弹层首项拿到焦点后 25ms 即被抢回 FAB）。
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && identical(primary, node)) return;
      if (primary != null &&
          primary is FocusScopeNode &&
          _hasFocusableDescendant(primary)) {
        return;
      }
      _tryFocusInOrder(candidates, index + 1);
    });
  }

  /// 焦点是否处于"用户可见可用"的状态。
  ///
  /// 判据（2026-10-04 实测校准，2026-10-05 修正 modal 弹层误判）：
  /// - 主导航栏上的节点 → 合法（用户在导航栏换 tab 时不能抢走焦点）；
  /// - **scope 节点且其子树内已有可聚焦后代** → 合法。这一条是为
  ///   `showDialog` / `showM3EModalBottomSheet` 这类 modal 弹层加的：弹层打开
  ///   后会先把自己（`_ModalScopeState`）设为焦点，此时它自己的子树里已经有
  ///   `DpadFocusable` 行并持有焦点（弹层脚本会主动 requestFocus）。旧判据只看
  ///   "scope 自身是否在 tab 子树内"，弹层不在 → 判为不合法 → 校正逻辑把焦点
  ///   抢回页面 FAB（2026-10-05 真机实测：弹层首项拿到焦点后 25ms 即被抢走，
  ///   表现为"要点两次才有焦点"）。故这里改成看**子树内有没有活的落点**。
  /// - scope 子树内**无**任何可聚焦后代 → 不合法（方向键把焦点上交到路由
  ///   scope 的典型症状：`ModalRoute.traversalEdgeBehavior` 默认
  ///   `parentScope`，焦点被上交后焦点框消失、按键失灵）。
  /// - tab 之外的范围节点（根 scope）→ 合法，不动；
  /// - 其余不在本 tab 内的节点 → 不合法。
  bool _isFocusUsable(FocusNode? node, String activeId) {
    if (node == null) return false;
    if (TvNavFocusBridge.instance.isNavNode(node)) return true;
    final inTab = _isInActiveTab(node, activeId);
    if (node is FocusScopeNode) {
      // 弹层/对话框：子树内已有可聚焦落点就说明用户正与之交互，放行。
      if (_hasFocusableDescendant(node)) return true;
      return !inTab;
    }
    return inTab;
  }

  /// [scope] 子树内是否存在**当前可聚焦且参与遍历**的后代节点。
  ///
  /// 必须递归而非只看一层：弹层内容被 `SafeArea` / `Column` 等多层容器包裹
  /// （本仓底部弹层是 `SafeArea > Builder > Column > _tvSheetRow`），
  /// `DpadFocusable` 不是 scope 的直接后代。
  ///
  /// 深度上限 6 层足够覆盖弹层结构，又能在「焦点落在超大列表」时及时收敛
  /// （那种情况首个兄弟通常就可聚焦，命中即返回）。已卸载/被 `ExcludeFocus`
  /// 排除的节点 `canRequestFocus` 仍可能为 true，故额外要求渲染矩形非空。
  bool _hasFocusableDescendant(FocusNode scope, {int depth = 0}) {
    if (depth > 6) return false;
    for (final child in scope.descendants) {
      if (child is FocusScopeNode) continue;
      if (!child.canRequestFocus || child.skipTraversal) continue;
      final ctx = child.context;
      if (ctx == null || !ctx.mounted) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.hasSize || box.size.isEmpty) continue;
      return true;
    }
    // 一层内没有可聚焦节点：下潜一层看子 scope（弹层内容常挂在子 route 上）。
    for (final child in scope.descendants) {
      if (child is! FocusScopeNode) continue;
      if (_hasFocusableDescendant(child, depth: depth + 1)) return true;
    }
    return false;
  }

  /// 焦点是否落在 [tabId] 的中央栈或详情面板栈内。
  bool _isInActiveTab(FocusNode node, String tabId) {
    if (_isInTab(node, tabId)) return true;
    final detail = _detailKeys[tabId]?.currentState;
    if (detail == null) return false;
    final scope = detail.focusNode;
    var current = node;
    while (true) {
      if (identical(current, scope)) return true;
      final next = current.parent;
      if (next == null || identical(next, current)) return false;
      current = next;
    }
  }

  /// 双栏 tab 的详情面板是否独占整宽（单栏态）；与中央栈深度合成同一个二级判定。
  void _onDetailExclusive(String tabId, bool exclusive) {
    if (_detailExclusive[tabId] == exclusive) return;
    _detailExclusive[tabId] = exclusive;
    _scheduleDepthReport();
    // 单栏态下详情整屏盖住 master，进出它同样是"二级页 push/pop"，
    // 焦点需要校正一次（与中央栈的 _onRouteDepthChanged 同等对待）。
    if (kTvBuild) _ensureFocusNotStuck();
  }

  /// 路由事件可能发生在 Navigator 自身 build 期间（首帧建栈），此时直接 setState
  /// 会撞上「build 期间改父级状态」；转场本来就是动画，推迟一帧不可见。
  void _scheduleDepthReport() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!mounted || widget.visibleTabs.isEmpty) return;
      final index =
          widget.selectedIndex.clamp(0, widget.visibleTabs.length - 1);
      final tab = widget.visibleTabs[index];
      // 「用户面前还是不是该 tab 的栈底页」有两个来源：中央 Navigator 的深度，以及
      // 双栏 tab 退化成单栏时独占整宽的详情面板（详情栈挂在详情面板自己的
      // Navigator 上，中央的深度观察者看不见它）。两条事实合成一条后**就地定级**：
      // 主导航入口必须保留导航栏；标题对齐只影响播放条样式，不决定导航层级
      // （播放条形态的判据是 `page_title_alignment.dart` 的 `isPrimaryNavPage`，
      //  与下面的定级互不相干）。
      // 中央栈深度只统计页面路由——托盘/对话框这类遮罩弹层（PopupRoute）弹出/关闭
      // 不改变页面层级，底栏保持一级页面时的形态。
      final secondary = (_depths[tab.id]?.hasPushedRoute ?? false) ||
          (_detailExclusive[tab.id] ?? false);
      if (secondary == _reportedSecondary) return;
      // 二级态翻转**等转场收敛再上报**：底栏/常驻条的收起与恢复会当场改变
      // Tab 栈（中央 Navigator）的高度，而框架 Hero 的飞行盒子按起飞那一刻的
      // navigatorSize 换算四边（heroes.dart）——转场途中改高度，差值会整段
      // 加在飞行封面上（真机实测：一级页进详情时底栏收起，封面被拉长）。
      // 这与搜索页 `_dismissImeBeforeNavigate` 是同一类问题的两半：键盘收起
      // 在入口侧规避，底栏收起在这里推迟到转场之后。转场收敛时观察者会补发
      // 一次 _onChanged 把上报带回来。`_detailExclusive` 的翻转发生在双栏
      // 面板栈（自绘飞行，实时实测矩形，不怕改尺寸）或旋转几何变化，面板栈
      // 不在本观察者的转场跟踪里，不会被这里卡住。
      if (_depths[tab.id]?.transitionSettling ?? false) return;
      _reportedSecondary = secondary;
      widget.onSecondaryRouteChanged?.call(secondary);
    });
  }

  /// 当前选中 tab 的中央栈**此刻**是否停着 push 出来的页面路由。
  ///
  /// 供主布局在切 tab 后立即刷新形态交棒的事实（[onPageRouteEvent] 只在路由
  /// 事件当下推送；切 tab 没有路由事件，但「哪个栈算当前栈」变了）。
  bool currentTabHasPushedPage() {
    final tabs = widget.visibleTabs;
    if (tabs.isEmpty) return false;
    final index = widget.selectedIndex.clamp(0, tabs.length - 1);
    return _depths[tabs[index].id]?.hasPushedRoute ?? false;
  }

  /// 详情栈先返回，再返回中央栈；交还主布局处理沉浸及双击退出。
  Future<bool> maybePop() async {
    if (widget.visibleTabs.isEmpty) return false;
    final index = widget.selectedIndex.clamp(0, widget.visibleTabs.length - 1);
    final id = widget.visibleTabs[index].id;
    final nav = _navKeys[id]?.currentState;
    // 未分派到右栏的中央路由盖在双栏上，必须先消费它。
    if (nav != null && nav.canPop()) return nav.maybePop();
    final detail = _detailKeys[id]?.currentState;
    if (detail != null && await detail.maybePop()) return true;
    // 设置二/三级页在同一路由内切换，canPop=false 仍可能由 PopScope 消费返回。
    return await nav?.maybePop() ?? false;
  }

  /// 往当前 tab 的中央内容栈推一条路由（LaunchPad 隐藏 tab 点击 / 快捷方式入口）。
  ///
  /// 必须走内层 Navigator：中央栈的 [_TabRouteDepthObserver] 据此上报二级态，
  /// 底栏/横屏侧栏才会播放收起动画（推根 Navigator 会整页盖住壳层，链路不触发）。
  /// shell 未构建（桌面布局走 DesktopShell、或首帧前）返回 null，调用方自行兜底。
  Future<T?>? pushCurrentTabRoute<T extends Object?>(WidgetBuilder builder) {
    if (widget.visibleTabs.isEmpty) return null;
    final index = widget.selectedIndex.clamp(0, widget.visibleTabs.length - 1);
    final nav = _navKeys[widget.visibleTabs[index].id]?.currentState;
    if (nav == null) return null;
    return nav.push(MaterialPageRoute<T>(builder: builder));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.visibleTabs.isEmpty) return const SizedBox.shrink();
    final index = widget.selectedIndex.clamp(0, widget.visibleTabs.length - 1);
    final activeId = widget.visibleTabs[index].id;
    final isFirstBuild = _visited.isEmpty;
    final newlyActivated = _visited.add(activeId);
    // tv: 切 tab 后焦点会冻结在被 ExcludeFocus 排除的旧 tab 上（新 tab 表现为
    // "丢失焦点"、按键全无效），需显式抢回。首次进入尤其明显：新 tab 首帧还是
    // SizedBox.shrink，其 region 从未记录焦点位，dpad 的 restore 兜底全落空。
    // 详见 [_ensureFocusNotStuck]。
    if (!isFirstBuild && newlyActivated) {
      _ensureFocusNotStuck();
    }
    return IndexedStack(
      index: index,
      children: [
        for (final tab in widget.visibleTabs)
          TickerMode(
            key: ValueKey(tab.id),
            enabled: tab.id == activeId,
            child: ExcludeFocus(
              excluding: tab.id != activeId,
              child: _visited.contains(tab.id)
                  ? _buildTab(tab.id)
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  /// 节点是否位于指定 tab 的导航栈内。
  bool _isInTab(FocusNode node, String tabId) {
    final nav = _navKeys[tabId]?.currentState;
    if (nav == null) return false;
    final scope = nav.focusNode;
    var current = node;
    while (true) {
      if (identical(current, scope)) return true;
      final next = current.parent;
      if (next == null || identical(next, current)) return false;
      current = next;
    }
  }

  /// 在 scope 子树内找出可聚焦、可遍历的节点（最多 [limit] 个）。
  ///
  /// 用 `descendants`（深层后代）：dpad 的导航项、列表行等都是
  /// `DpadFocusable`，本身即可聚焦可遍历；中间层容器节点（Scrollable 等）
  /// 通常 `canRequestFocus == false`，会被跳过。
  /// 候选必须满足三条，缺一都可能让校正"原地打转"（2026-10-04 实测教训）：
  /// 1. **不是范围节点**——`FocusScopeNode.canRequestFocus` 恰为 true，会通过朴素
  ///    过滤并被排到候选首位，于是焦点被交回给"正要逃离的那个 scope"；
  /// 2. 可聚焦且参与遍历；
  /// 3. **有实际渲染尺寸**——离屏（Offstage/未活动路由）子树里的节点拿不到焦点。
  List<FocusNode> _focusablesIn(FocusNode? scope, {int limit = 8}) {
    if (scope == null) return const [];
    final result = <FocusNode>[];
    for (final node in scope.descendants) {
      if (node is FocusScopeNode) continue;
      if (!node.canRequestFocus || node.skipTraversal) continue;
      final ctx = node.context;
      if (ctx == null || !ctx.mounted) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.hasSize || box.size.isEmpty) continue;
      result.add(node);
      if (result.length >= limit) break;
    }
    return result;
  }

  Widget _buildTab(String id) {
    final navigator = Navigator(
      key: _navKeys.putIfAbsent(id, () => GlobalKey<NavigatorState>()),
      observers: [
        _depths.putIfAbsent(
          id,
          () => _TabRouteDepthObserver(
            () => _onRouteDepthChanged(id),
            onPageRouteEvent: (route) => _onPageRouteEventForTab(id, route),
          ),
        ),
      ],
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) {
          final page = widget.pageBuilder(id);
          final persistentBar = widget.persistentBarBuilder?.call(id);
          if (kTwoPaneTabs.contains(id)) {
            return DesktopTwoPane(
              responsive: true,
              detailKey: _detailKeys.putIfAbsent(
                id,
                () => GlobalKey<NavigatorState>(),
              ),
              // tv: 详情面板的 Navigator 与中央栈平级，中央观察者看不见它的
              // push/pop；不单独挂一个就无法在「点进歌单详情 → 返回」后校正
              // 焦点（2026-10-04 实测症状）。该观察者只负责触发焦点校正，
              // 不参与 _depths 的二级判定（那是中央栈专用语义）。
              detailObservers: kTvBuild
                  ? [
                      _tvFocusRecheckObservers.putIfAbsent(
                        id,
                        () => _TvFocusRecheckObserver(_ensureFocusNotStuck),
                      ),
                    ]
                  : const <NavigatorObserver>[],
              masterFooter: persistentBar,
              onDetailFullscreenChanged: (exclusive) =>
                  _onDetailExclusive(id, exclusive),
              master: page,
            );
          }
          final content = kConstrainedTabs.contains(id)
              ? ContentWidth(child: page)
              : page;
          if (persistentBar == null) return content;
          // 常驻条贴在根内容下方，随整页一起被 push 出来的二级路由盖住。
          return Column(
            children: [
              Expanded(child: content),
              persistentBar,
            ],
          );
        },
      ),
    );

    // 每个 Tab 内容栈自带一个框架 Hero 控制器。
    //
    // 为什么必须单独挂：`HeroControllerScope` 的既定语义是「一个控制器只订阅一个
    // Navigator，且某个 Navigator 取用后会拦住其子树内的下级 Navigator」——
    // MaterialApp 那个只服务于根 Navigator，Tab 内容栈这个下级 Navigator 拿不到，
    // 于是「在 Tab 栈里 push 详情」的入口（搜索页专辑 tab、新碟上架浏览页…）框架
    // Hero 永远不飞（真机实测：两端 tag 一致、开关为开，shuttle 一次都没跑，
    // `openDetail scope=false` 全部落在这个 Navigator 上）。
    //
    // 双栏 tab 的详情面板 Navigator 会被上面的规则拦住、同样拿不到控制器：它本来
    // 就走 PlaylistCoverFlightBus 的自绘路径（`_inPane=true`，不包框架 Hero），
    // 互不干涉，也不会出现「一个封面飞两次」。
    final tabStack = HeroControllerScope(
      controller: _tabHeroControllers.putIfAbsent(
        id,
        () => MaterialApp.createMaterialHeroController(),
      ),
      child: navigator,
    );

    // tv: 每个 Tab 内容栈外包一个 DpadRegion —— memoryKey 按 tabId 唯一，
    // 切 Tab（IndexedStack 保活 + ExcludeFocus 隔离）回来后焦点回原位
    // （DpadEnterBehavior.restore）。
    //
    // 边缘行为（2026-10-04 实测修正）：
    // - 纵向保持 leave：到底时 dpad 先滚动懒列表，滚尽后落到常驻播放条 /
    //   底部导航栏（wrap 会把焦点困在内容区）。
    // - 横向改为 stop + onEdge 显式移交：内容区在 tab Navigator（FocusScope）
    //   内，dpad 收集候选用 nearestScope.traversalDescendants，**取不到
    //   scope 外的兄弟节点**（导航栏），所以 leave 在这里等于死键——实测连按
    //   12 次左键焦点纹丝不动（widget 测试
    //   test/core/remote/dpad_scope_probe_test.dart 复现同一现象）。改为在
    //   边缘停下并经 [TvNavFocusBridge] 把焦点直接交给导航栏节点。
    //   纵向仍需到达导航栏下方的常驻播放条，故只有横向 stop。
    if (kTvBuild) {
      final tabIndex = widget.visibleTabs.indexWhere((t) => t.id == id);
      return DpadRegion(
        // GlobalKey：焦点校正时要读该区域的 lastFocused（上次聚焦项）以回原位，
        // 见 [_ensureFocusNotStuck]。
        key: _tvTabRegionKeys.putIfAbsent(
          id,
          () => GlobalKey<DpadRegionState>(),
        ),
        memoryKey: 'tv/tab-$id',
        debugLabel: 'tab-$id',
        horizontalEdge: DpadEdgeBehavior.stop,
        // 纵向改为 stop：底部常驻播放条同样在 tab 的 Navigator scope 之外，
        // leave 与横向当年一样是死键（2026-10-04：MiniPlayer 在 TV 上完全
        // 选不中）。dpad 会先尝试滚动懒列表，滚尽后才触发 onEdge，滚动不受
        // 影响；到了真正的下边缘再经 [TvPlayerBarFocusBridge] 显式移交。
        verticalEdge: DpadEdgeBehavior.stop,
        onEdge: (direction) {
          // tv: stop 边缘的第一步是「同 scope 内、这个方向上属于别的区域」的
          // 候选移交（横向卡片带等嵌套区域）。dpad 的区域成员判定看不到它们，
          // 少了这一步，从带外的行按下/右会被 stop 直接吃掉按键，
          // 带里的卡片永远落不下焦点（见 tv_edge_nested_handoff 的说明与
          // test/core/remote/tv_band_below_fold_focus_test.dart 的 C/D 两组）。
          final primary = FocusManager.instance.primaryFocus;
          if (primary != null &&
              focusNestedRegionBeyond(primary, direction)) {
            return;
          }
          if (direction == TraversalDirection.left) {
            // 左边缘 = 往导航栏方向。移交当前 tab 对应的导航项（记忆上次焦点位
            // 由导航栏自己的 DpadRegion + memoryKey 负责）。
            TvNavFocusBridge.instance.focusNavItem(tabIndex < 0 ? 0 : tabIndex);
            return;
          }
          if (direction == TraversalDirection.down) {
            // 下边缘的两个落点，按优先级：
            // 1. 当前页的右下角 FAB —— 它在 scope 内但几何不合格（水平不重叠
            //    且底边更高），dpad 的候选判定直接把它排除，只能桥接
            //    （见 [TvFabFocusBridge]）；
            // 2. 底部常驻播放条 —— 在 tab Navigator scope 之外，同样够不着。
            // 页内常驻条（PrimaryPagePersistentBar）在本 scope 内，dpad 会
            // 自然落到它上面，不会走到这里。
            if (TvFabFocusBridge.instance.focusFab()) return;
            TvPlayerBarFocusBridge.instance.focusPlayerBar();
          }
        },
        child: tabStack,
      );
    }
    return tabStack;
  }
}

/// tv: 详情面板 Navigator 的轻量观察者——路由 push/pop/替换后触发一次回调。
///
/// 与 [_TabRouteDepthObserver] 的区别：不记录任何状态、不参与二级页判定，
/// 只做"路由变了 → 校正一次焦点"。双栏 tab 的详情挂在独立 Navigator 上，
/// 中央观察者看不到它的路由事件（2026-10-04 实测：点进歌单详情后返回丢焦点）。
class _TvFocusRecheckObserver extends NavigatorObserver {
  _TvFocusRecheckObserver(this._onChanged);

  final VoidCallback _onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _onChanged();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _onChanged();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _onChanged();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _onChanged();
}

/// 记录一个 tab 内层 Navigator 上「当前在场」的路由，用于上报栈深度事实。
///
/// 「在场」只统计页面路由：遮罩弹层（`PopupRoute`，含托盘/对话框）不算离开栈底
/// （见 `hasPushedRoute`）。
///
/// 不用 `NavigatorState.canPop()` 当判据：根路由自带返回处理
/// （`willHandlePopInternally`）或页面上有弹出层时它同样为真，会把一级页面
/// 误判成二级页并把底栏收掉。这里直接读路由自己的 `isFirst`，与
/// `isSecondaryRoutePage` 取同一条路由事实；**导航层级**只由「本观察者的中央栈
/// 深度 ∨ 详情面板独占整宽」两条事实合成（见 _scheduleDepthReport），
/// 标题对齐（`TabItem.pinnedTitle` / `isPrimaryNavTab`）只决定播放条形态，
/// 不参与这里的定级。路由集合只在事件里增删，真值来自路由本身。
class _TabRouteDepthObserver extends NavigatorObserver {
  _TabRouteDepthObserver(this._onChanged, {this.onPageRouteEvent});

  final VoidCallback _onChanged;

  /// 页面路由事件（push/pop/remove/replace）的**当下**回调（不过
  /// `transitionSettling` 闸门）——底栏形态交棒的飞行窗口据此在导航时刻开跑。
  /// 转场收敛时 [settle] 的补报**不**走这里（那不是导航事件）。
  final void Function(Route<dynamic> route)? onPageRouteEvent;
  final Set<Route<dynamic>> _present = <Route<dynamic>>{};

  /// 转场未收敛的页面路由。push 的进场（forward）与 pop 的出场（reverse——
  /// 路由此刻已离开 [_present]，但动画还在播、页面还看得见）都会记进来，
  /// 收敛（completed/dismissed）即移除并触发一次重报。
  final Set<Route<dynamic>> _inTransition = <Route<dynamic>>{};

  /// 栈底之外还有**页面路由** = 当前显示的是被 push 出来的二级页。
  ///
  /// 排除 `PopupRoute`（底部托盘 / 对话框等带遮罩的弹层，`ModalBottomSheetRoute`、
  /// `DialogRoute` 都是其子类；m3e_core 的 showM3EModalBottomSheet 内部即
  /// showModalBottomSheet）：这类路由可点遮罩关闭、下方页面仍在场，不构成页面
  /// 层级变化。教训：本地音乐页右下角 ➕ 弹扫描托盘会把底栏收起、关闭又展开，
  /// 弹层期间让出的空间没有内容承接（2026-10-05 用户报告）。
  bool get hasPushedRoute =>
      _present.any((route) => !route.isFirst && route is! PopupRoute);

  /// 有页面路由转场未收敛 = 二级态翻转暂缓上报（见
  /// [ResponsiveShellState._scheduleDepthReport]：底栏收起/恢复会当场改变
  /// Tab 栈高度，转场途中改高度会把框架 Hero 的飞行封面拉长）。
  bool get transitionSettling => _inTransition.isNotEmpty;

  /// 页面路由进出时跟踪其转场，收敛后通知重报。弹层（PopupRoute）不构成页面
  /// 层级、也不参与底栏时机，不跟踪。
  ///
  /// **Hero 探位帧**：转场首帧 HeroController 会把新路由置 `offstage` 测 Hero
  /// 终位（heroes.dart `_maybeStartHeroTransition`），此时 `ModalRoute.offstage=`
  /// 把动画代理临时换成 `kAlwaysCompleteAnimation`——status 短暂变成 completed、
  /// v=1.0，**不是真收敛**。offstage 期间的状态事件一律忽略，等翻回后的真实状态。
  void _watchTransition(Route<dynamic> route) {
    if (route is! TransitionRoute) return;
    final anim = route.animation;
    if (anim == null) return;
    final modal = route is ModalRoute ? route : null;
    final bool heroOffstage = modal?.offstage ?? false;
    if (!heroOffstage &&
        (anim.status == AnimationStatus.completed ||
            anim.status == AnimationStatus.dismissed)) {
      // 已收敛（无转场动画的路由，或测试里直接推 completed 的路由）。
      return;
    }
    // 已在跟踪（同一路由 push 时挂过监听，pop 不重复挂——dismissed 由原监听接住）。
    if (!_inTransition.add(route)) return;
    void settle(AnimationStatus status) {
      if (modal?.offstage ?? false) return; // Hero 探位帧的假状态，忽略。
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      anim.removeStatusListener(settle);
      if (_inTransition.remove(route)) _onChanged();
    }

    anim.addStatusListener(settle);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _present.add(route);
    _watchTransition(route);
    onPageRouteEvent?.call(route);
    _onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _present.remove(route);
    _watchTransition(route);
    onPageRouteEvent?.call(route);
    _onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _present.remove(route);
    _watchTransition(route);
    onPageRouteEvent?.call(route);
    _onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _present.remove(oldRoute);
    if (newRoute != null) _present.add(newRoute);
    onPageRouteEvent?.call(newRoute ?? oldRoute ?? _present.last);
    _onChanged();
  }
}
