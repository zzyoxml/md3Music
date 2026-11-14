import 'package:dpad/dpad.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../build_flags.dart';
import 'bottom_chrome_dimens.dart';
import 'bottom_chrome_scope.dart';
import 'bottom_chrome_sink.dart';
import '../theme/motion_constants.dart';
import 'tv_nav_focus_bridge.dart';

import '../utils/app_haptics.dart';
import '../../providers/device_provider.dart';
import '../../providers/theme_provider.dart';

enum ScreenType { compact, medium, expanded }

/// 断点值 600dp。[getScreenType] 量的是**可用宽度**（横屏手机也会越过它），
/// [isPadLayout] 量的是**最短边**（只有真正的大屏设备才越过）。
const double compactBreakpoint = 600;
const double expandedBreakpoint = 840;
const double twoPaneBreakpoint = 1000;

/// 底栏（竖屏 NavigationBar）收起 / 展开时长。
///
/// 与「二级页面 push/pop」转场同时开始（路由变化经 post-frame 上报、比转场
/// 晚不到一帧）、比它略短：底栏先让位、页面再落位，读起来才不乱。
///
/// 这是一次性**转场**动画，与 AGENTS §10 约束的"常驻循环动效"不是一类
/// （同 `_CapsuleBounce` 的回弹、`SecondaryMiniPlayer._morph` 的弹簧），
/// 因此用 AnimationController 合规；而展开播放页时跟着手指走的那部分挂在既有
/// `playerExpansion` 帧源上（见 `BottomChromeSink`），不新增 Ticker / Timer。
const Duration kBottomChromeToggleDuration = Duration(milliseconds: 260);

/// 所有窗口形态按局部可用宽度求值，独立于桌面布局开关。
bool usesNavigationRail(double width) => width >= compactBreakpoint;
bool usesTwoPane(double width) => width >= twoPaneBreakpoint;

/// 横屏 NavigationRail 槽位宽的默认档（首次实测回填前的占位，与
/// `_ResponsiveScaffoldState._railWidth` 的初值同源；rail 实际宽随文字档位由
/// [_MeasureWidth] 实测，见 [navigationRailReservedWidth]）。
const double kNavigationRailDefaultWidth = 96.0;

/// 横屏 rail 与内容区之间的分隔线占位宽（`VerticalDivider(thickness: 1,
/// width: 1)`，见 `_buildRailLayout`）。
const double kNavigationRailDividerWidth = 1.0;

/// 横屏 rail 布局下内容区左缘的保留宽度（rail 槽位 + 分隔线，实测值）。
///
/// rail 本体挂在 `ResponsiveScaffold` 子树内，形变浮层挂在 Navigator 之上（树外），
/// 宽度没法经 InheritedWidget 传递 —— 由 [_MeasureWidth] 实测回填（`onWidth`
/// 回调里与本 State 的 `_railWidth` 一并写入），布局外的端点解析消费方读这份
/// 全局值。未布局前回落到默认档（[kNavigationRailDefaultWidth] + 分隔线）。
double navigationRailReservedWidth =
    kNavigationRailDefaultWidth + kNavigationRailDividerWidth;

/// 横屏 rail 槽位 + 分隔线**当前可见**的左缘保留宽（随滑出/滑入动画逐帧收缩，
/// 静止在场 = [navigationRailReservedWidth]，完全收起 = 0）。
///
/// 与 [navigationRailReservedWidth] 同一条「布局外回填」通道：由 `_buildRailLayout`
/// 的逐帧 builder 写入（只写字段、不触发 setState，AGENTS §10）。消费者是形态
/// 交棒浮层的胶囊端点解析 —— 横屏 push 交棒时 rail 要等路由转场收敛才起 260ms
/// 滑出动画，而浮层的可见形变前置在窗口开头 260ms 内走完（K1）；胶囊端点的左缘
/// 保留若按结算快照冻结成 0，形变会在 rail 仍在场时就把胶囊推到全宽（左缘盖住
/// rail，真机横屏报障的「点击瞬间与落定后侧边边距不一致」）。逐帧读本值，胶囊
/// 端点即与 rail 槽位同帧同步收敛。竖屏 / rail 未布局时恒 0（初值即 0，rail
/// builder 首帧写入后与在场事实一致）。
double navigationRailVisibleInset = 0.0;

ScreenType getScreenType(double width) {
  if (width < compactBreakpoint) return ScreenType.compact;
  if (width < expandedBreakpoint) return ScreenType.medium;
  return ScreenType.expanded;
}

/// 当前是否使用 Pad（大屏）布局：分栏播放器、网格列数偏好、居中大弹窗等。
///
/// [DeviceType.auto] 按**有效视口**最短边判定，而不是设备物理 dp：
/// 「显示大小」（[DisplayScaleScope]）调大后可用逻辑区随之变小，原生同样会跌出
/// sw600dp 资源桶、切回手机布局。两边一致才不会出现"Pad 分栏挤在手机大小的
/// 视口里"。用户在设置里手动选了手机/平板时直接服从该选择。
bool isPadLayout(BuildContext context) {
  switch (context.read<DeviceProvider>().deviceType) {
    case DeviceType.auto:
      return MediaQuery.sizeOf(context).shortestSide >= compactBreakpoint;
    case DeviceType.phone:
      return false;
    case DeviceType.pad:
      return true;
  }
}

/// 桌面外壳（侧栏 + 顶部工具栏）总开关。
///
/// 由设置页「桌面布局」开关驱动、启动时从 `SettingsRepository.getDesktopModeEnabled`
/// 载入。**默认 false**：无论横竖屏都走常规响应式布局（[ResponsiveScaffold]）；
/// 用户手动开启后，无论横屏还是竖屏都强制使用桌面外壳。
///
/// 用全局 [ValueNotifier] 而非 Provider：因 [isDesktopLayout] 也会在返回键回调等
/// 非 build 上下文里被调用（`context.watch` 会抛异常），值型订阅更安全；顶层
/// `_MainLayout` 监听它触发整棵子树重建（与 `kCoverFlowImmersive` 同模式）。
final ValueNotifier<bool> kDesktopModeEnabled = ValueNotifier<bool>(false);

/// 内容双栏（master-detail）开关；关闭不影响侧栏导航。历史名
/// [kWindowsTwoPaneEnabled] 保留：开关现已三端通用（设置页「启用双栏布局」），
/// 非 Windows 由 main.dart 播种默认 true（宽屏双栏行为不回退），Windows 默认关。
final ValueNotifier<bool> kWindowsTwoPaneEnabled = ValueNotifier<bool>(false);

/// 播放器形态总开关（SecondaryMiniPlayerHost 渲染悬浮条还是底部常驻条）。
///
/// 默认关闭（底部常驻形态）。开启后**主页与二级页面**均使用悬浮播放条；关闭后
/// 统一改用底部常驻播放条（主页由 shell 承载，二级页面由宿主补上同一条）。
///
/// 与 [kDesktopModeEnabled] 同为"外壳/播放栏形态"开关，放同一处便于查找。
/// 宿主用 [ValueListenableBuilder] 直接订阅即可即时生效，无需整棵子树重建。
final ValueNotifier<bool> kSecondaryPlayerEnabled = ValueNotifier<bool>(false);

/// Android 预测性返回手势（predictive back）总开关判定源。
///
/// 启动为 false，由 `lib/app.dart` 的 _AppViewState 冷启动载入持久化值、
/// 设置页开关运行时写入同一 notifier；主题在 _AppView 里读取该值切换
/// pageTransitionsTheme 的 Android builder。
/// 与 [kDesktopModeEnabled] / [kSecondaryPlayerEnabled] 同放一处便于查找。
final ValueNotifier<bool> kPredictiveBackEnabled = ValueNotifier<bool>(false);

/// 歌单封面连贯过渡（列表卡片封面 → 歌单详情页头封面的共享元素飞行）总开关。
///
/// 默认开启；启动时由 `lib/app.dart` 载入持久化值，设置页开关运行时写入同一 notifier，
/// `PlaylistCoverHero` 直接读 `.value` 判定（关闭时既不登记来源也不起飞）。
/// 与 [kPredictiveBackEnabled] 同放一处便于查找。
final ValueNotifier<bool> kPlaylistCoverTransitionEnabled =
    ValueNotifier<bool>(true);

/// 「封面连贯过渡」与「预测性返回手势」互斥的裁决（**封面连贯过渡优先**）。
///
/// 为什么要互斥：真机实测两者同开时，pop 期间预测性返回会在飞行途中改写被弹出路由
/// 的动画/尺寸，而框架 Hero 给飞行封面的盒子是按**起飞那一刻**的 `navigatorSize`
/// 冻结换算的（`heroes.dart:1033`），中途变的尺寸只能整体拉伸封面 —— 表现为退场
/// 「抽搐一下」。这与输入法 `adjustResize` 压缩窗口是同一类「转场途中尺寸变了」，
/// 在 shuttle 内部纠正会把一帧错误尺寸暴露成跳变（试过并回退），所以从源头避免并发。
///
/// 用法：设置页两个开关的 `onChanged` 与 `lib/app.dart` 冷启动载入都过一遍这里，
/// 保证 notifier、本地 state、持久化三处口径一致。
({bool coverTransition, bool predictiveBack}) resolveCoverBackExclusivity({
  required bool coverTransition,
  required bool predictiveBack,
}) =>
    (
      coverTransition: coverTransition,
      predictiveBack: coverTransition ? false : predictiveBack,
    );

/// 悬浮播放器的进度指示开关（沿胶囊内缘包边一圈；收起成圆盘时即为其外圈进度环）。
///
/// 默认开启，但只在 [kSecondaryPlayerEnabled] 开启后才有意义（常驻条自带进度）。
/// 与悬浮条形态开关放同一处，宿主订阅后即时生效。
final ValueNotifier<bool> kSecondaryPlayerProgressEnabled =
    ValueNotifier<bool>(true);

/// 悬浮播放器整体透明度（0.2~1.0，默认完全不透明）。
final ValueNotifier<double> kSecondaryPlayerOpacity = ValueNotifier<double>(1.0);

/// 一级页面（每 tab 的内层 Navigator 首路由 / 栈底主布局内的 tab 页）是否也用悬浮底栏。
///
/// 分级形态配置：[kSecondaryPlayerEnabled] 是总开关，本开关只决定**一级页面**
/// 这一级用哪种底栏——
/// - true（默认）：一级页面也用悬浮条，shell 的全宽常驻 [MiniPlayer] 隐藏；
/// - false：一级页面退回底部常驻条（**贴在底部导航栏上方**），二级页面（含 tab
///   内层 push 出来的搜索页 / 每日推荐详情，以及平板双栏的详情面板）仍用悬浮条。
///   退回的那条常驻条挂在**每个 tab 根内容的底部**（`SecondaryMiniPlayerHost`
///   同文件的 `PrimaryPagePersistentBar`）：双栏 tab 只占左栏宽度，其余 tab 全宽。
///   挂在根内容里而不是壳层 Column 底部，是因为壳层看不见内层 push —— 从「发现」
///   打开搜索页时会出现「常驻条 + 二级页悬浮条」同屏两条。
///
/// 判据分两条，**不要混用**（同一页面可能一条算一级、一条算二级）：
/// - **播放条形态**（本开关的作用对象）：`page_title_alignment.dart` 的
///   `isPrimaryNavPage`（标题左对齐 + 停在栈底），双栏详情面板与内层 push 出来的
///   路由都归为二级。
/// - **导航层级**（底部导航栏显隐）：判据在 `responsive_shell.dart` 的
///   `_scheduleDepthReport`（中央栈是否有 push 出来的页面路由 ∨ 双栏详情面板是否
///   独占整宽），经 `onSecondaryRouteChanged` 上报为 `app.dart` 的
///   `_secondaryPageOnTop`，**不看标题对齐**；开关见 [kHideNavBarOnSecondaryPages]。
final ValueNotifier<bool> kSecondaryPlayerOnPrimaryPages =
    ValueNotifier<bool>(true);

/// 底栏「形态交叉过渡」进度：0 = 常驻条外观/位置，1 = 悬浮胶囊外观/位置。
///
/// 一级常驻条（`MiniPlayer`）↔ 二级悬浮胶囊（`SecondaryMiniPlayer`）只是同一根
/// 底栏的两种形态，但两者分属**不同路由子树**：悬浮形态开启时壳层常驻条根本不挂载
/// （`app.dart` 的 `_buildBody` 在 `kSecondaryPlayerEnabled` 为真时早退），一级页面
/// 那条由 `PrimaryPagePersistentBar` 挂在 tab 内容底部、且会被 push 出来的页面整块
/// 盖住（`secondary_mini_player.dart` 该类的说明自述）。因此"就地 morph"没有共同
/// 载体 —— 由挂在 Navigator 之上的 `BottomBarMorphOverlay` 独占这一段过渡，两端
/// 真身在过渡窗口内各自让位（让位判据见各 bar 的 `kBottomBarFormProgress` 读取）。
///
/// 由 `_MainLayoutState` 的一条**一次性 260ms** 控制器写入（时长/曲线与底栏收展
/// 同源，见 [kBottomChromeToggleDuration]）；静止时停在端点、零帧成本，不新增任何
/// 常驻 Ticker / repeat（AGENTS §10）。
final ValueNotifier<double> kBottomBarFormProgress = ValueNotifier<double>(0.0);

/// 底栏形态**交棒飞行窗口**是否开启（`app.dart` 的 `_MainLayoutState` 写入）。
///
/// 与 [kBottomBarFormProgress]（动画进度）互补：进度在端点（0 / 1）无法区分
/// 「静止」与「飞行刚起跑」，而交棒必须让**源真身与目的真身**在正确的那一帧各自
/// 就位 —— 否则目的形态真身会抢闸画出（切换瞬间跳一下）。窗口用独立布尔：起跑与
/// 「让位基准」同帧置 true、动画收敛/吸附置 false。`p` 保持端点值、由动画自身推进。
final ValueNotifier<bool> kBarFormFlightActive = ValueNotifier<bool>(false);

/// 交棒窗口内**哪一端真身是源形态**（true = 常驻条端为源）。
///
/// 窗口内两端真身**都保持挂载**（不改挂载条件 —— 卸载会重建封面 State），可见性
/// 由它分流：**源端 onstage**（浮层天然盖在 Navigator 之上、把它盖住，故无需 offstage，
/// `保挂载` 成立）、**目的端 offstage**（避免「浮层 + 目的真身」同屏双条）。收敛当帧
/// 本值随窗口一起失效。
final ValueNotifier<bool> kBarFormResidentIsSource = ValueNotifier<bool>(true);

/// 底栏目标形态：0 = 常驻条，1 = 悬浮胶囊（**纯函数**，便于单测）。
///
/// **为什么是这三个输入**（依据 `secondary_mini_player.dart:205-212` 的形态分支）：
/// - [floatingEnabled]（`kSecondaryPlayerEnabled`）：总开关关闭时，一级与二级页面
///   都退回底部常驻条（`_buildBottomBarFallback`），恒为 0；
/// - [onPrimaryPages]（`kSecondaryPlayerOnPrimaryPages`）：开关开启时**一级页面**
///   也用悬浮胶囊，故一级页面不再落在常驻条上；
/// - [pageIsPrimaryNav]：当前页面是「一级导航页」（标题左对齐，判据同
///   `page_title_alignment.dart` 的 `isPrimaryNavTab`：`tab.pinnedTitle` 且未被 push）。
///
/// 三条合起来即 `_buildHost` 的分支：只有「**一级导航页** 且 一级页面退回常驻条」
/// 这一组才由常驻条承载；其余（二级页面、标题居中的 tab 页）一律悬浮胶囊。
double resolveBottomBarFormTarget({
  required bool floatingEnabled,
  required bool onPrimaryPages,
  required bool pageIsPrimaryNav,
}) {
  if (!floatingEnabled) return 0.0;
  if (!onPrimaryPages && pageIsPrimaryNav) return 0.0;
  return 1.0;
}

/// 底栏形态交棒的触发源（决定飞行窗口时机与是否真的交棒，会诊 D3 的幻影翻转
/// 排除；`_MainLayoutState._syncBarFormTarget` 消费，回归测试复刻同一枚举）。
enum BarFormFlipCause {
  /// 真实页面路由事件（push/pop/remove/replace）：窗口覆盖整段路由转场 +
  /// 随后的底栏收起/恢复（时长见 `resolveMorphFlightDuration`）。
  navigation,

  /// 两个形态开关的用户切换（沿用原 260ms 窗口）。
  settingsToggle,

  /// 用户在主导航栏切换 tab（沿用原 260ms 窗口）。
  tabSwitch,

  /// 其余一切重建顺带的目标重算（冷启动播种 / tab 配置装载 / 转屏 /
  /// 二级态推迟上报……）：一律**吸附端点**、不播交棒 —— 用户没有做出任何让
  /// 那根条换形态的动作，播动画就是幻影翻转。
  ambient,
}

/// 二级页面（及以后）是否收起底部导航栏（**默认 true = 隐藏**）。
///
/// 「二级页面」的认定只看**导航层级**：判据在 `responsive_shell.dart` 的
/// `_scheduleDepthReport`（中央栈是否有 push 出来的**页面**路由——`PopupRoute`
/// 弹层不算——∨ 双栏 tab 退化成单栏时详情面板是否独占整宽），由
/// `onSecondaryRouteChanged` 上报给主布局；**标题对齐不参与定级**，它只决定播放条
/// 形态（见 [kSecondaryPlayerOnPrimaryPages] 的判据说明）。关闭后这些页面保留底部
/// NavigationBar，播放条仍是悬浮形态（相当于悬浮在导航栏上方）。
///
/// 只管竖屏底栏：横屏侧边 NavigationRail 在二级页面同样收起（同一个二级判定），
/// 但不受本开关影响。顶层 `_MainLayout` 监听它触发重建。
final ValueNotifier<bool> kHideNavBarOnSecondaryPages =
    ValueNotifier<bool>(true);

/// 当前 tab 的中央栈顶停着「不保留播放栏」的二级路由页（二级路由形态的设置页，
/// 经 `lib/app.dart` `_pageForTabAsRoute` 的 `ResidentBarSuppressor` 包装）。
///
/// 置位期间隐藏 `_MainLayout` 底部常驻 MiniPlayer：这类页面按设计是纯界面
/// （「设置页不挂播放栏」）。原先推根 Navigator 时整页盖住常驻条、天然无播放栏；
/// 改推 tab 中央栈后常驻条在壳层之外盖不住，需要这个信号主动隐藏。
/// 消费方必须与「当前 tab 停在二级页面」合取（`_MainLayout._secondaryPageOnTop`，
/// 与 `kCoverFlowImmersive` 的消费方式同构）：该页被 IndexedStack 切到别的 tab
/// 后 notifier 不会复位（路由仍挂载），只有合取才能保证其它 tab 照常显示常驻条。
/// 只在常驻条形态（[kSecondaryPlayerEnabled] 关）下有消费方。
final ValueNotifier<bool> kSuppressResidentMiniPlayer =
    ValueNotifier<bool>(false);

/// 悬浮播放器折叠态（圆盘）的停靠位。
enum SecondaryPlayerDockSide {
  left,
  center,
  right;

  /// 从持久化原始字符串解析；非法/为空返回 null（调用方回退默认值）。
  static SecondaryPlayerDockSide? tryParse(String? raw) {
    if (raw == null) return null;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}

/// 悬浮播放器折叠态圆盘的水平停靠位。
///
/// 拖拽松手吸附后写入并持久化；未持久化过时由启动装载按设备形态给默认值
/// （手机 [SecondaryPlayerDockSide.center]、Pad [SecondaryPlayerDockSide.right]）。
/// 全局通知器而非实例状态：每个页面的悬浮播放器各有独立 State，
/// 停靠位必须跨页面一致。
final ValueNotifier<SecondaryPlayerDockSide> kSecondaryPlayerDock =
    ValueNotifier<SecondaryPlayerDockSide>(SecondaryPlayerDockSide.center);

/// 是否使用「桌面音乐软件式」外壳（侧栏 + 顶部工具栏 + 中央内容 + 全宽底部
/// 播放栏）。
///
/// 全项目桌面化分支的**唯一判定源**。现由用户设置 [kDesktopModeEnabled] 决定，
/// 不再自动按方向/尺寸切换：
/// - 关闭（默认）→ 恒返回 false，无论横竖屏都用 [ResponsiveScaffold]
///   （竖屏底部导航栏、横屏侧边 [NavigationRail]）；
/// - 开启 → 恒返回 true，无论横竖屏都用桌面外壳。
///
/// 保留 [context] 形参仅为兼容既有调用点签名。
bool isDesktopLayout(BuildContext context) => kDesktopModeEnabled.value;

/// 按容器**局部宽度**推导网格列数（计划 4.7 宽屏密度）。
///
/// 分栏 / 双栏会改变可用宽度，列数必须按面板内 [LayoutBuilder] 的局部宽度
/// 测量，而非全局 [MediaQuery]——否则窄详情/主列面板会塞进过多列。按每列
/// 目标宽度 [targetExtent] 均分，结果夹在 [min, max]。
int gridColumnsForWidth(
  double width, {
  double targetExtent = 200,
  int min = 2,
  int max = 6,
}) {
  if (width <= 0 || targetExtent <= 0) return min;
  final n = (width / targetExtent).floor();
  return n.clamp(min, max);
}

class ResponsiveLayout extends StatelessWidget {
  final WidgetBuilder compact;
  final WidgetBuilder? medium;
  final WidgetBuilder? expanded;

  const ResponsiveLayout({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenType = getScreenType(constraints.maxWidth);
        switch (screenType) {
          case ScreenType.compact:
            return compact(context);
          case ScreenType.medium:
            return (medium ?? compact)(context);
          case ScreenType.expanded:
            return (expanded ?? medium ?? compact)(context);
        }
      },
    );
  }
}

class ResponsiveScaffold extends StatefulWidget {
  final List<NavigationDestination> destinations;
  final List<NavigationRailDestination> railDestinations;
  final List<NavigationDrawerDestination> drawerDestinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget body;
  final Widget? compactBody;
  final Widget? mediumBody;
  final Widget? expandedBody;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;

  /// 为 true 时收起**竖屏底部 NavigationBar**（二级页面 / 封面流横屏沉浸）。
  ///
  /// 页面层级的认定见 `responsive_shell.dart` 的 `_scheduleDepthReport`（只看路由
  /// 深度与详情面板独占，不看标题对齐；口径同 [kHideNavBarOnSecondaryPages] 的说明），
  /// 用户侧开关见 [kHideNavBarOnSecondaryPages]（只作用于本参数，不影响横屏侧栏）。
  final bool hideNavigation;

  /// 为 true 时收起**横屏侧边 NavigationRail**（及分隔线）。
  ///
  /// null = 跟随 [hideNavigation]。主布局显式传"路由栈是否离开栈底"，让横屏
  /// 侧栏不受「二级页面隐藏菜单底栏」开关影响。
  final bool? hideRailNavigation;

  const ResponsiveScaffold({
    super.key,
    required this.destinations,
    required this.railDestinations,
    required this.drawerDestinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.body,
    this.compactBody,
    this.mediumBody,
    this.expandedBody,
    this.appBar,
    this.floatingActionButton,
    this.hideNavigation = false,
    this.hideRailNavigation,
  });

  @override
  State<ResponsiveScaffold> createState() => _ResponsiveScaffoldState();
}

class _ResponsiveScaffoldState extends State<ResponsiveScaffold>
    // TickerProviderStateMixin：State 持两个动画控制器（_chromeHide + _railHide），
    // SingleTicker 会抛 "multiple tickers were created"。
    with TickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 底栏收起进度：0 = 完整在场，1 = 已让位。
  ///
  /// 同源驱动四处：槽位高度与底栏下沉（`BottomChromeSlot`）、body 底部安全区
  /// 补偿（[_withAnimatedBottomInset]）、上报给播放条的净空口径
  /// （`BottomChromeScope.bottomChromeCollapse`）。
  late final AnimationController _chromeHide;

  /// 收起走 `chromeSinkEasing`（轻推起步、软着陆），展开走 `chromeRiseEasing`
  /// （平滑 ease-out、软着陆）—— 沉底利落、回升柔和，与常驻 MiniPlayer 的
  /// 收展走同一套运动语汇（见 `M3ExpressiveMotion` 底栏组注释）。
  late final Animation<double> _chromeHideCurve;

  /// 系统「减弱动态效果」：转场直接落端点、不播动画。
  ///
  /// 在 [didChangeDependencies] 里缓存（那里建立 MediaQuery 依赖合规），
  /// [didUpdateWidget] 用这份缓存值决定播动画还是直接落端点。
  bool _reduceMotion = false;

  /// 横屏侧栏的滑出动画控制器/曲线（与竖屏底栏同规格、独立驱动，理由见
  /// initState 注释）。
  late final AnimationController _railHide;
  late final Animation<double> _railHideCurve;

  /// NavigationRail 的实测宽度（滑出槽位按它收缩）。由 [_MeasureWidth] 在
  /// 首次布局时回填，兜底 96 = M3 rail 带 label 的默认宽；实测不触发
  /// setState——槽位宽度在 AnimatedBuilder builder 内逐帧重读字段，量到
  /// 新值自动生效。
  double _railWidth = kNavigationRailDefaultWidth;

  /// tv: 导航项焦点节点池，两个变体各一份（icon / selectedIcon），
  /// 在本 State 生命周期结束时统一 dispose。理由见 [_tvWrapNavIcon]。
  final Map<int, FocusNode> _navNodes = {};
  final Map<int, FocusNode> _navSelectedNodes = {};

  /// tv: 竖屏 NavigationBar 整项焦点节点池（每项 1 个）。
  ///
  /// 竖屏项是 icon + label 的整棵 [NavigationDestination]，随选中态稳定存在，
  /// 没有 selectedIcon 变体，故不像 [_tvWrapNavIcon] 那样分双池。
  /// 理由与释放同 [_navNodes]。
  final Map<int, FocusNode> _navItemNodes = {};

  @override
  void dispose() {
    _chromeHide.dispose();
    _railHide.dispose();
    for (final node in _navNodes.values) {
      node.dispose();
    }
    for (final node in _navSelectedNodes.values) {
      node.dispose();
    }
    for (final node in _navItemNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// 每个 tab 胶囊回弹动画的 key（竖屏 NavigationBar 用 icon，横屏
  /// NavigationRail 的 icon / selectedIcon 各占一个 key 槽位）。
  late List<GlobalKey<_CapsuleBounceState>> _bounceKeys;
  late List<GlobalKey<_CapsuleBounceState>> _selectedBounceKeys;

  /// tv: TV 首屏 autofocus 锚点只允许生效一次。
  ///
  /// 横屏 NavigationRail 的 icon / selectedIcon 是两个不同 GlobalKey 的
  /// `_CapsuleBounce`，选中态切换时二者整棵重挂载；若首项 DpadFocusable 的
  /// autofocus 常驻，tab 0 被切走再切回时新挂载的锚点会把焦点从别处抢回来。
  /// 首帧结束翻位（只被后续 build 读取，无需 setState），此后锚点不再请求
  /// 焦点。竖屏 NavigationBar 的 icon 元素跨选中态稳定存在、本就只挂载一次，
  /// 门控仅为两条路径行为一致。
  bool _tvNavAutofocusDone = false;

  @override
  void initState() {
    super.initState();
    // 首个 build 前就把进度定到端点：应用直接启动在二级页面时不播动画。
    _chromeHide = AnimationController(
      vsync: this,
      duration: kBottomChromeToggleDuration,
      value: widget.hideNavigation ? 1.0 : 0.0,
    );
    _chromeHideCurve = CurvedAnimation(
      parent: _chromeHide,
      curve: M3ExpressiveMotion.chromeSinkEasing,
      reverseCurve: M3ExpressiveMotion.chromeRiseEasing,
    );
    // 横屏侧栏的滑出动画：与竖屏底栏同规格（同时长/同曲线），但**独立驱动**
    // ——rail 的显隐目标（hideRailNavigation ?? hideNavigation）允许与底栏
    // （hideNavigation）分叉（「二级页面隐藏菜单底栏」开关只作用于底栏），
    // 复用 _chromeHideCurve 会在分叉场景拿错进度。
    _railHide = AnimationController(
      vsync: this,
      duration: kBottomChromeToggleDuration,
      value: (widget.hideRailNavigation ?? widget.hideNavigation) ? 1.0 : 0.0,
    );
    _railHideCurve = CurvedAnimation(
      parent: _railHide,
      curve: M3ExpressiveMotion.chromeSinkEasing,
      reverseCurve: M3ExpressiveMotion.chromeRiseEasing,
    );
    _bounceKeys = _initBounceKeys(widget.railDestinations.length);
    _selectedBounceKeys = _initBounceKeys(widget.railDestinations.length);
    // tv: 首帧结束即关闭 TV 首屏 autofocus 锚点——autofocus 在首帧焦点结算
    // 时已生效（dpad 的 Dpad.restoreFocus 明确让位给 autofocus 项），后续
    // 重建读到 true 不再抢焦点。仅 TV 构建需要。
    if (kTvBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tvNavAutofocusDone = true;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(covariant ResponsiveScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.railDestinations.length;
    if (_bounceKeys.length != count) {
      _bounceKeys = _initBounceKeys(count);
      _selectedBounceKeys = _initBounceKeys(count);
    }
    if (widget.hideNavigation != oldWidget.hideNavigation) {
      if (_reduceMotion) {
        _chromeHide.value = widget.hideNavigation ? 1.0 : 0.0;
      } else if (widget.hideNavigation) {
        _chromeHide.forward();
      } else {
        _chromeHide.reverse();
      }
    }
    // 横屏侧栏滑出：跟 rail 自己的显隐目标（可能与底栏分叉，见 initState 注释）。
    final bool hideRail = widget.hideRailNavigation ?? widget.hideNavigation;
    final bool oldHideRail =
        oldWidget.hideRailNavigation ?? oldWidget.hideNavigation;
    if (hideRail != oldHideRail) {
      if (_reduceMotion || kTvBuild) {
        _railHide.value = hideRail ? 1.0 : 0.0;
      } else if (hideRail) {
        _railHide.forward();
      } else {
        _railHide.reverse();
      }
    }
  }

  List<GlobalKey<_CapsuleBounceState>> _initBounceKeys(int count) {
    return List.generate(count, (_) => GlobalKey<_CapsuleBounceState>());
  }

  /// 点击 destination 完成后的统一入口：先触发该 tab 胶囊自驱动的水平
  /// 超出回弹（点击已选中项时），再转发原生选择回调（不改变原有切换行为；
  /// 切换选中项时胶囊由 _CapsuleBounce 的 didUpdateWidget 自动播放）。
  /// 选择类震动（EFFECT_TICK）：竖屏 NavigationBar / 横屏 NavigationRail 共用。
  void _handleDestinationSelected(int index) {
    AppHaptics.tick(HapticCategory.navigation);
    _bounceKeys[index].currentState?.playBounce();
    _selectedBounceKeys[index].currentState?.playBounce();
    widget.onDestinationSelected(index);
  }

  /// tv: 主导航（竖屏 NavigationBar / 横屏 NavigationRail）的 DpadRegion。
  ///
  /// memoryKey 让导航焦点位跨重建记忆（DpadEnterBehavior.restore：从内容区
  /// 回到导航时回到上次的项）。正常构建不包，触屏路径零变化
  /// （kTvBuild=false 整段树摇剔除）。
  Widget _tvWrapNavRegion(Widget child) {
    if (!kTvBuild) return child;
    return DpadRegion(
      memoryKey: 'tv/main-nav',
      debugLabel: 'main-nav',
      child: child,
    );
  }

  /// tv: 导航项图标的 TV 焦点包装（**逐项**）。
  ///
  /// 2026-10-04 实测修正：原先只包装**首项**作 autofocus 锚点，其余项依赖
  /// Material 原生 InkResponse 焦点（Rail 的项是 `_IndicatorInkWell`，无独立
  /// 焦点节点）。改为**每一项都包** DpadFocusable：上下键在项间稳定移动、
  /// OK 经 onSelect 走 [_handleDestinationSelected]（与触点同一套震动/胶囊
  /// 回弹/切换逻辑）。
  ///
  /// 包装粒度说明：竖屏 NavigationBar 的 [NavigationDestination] 是 widget，可整项
  /// 包装（见调用处）；NavigationRail 的 [NavigationRailDestination] **不是 widget**
  /// （是描述类，由 NavigationRail 内部转换），只能包它的 icon/selectedIcon。
  /// [DpadFocusable] 默认 excludeChildFocus=true，内层 InkResponse 不再产生第二个
  /// 停点。正常构建原样返回，触屏路径零变化。
  ///
  /// [autofocus] 仍只给首项、且受一次性门控 [_tvNavAutofocusDone] 约束：Rail 的
  /// icon/selectedIcon 跨选中态会整棵重挂载，autofocus 常驻会把焦点从别处抢回来。
  ///
  /// 每项的焦点节点登记到 [TvNavFocusBridge]，供内容区在焦点到达 scope 边缘时
  /// 显式移交（见该类的说明——dpad 不跨 FocusScope 收集候选）。
  Widget _tvWrapNavIcon(int index, Widget icon) {
    if (!kTvBuild) return icon;
    // 每个导航项持有**两个稳定节点**（icon 变体 / selectedIcon 变体各一），
    // 由 State 缓存、随本 State 生命周期 dispose——不能每次 build 新建（导航会
    // 随 setState 频繁重建，持续泄漏），也不能两个变体复用同一个（NavigationRail
    // 的 icon 与 selectedIcon 是两棵互斥子树，Flutter 的焦点节点只允许一个挂载
    // 点，复用会让两个 DpadFocusable 争抢并使 OK 键链路失效——2026-10-04 实测：
    // 焦点能移到导航栏但按 OK 不切 tab）。
    //
    // 每次构建把该节点登记到 [TvNavFocusBridge]：两个变体中当前真正挂载的那个
    // 会在本轮 build 里最后执行，登记结果即为可移交的活节点。
    final isSelected = widget.selectedIndex == index;
    final node = isSelected
        ? _navSelectedNodes.putIfAbsent(
            index,
            () => FocusNode(debugLabel: 'tv/nav-sel-$index'))
        : _navNodes.putIfAbsent(
            index,
            () => FocusNode(debugLabel: 'tv/nav-$index'));
    TvNavFocusBridge.instance.register(index, node);
    return DpadFocusable(
      focusNode: node,
      autofocus: index == 0 && !_tvNavAutofocusDone,
      onSelect: () => _handleDestinationSelected(index),
      child: icon,
    );
  }

  /// tv: 竖屏 NavigationBar 导航项的焦点包装（整项 = icon + label）。
  ///
  /// [NavigationDestination] 本身是 widget，故可整项包住：焦点框与选中胶囊一致，
  /// 比只圈图标的小方块更易辨识。逐项包装的理由同 [_tvWrapNavIcon]。
  Widget _tvWrapNavItem({
    required int index,
    required Widget child,
  }) {
    if (!kTvBuild) return child;
    // 节点复用禁忌同 [_tvWrapNavIcon]：本层由 AnimatedBuilder(_chromeHideCurve)
    // 逐帧重建，每次 build 新建 FocusNode 会逐帧泄漏且节点身份每帧变化
    // （收起动画期间焦点丢失）。竖屏整项只有一个变体，按项池化进
    // [_navItemNodes]，随本 State dispose 统一释放。
    // 每次构建把该节点登记到 [TvNavFocusBridge]，供内容区边缘移交。
    final node = _navItemNodes.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'tv/nav-$index'),
    );
    TvNavFocusBridge.instance.register(index, node);
    return DpadFocusable(
      focusNode: node,
      autofocus: index == 0 && !_tvNavAutofocusDone,
      onSelect: () => _handleDestinationSelected(index),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 底栏收起进度是**逐帧**量：槽位高度、底栏下沉、播放条净空口径、body 底部
    // 安全区补偿四处都读它，因此整层按帧重建。`widget.body` / `compactBody` 是
    // 跨帧不变的实例，页面子树不会跟着重建。
    return AnimatedBuilder(
      animation: _chromeHideCurve,
      builder: (BuildContext context, Widget? _) {
        final double collapse = _chromeHideCurve.value;
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool rail = usesNavigationRail(constraints.maxWidth);
            return BottomChromeScope(
              // 坞位存在性：收起动画期间底栏仍在槽位里（collapse < 1），
              // 播放条据此把净空口径线性过渡（见 BottomChromeScope 的说明）。
              hasBottomChrome: !rail && collapse < 1.0,
              bottomChromeCollapse: collapse,
              // 逐帧进度源：同一份收起动画本体，供消费方**订阅**（而不是对本
              // InheritedWidget 建立依赖）—— 后者会让整棵消费子树逐帧重建。
              collapseProgress: _chromeHideCurve,
              child: rail
                  ? _buildRailLayout(getScreenType(constraints.maxWidth))
                  : _buildCompactLayout(),
            );
          },
        );
      },
    );
  }

  Widget _buildCompactLayout() {
    // labelBehavior 由主题设置控制（NavigationBarThemeData.labelBehavior，
    // 跟随设置页「底部导航栏文字」三档切换）。
    final labelBehavior = Theme.of(context).navigationBarTheme.labelBehavior;
    // 底栏槽位总高 = 显式 height + NavigationBar 内部 SafeArea 自己补的底部
    // padding（见 flutter/material/navigation_bar.dart 的 build：Material →
    // SafeArea → SizedBox(height: effectiveHeight)）。`Scaffold` 给
    // bottomNavigationBar 的 MediaQuery 是 `removeBottomPadding: false`，
    // 所以这里读到的就是它实际会补的那一段。
    final double barHeight = labelBehavior ==
            NavigationDestinationLabelBehavior.alwaysHide
        ? BottomChromeDimens.navBarIconOnlyHeight
        : BottomChromeDimens.navBarWithLabelHeight;
    final double slotHeight = barHeight + MediaQuery.paddingOf(context).bottom;
    final double collapse = _chromeHideCurve.value;
    // 隐藏判定不能只看进度：恢复方向（reverse）起步的那一帧进度仍是 1.0，
    // 只看进度会让底栏在"第一帧就该重新进树"时仍被判为已隐藏、退化成硬切。
    // 目标态（widget.hideNavigation）与进度双条件：只有"收起方向 + 进度到 1"
    // 才移除槽位，两端语义与原实现一致（见不变量：collapse>=1 传 null）。
    final bool chromeHidden = collapse >= 1.0 && widget.hideNavigation;
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      // body 底部安全区补偿：底栏还在槽位里时 Scaffold 会把 body 的底部 padding
      // **整段移除**（`removeBottomPadding: bottomNavigationBar != null`），于是
      // 底栏收起过程中 body 底部 inset 一直是 0，直到槽位被移除那一帧才突然补回
      // 真实值 —— 那又是一处滞后跳变。这里按收起进度把该 inset 线性补回去；
      // 两端同样保持包装（见 _withAnimatedBottomInset：换 body 槽位的类型会重建
      // 整棵 body，常驻播放条的封面就会闪）。
      body: _withAnimatedBottomInset(
        context,
        widget.compactBody ?? widget.body,
        collapse,
      ),
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: chromeHidden
          ? null
          // 底栏必须在**有歌/无歌、任何主题**下都与今天逐像素一致：本分支只把
          // 原有 NavigationBar 包进"收起槽位 + 面板下沉"两层，内部一行未改。
          : BottomChromeSlot(
              collapse: collapse,
              slotHeight: slotHeight,
              child: BottomChromeSink(
                slotHeight: slotHeight,
                progress: PlayerPanelSignal.expansion,
                // tv: 主导航分区（memoryKey 'tv/main-nav'，边缘 leave）。正常构建
                // 原样返回 NavigationBar。
                child: _tvWrapNavRegion(
                  NavigationBar(
                    // 仅图标（alwaysHide）时高度减半紧凑显示（44）；
                    // 显示文字（始终显示/仅当前页）时用 64 紧凑高度，
                    // 比默认 80 更矮但仍能容纳 icon + label。
                    height: barHeight,
                    selectedIndex: widget.selectedIndex,
                    onDestinationSelected: _handleDestinationSelected,
                    // 每个 tab 的图标外包自定义胶囊（选中时显示，点击/切换后
                    // 胶囊水平超出回弹，图标不动）
                    destinations: [
                      for (int i = 0; i < widget.destinations.length; i++)
                        _tvWrapNavItem(
                          index: i,
                          child: NavigationDestination(
                            // 正常构建原样返回 _CapsuleBounce。
                            icon: _CapsuleBounce(
                              key: _bounceKeys[i],
                              selected: widget.selectedIndex == i,
                              child: widget.destinations[i].icon,
                            ),
                            label: widget.destinations[i].label,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// 把 body 的底部安全区 inset 按底栏收起进度补回去（见调用点说明）。
  ///
  /// **两端也必须包**：body 槽位上挂的 widget 类型一旦在转场两端变化
  /// （裸 body ↔ `MediaQuery(child: body)`），`Element.updateChild` 的 canUpdate
  /// 判据不成立，整棵 body 会被卸载重建 —— 常驻播放条就挂在 body 里，它的封面
  /// 会随 State 一起销毁、从零重新解析，真机表现为「底栏收起/恢复时封面闪一下」。
  /// 包装本身不改变数值：collapse=0 时补的是 0（底栏在场，Scaffold 已移除这段
  /// inset），chromeHidden 时补的是完整 inset（Scaffold 不再移除），两端都连续。
  Widget _withAnimatedBottomInset(
    BuildContext context,
    Widget body,
    double collapse,
  ) {
    final mq = MediaQuery.of(context);
    final double inset = mq.padding.bottom;
    // 无手势条净空时没有可补的量；这一判据不随转场变化，所以不会造成两端换型。
    if (!inset.isFinite || inset <= 0) return body;
    final double t = collapse.isFinite ? collapse.clamp(0.0, 1.0) : 0.0;
    return MediaQuery(
      data: mq.copyWith(
        padding: mq.padding.copyWith(bottom: inset * t),
      ),
      child: body,
    );
  }

  Widget _buildRailLayout(ScreenType screenType) {
    // 横屏侧栏文字跟随设置页「底部导航栏文字」三档
    //（NavigationBarThemeData.labelBehavior，与竖屏 NavigationBar 同源），
    // 映射到原生 NavigationRail 的 labelType。
    // null（主题未显式设置）按始终显示处理，与竖屏分支的默认行为一致。
    final labelBehavior =
        Theme.of(context).navigationBarTheme.labelBehavior ??
        NavigationDestinationLabelBehavior.alwaysShow;
    final labelType = switch (labelBehavior) {
      NavigationDestinationLabelBehavior.alwaysShow =>
        NavigationRailLabelType.all,
      NavigationDestinationLabelBehavior.onlyShowSelected =>
        NavigationRailLabelType.selected,
      NavigationDestinationLabelBehavior.alwaysHide => NavigationRailLabelType.none,
    };
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      // 横屏左右安全区：侧栏与内容避开异形屏/圆角屏的左右 cutout（刘海横置）。
      // 只保护左右，上下留给页面自身的 AppBar / body 处理。
      body: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            // 横屏侧栏滑出：原来是 Visibility(maintainState) 硬切（Offstage 瞬间
            // 消失/出现，morph 转场时非常突兀）。现改为与竖屏底栏同一套逐帧动画
            // 语言——槽位宽度按收起进度收缩（SizedBox），rail 本体保持固有宽、
            // 在槽位内**右缘对齐**（Align centerRight），左缘超出部分被 ClipRect
            // 裁掉——视觉即「rail 向屏幕左外侧滑出」，内容区随槽位收缩平滑扩展。
            //
            // 约束安全：整条链全部有界（Row 高度来自 Scaffold body；rail 收
            // SizedBox(width: 恒定) 的 tight 宽约束，与原 Row loose 下按固有宽
            // 布局等价）。不能用 OverflowBox(maxHeight: infinity) / UnconstrainedBox
            // 放开约束——rail 内部的 flex Column 会在无界方向崩（真机/测试复现）。
            //
            // rail **恒挂载**：Visibility 只在滑出完成后切 Offstage 省绘制
            // （maintainState 语义不变，body 不会因换型卸载重建）。TV 构建不接
            // 动画（_railHide 在 didUpdateWidget 里瞬时落端点），行为等价硬切。
            AnimatedBuilder(
              animation: _railHideCurve,
              builder: (context, _) {
                final hideRail =
                    widget.hideRailNavigation ?? widget.hideNavigation;
                final double c = kTvBuild
                    ? (hideRail ? 1.0 : 0.0)
                    : _railHideCurve.value.clamp(0.0, 1.0);
                // 同帧回填「当前可见的左缘保留宽」（_MeasureWidth 同款只写字段
                // 通道）：滑出全程逐帧收缩，供形态交棒浮层的胶囊端点跟随 rail
                // 滑出进度（见 navigationRailVisibleInset 的说明）。
                navigationRailVisibleInset =
                    navigationRailReservedWidth * (1 - c).clamp(0.0, 1.0);
                return Visibility(
                  // 滑出完成才 Offstage（收起方向 + 进度到 1，与竖屏底栏同口径）；
                  // 反向恢复的起步帧进度仍是 1.0，hideRail 已翻 false → 立即回树。
                  visible: !(hideRail && c >= 1.0),
                  maintainState: true,
                  child: ClipRect(
                    child: SizedBox(
                      width: _railWidth * (1 - c).clamp(0.0, 1.0),
                      // OverflowBox 的两个关键：
                      // - 宽度 tight 钉在 [_railWidth]：rail 不随槽位收缩被压扁
                      //   （否则 _MeasureWidth 会把收缩后的宽度回填进基准，形成
                      //   「越收越窄、回不到满宽」的反馈环）；
                      // - 高度经 LayoutBuilder 传**父级有界约束**（直接给 infinity
                      //   会让 rail 内部的 flex Column 在无界高度崩，测试复现）。
                      child: LayoutBuilder(
                        builder: (context, outer) => OverflowBox(
                          alignment: Alignment.centerRight,
                          minWidth: _railWidth,
                          maxWidth: _railWidth,
                          minHeight: outer.minHeight,
                          maxHeight: outer.maxHeight,
                          child: _MeasureWidth(
                            onWidth: (w) {
                              if (w.isFinite && w > 0) {
                                _railWidth = w;
                                // 同步布局外消费方（形变浮层的胶囊端点解析）：
                                // rail 实际占用 = 槽位 + 分隔线。
                                navigationRailReservedWidth =
                                    w + kNavigationRailDividerWidth;
                              }
                            },
                            // tv: 主导航分区（memoryKey 'tv/main-nav'，与竖屏
                            // NavigationBar 同一条路径共用；二者按宽度互斥，不会
                            // 同屏双 Region）。正常构建原样返回 NavigationRail。
                            child: _tvWrapNavRegion(
                              NavigationRail(
                                selectedIndex: widget.selectedIndex,
                                onDestinationSelected: _handleDestinationSelected,
                                // 每个 tab 的图标外包自定义胶囊（icon 与 selectedIcon
                                // 各占一个 key 槽位，同一时刻只有其一在树中；选中时
                                // 显示胶囊，点击/切换后胶囊水平超出回弹，图标不动）
                                destinations: [
                                  for (int i = 0; i < widget.railDestinations.length; i++)
                                    NavigationRailDestination(
                                      // tv: 逐项包 DpadFocusable（首项兼作 autofocus
                                      // 锚点，一次性门控防重挂载抢焦点）。
                                      // NavigationRailDestination 不是 widget，只能包
                                      // icon/selectedIcon。正常构建原样返回 _CapsuleBounce。
                                      icon: _tvWrapNavIcon(
                                        i,
                                        _CapsuleBounce(
                                          key: _bounceKeys[i],
                                          selected: widget.selectedIndex == i,
                                          child: widget.railDestinations[i].icon,
                                        ),
                                      ),
                                      selectedIcon: _tvWrapNavIcon(
                                        i,
                                        _CapsuleBounce(
                                          key: _selectedBounceKeys[i],
                                          selected: widget.selectedIndex == i,
                                          child: widget.railDestinations[i].selectedIcon,
                                        ),
                                      ),
                                      label: widget.railDestinations[i].label,
                                    ),
                                ],
                                leading: widget.floatingActionButton,
                                labelType: labelType,
                                // 原生胶囊已由 theme 关闭（indicatorColor transparent），
                                // 胶囊统一由 _CapsuleBounce 绘制
                                indicatorColor: Colors.transparent,
                                // 图标组垂直居中排列（groupAlignment 0 = 居中，-1 = 顶部）。
                                // tab 过多时 NavigationRail 内部自动滚动。宽度/间距均为
                                // 原生固定规格。
                                groupAlignment: 0.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            // 分隔线与侧栏同节奏：槽位宽度随收起进度归零 + 淡出（1px 线滑出无意义）。
            AnimatedBuilder(
              animation: _railHideCurve,
              builder: (context, _) {
                final hideRail =
                    widget.hideRailNavigation ?? widget.hideNavigation;
                final double c = kTvBuild
                    ? (hideRail ? 1.0 : 0.0)
                    : _railHideCurve.value.clamp(0.0, 1.0);
                return Visibility(
                  visible: !(hideRail && c >= 1.0),
                  maintainState: true,
                  child: ClipRect(
                    child: SizedBox(
                      width: (1 - c).clamp(0.0, 1.0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Opacity(
                          opacity: 1 - c,
                          child: VerticalDivider(
                            thickness: 1,
                            width: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            Expanded(child: screenType == ScreenType.expanded
                ? widget.expandedBody ?? widget.mediumBody ?? widget.body
                : widget.mediumBody ?? widget.body),
          ],
        ),
      ),
    );
  }
}

/// 量取 child 布局宽度并回调（rail 滑出槽位用）：在 performLayout 末尾读
/// size，**只回填字段、不触发 setState**——消费方（槽位宽度）在逐帧动画的
/// builder 里重读字段，量到新值自然生效。
class _MeasureWidth extends SingleChildRenderObjectWidget {
  const _MeasureWidth({required this.onWidth, super.child});

  final ValueChanged<double> onWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureWidth(onWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasureWidth renderObject,
  ) {
    renderObject.onWidth = onWidth;
  }
}

class _RenderMeasureWidth extends RenderProxyBox {
  _RenderMeasureWidth(this.onWidth);

  ValueChanged<double> onWidth;

  @override
  void performLayout() {
    super.performLayout();
    if (child != null && size.width.isFinite && size.width > 0) {
      onWidth(size.width);
    }
  }
}

/// 选中指示器胶囊（外观与 M3 原生胶囊一致：secondaryContainer 实心
/// StadiumBorder）+ 点击/切换后胶囊自驱动的水平方向超出回弹。
///
/// - 选中且未启用背景图时显示胶囊（背景图模式下隐藏，与原生覆写一致）；
/// - 胶囊回弹动画仅作用于胶囊本身（Transform.scaleX 包裹胶囊背景），
///   图标保持不动；
/// - 动画由 **m3e_core 官方预设弹簧**（[M3EMotion.standardPopup]：stiffness 1000 /
///   damping 0.6，见下方 `_bounceMotion`，非手调参数）驱动：
///   快速拉伸超出（1 → 1.2，过冲）后弹回
///   （1.2 → 1，过冲振荡收敛），自驱动播完；
/// - 不包任何手势/监听，避免与 NavigationBar / NavigationRail 自身的点击
///   竞争；动画由父级（_handleDestinationSelected 点击）或本组件
///   didUpdateWidget（selected false→true 切换）触发。
class _CapsuleBounce extends StatefulWidget {
  const _CapsuleBounce({
    super.key,
    required this.selected,
    required this.child,
  });

  final bool selected;
  final Widget child;

  @override
  State<_CapsuleBounce> createState() => _CapsuleBounceState();
}

class _CapsuleBounceState extends State<_CapsuleBounce>
    with SingleTickerProviderStateMixin {
  /// 回弹段 spring：**m3e_core 官方 MD3E 预设**（收口到
  /// [M3ExpressiveMotion.kFeedbackSpring] = `M3EMotion.standardPopup`：
  /// stiffness 1000 / damping 0.6，专为弹出类小部件设计的 bouncy 回弹），
  /// 过冲 ~9.5%，收敛干净，无需手调参数。
  static final _bounceMotion = M3ExpressiveMotion.kFeedbackSpring.toMotion();

  /// 拉伸段固定时长（spring 无固定时长，拉伸用短 animateTo 保证节奏可控）。
  static const Duration _stretchDuration = Duration(milliseconds: 80);

  /// 动画控制器 value 直接表示胶囊水平缩放（1.0 静止）。
  /// 值域覆盖 spring 的运动范围（拉伸过冲到 ~1.25、回弹过冲到 ~0.95）；
  /// 注意 AnimationController 默认值域 [0,1] 会把超出值 clamp 掉，必须显式放宽。
  late final AnimationController _controller;

  /// 系统「移除动画」：在 `didChangeDependencies` 缓存（该值经 dependencies 传播），
  /// 驱动动画前判一次，不在每帧读 MediaQuery。与父级 [ResponsiveScaffold] 的
  /// `_reduceMotion` 同一口径。
  bool _reduceMotion = false;

  /// playBounce 竞态守卫（自增序号）：见 [playBounce]。归属 State 实例，
  /// int 字段无需 dispose 释放。
  int _playGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      lowerBound: 0.8,
      upperBound: 1.4,
    );
    _controller.value = 1.0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(covariant _CapsuleBounce oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从未选中 → 选中（tab 切换）：胶囊出现时自动播放一次回弹
    if (!oldWidget.selected && widget.selected) {
      playBounce();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 播放一次完整脉冲：固定短时长快速拉伸超出（1→1.2，80ms），
  /// 完成后 spring 回弹（1.2→1.0，m3e_core 官方预设过冲收敛）。
  void playBounce() {
    // 每次 play 递增序号，链尾回调只认最新一次（见下方竞态说明）。
    final int generation = ++_playGeneration;
    _controller.stop();
    if (_reduceMotion) {
      // 系统「移除动画」：跳过整段 bounce，直接落终态（静止缩放 1.0），
      // 不产生中间帧回调，也不启动 stretch/spring。
      // 已在终态时连这一次赋值都不做（`value=` 无条件 notifyListeners，
      // 会让静止的胶囊白产一帧，§10.4.2）。
      if (_controller.value != 1.0) _controller.value = 1.0;
      return;
    }
    _controller
        .animateTo(1.2, duration: _stretchDuration, curve: Curves.easeOutCubic)
        .then((_) {
      // 拉伸完成后 spring 弹回（过冲振荡收敛）
      //
      // 竞态：`stop()` 会让上一次 `animateTo` 的 Future **立即完成**，其 `.then`
      // 随即执行并用 spring 覆盖第二次点击刚设的拉伸值 → 快速连点 tab 时动画
      // 互相打断。故校验自己仍是最新一次 play 才继续驱动，旧的直接放弃
      // （快速连点仍由最新那次重新起弹，语义不变）。
      if (mounted && generation == _playGeneration) {
        _controller.animateWith(
          _bounceMotion.createSimulation(start: 1.2, end: 1.0),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 背景图模式下隐藏胶囊（与原生覆写行为一致）
    final useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;
    final showCapsule = widget.selected && !useBackgroundImage;

    // 胶囊尺寸与 M3 NavigationIndicator 一致（64×32）
    return SizedBox(
      width: BottomChromeDimens.navCapsuleWidth,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 胶囊背景：点击后水平超出回弹（scaleX spring 动画仅作用于此层）
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.scale(
              scaleX: _controller.value,
              alignment: Alignment.center,
              child: Container(
                width: BottomChromeDimens.navCapsuleWidth,
                height: 32,
                decoration: showCapsule
                    ? ShapeDecoration(
                        color: colorScheme.secondaryContainer,
                        shape: const StadiumBorder(),
                      )
                    : null,
              ),
            ),
          ),
          // 图标：保持不动
          widget.child,
        ],
      ),
    );
  }
}

