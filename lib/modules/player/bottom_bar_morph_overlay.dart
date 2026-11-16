import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/layout/bottom_chrome_dimens.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/motion_constants.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/models/song.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'player_bar_progress_painter.dart';
import 'player_cover_morph_layer.dart';
import 'player_panel_frame.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 形态交叉过渡（一级常驻条 ↔ 二级悬浮胶囊）——W5
//
// 两条 bar 分属不同路由子树（见 `kBottomBarFormProgress` 的说明），过渡期间两端
// 各自身形让位，由本文件的 [BottomBarMorphOverlay] 独占**这一根条**并从一端几何
// 连续插值到另一端。几何端点见 `docs/plans/2026-10-11-player-bar-morph-plan.md` §2。
// ─────────────────────────────────────────────────────────────────────────────

/// 端点几何常量（设计像素）。与两处真身逐字节对齐，判据与
/// `test/core/layout/bottom_bar_morph_layout_test.dart` 一致。
///
/// 常驻条侧：高 = 进度 2 + 竖内边距 2×2 + 内容行 44；封面 44 / 圆角 6
/// （`AppRadius.cover`）；左右内缩 = `kMiniPlayerBaseSideInset`。
/// 胶囊侧：高 = `BottomChromeDimens.discDiameter`（64）；**可见封面 58 / 正圆**
/// （= `secondary_mini_player.dart` 的 `_kCoverDecode`，容器 64 内居中 → 四周
/// 3dp bezel；**不是**收起态圆盘的 56）；左右内缩 16（宿主
/// `SafeArea`+`Padding(16,0,16,12)`）、圆角 = 直径/2。
const double kMorphResidentBarHeight = 50.0;
const double kMorphResidentSideInset = 4.0;
const double kMorphResidentCoverSize = BottomChromeDimens.miniPlayerCoverSize;
const double kMorphResidentCoverRadius = AppRadius.cover;
/// 常驻条封面顶端（条内局部坐标）= 进度条 2 + 内容行上内边距 2。
const double kMorphResidentCoverTop = 4.0;
/// 常驻条内容行起笔（屏幕坐标）= 左内缩 + 封面 + 8dp 间隙。
const double kMorphResidentTextLeft =
    kMorphResidentSideInset + kMorphResidentCoverSize + 8.0;
const double kMorphResidentRowRight = 4.0;

const double kMorphCapsuleSideInset = 16.0;
/// 圆盘端（collapse=1）的条宽 = [BottomChromeDimens.discDiameter]（64），由
/// `resolveCapsuleBodyRect` 按收缩进度插值，不再单列常量。
/// 圆盘端**可见封面**边长 = 56（`secondary_mini_player.dart` 收起态 `coverVisible`
/// 的终点，`lerp(58, 56, _morph)`）。
const double kMorphDiscCoverSize = 56.0;
/// 圆盘端可见封面在 64 盒内的左上偏移 = (64 − 56) / 2 = 4。
const double kMorphDiscCoverInset =
    (BottomChromeDimens.discDiameter - kMorphDiscCoverSize) / 2;
/// 胶囊端**可见封面**边长 = `secondary_mini_player.dart` 的 `_kCoverDecode`（58）。
///
/// 展开态胶囊的封面就按 58 画：封面容器恒 64×64、封面圆在容器内居中，四周留
/// 3dp bezel 给进度包边（见该文件 `_kProgressStroke` 段注释）。**旧值 56 是收起
/// 态圆盘的封面尺寸**，当端点用会让浮层末帧与真身差 2dp 大小 + 3dp 位移
/// （会诊 D2 实测「浮层 56@left0 vs 真身 58@left3」），交棒瞬间封面"跳一下"。
const double kMorphCapsuleCoverSize = 58.0;
const double kMorphCapsuleCoverRadius = kMorphCapsuleCoverSize / 2;
/// 胶囊端可见封面在胶囊盒内的左上偏移 = (64 − 58) / 2 = 3。
const double kMorphCapsuleCoverInset =
    (BottomChromeDimens.discDiameter - kMorphCapsuleCoverSize) / 2;
/// 胶囊文字行起笔（胶囊内坐标）= 封面容器 64 + 2dp 视觉间隙。
const double kMorphCapsuleTextLeft = 66.0;
const double kMorphCapsuleRowRight = 10.0;

/// 两端形态的矩形登记簿（**设计像素、锚点空间**，含底部净空）。
///
/// **为什么是普通字段而不是 ValueNotifier**：登记发生在另一端 widget 的布局阶段，
/// 若用 notifier 会在那一帧触发 `markNeedsBuild`（"setState during build"）。浮层本身
/// 就被 `kBottomBarFormProgress` 逐帧驱动，读这两个字段即可拿到最新值，无需订阅。
/// 这与 `PlayerCoverMorphBus.pageOffset` 在 layout 阶段写入的既有做法同源。
class BottomBarMorphRegistry {
  BottomBarMorphRegistry._();

  static final BottomBarMorphRegistry instance = BottomBarMorphRegistry._();

  /// 常驻条矩形：`MiniPlayer` 自身 render box（锚点空间），底端 = 自身 box 底端
  /// （有底栏时压在底栏上、无底栏时到屏底）。量法同 `mini_player.dart` 的
  /// `_onRawDown`。
  ///
  /// 只在自己的路由是栈顶（`ModalRoute.isCurrent`）且未让位时登记 —— 被 push
  /// 出来的页面盖住、或转场平移中的矩形都不是「结算态」几何，登记进去只会把
  /// 端点算错（会诊 D2/D4；口诀：端点永远取**导航前最后一次结算态**的值）。
  Rect? residentRect;

  /// 悬浮胶囊矩形：胶囊宿主外框（`SafeArea`+12dp 底距+64 胶囊），底端到屏底。
  /// 量法同 `secondary_mini_player.dart` 的 `_captureMorphScene`。
  ///
  /// **浮层已不再消费它**（端点改为解析计算，见 [resolveCapsuleBodyRect]）——
  /// 宿主外框比可见胶囊本体宽 32 / 横偏 16，且只在非让位路径登记、飞行窗口内
  /// 冻结，直接用它会恒定偏 16px、宽 32px（会诊 D2/D4 实测 −81.9 / −114px）。
  /// 保留字段供场景快照与测试对照。
  Rect? capsuleRect;

  /// 交棒飞行开始那一刻的常驻条结算矩形快照。
  ///
  /// 飞行期间浮层**只认它**（`??` 回退 [residentRect]）：转场里其他 MiniPlayer
  /// 实例的重建、让位切换都可能改写 [residentRect]，逐帧读活值会让插值端点
  /// 中途漂移（会诊 D4 的「矩形冻结」正是现状如此，端点必须一次性冻结）。
  Rect? frozenResidentRect;

  /// 交棒目的端（胶囊侧）结算页面的内容区左缘保留宽（设计像素）。
  ///
  /// **结算快照存档**：驱动方在 [freezeResidentRectForFlight] 时写入（横屏二级页
  /// rail 已收 → 0，一级页 → rail 保留宽，竖屏恒 0）。**浮层已不再消费它** ——
  /// rail 的滑出发生在窗口后段（转场收敛后才起 260ms 动画），冻结常量会让前置
  /// 完成的可见形变把胶囊提前推到全宽、盖在仍在场的 rail 上（真机横屏跳变）；
  /// 浮层改为逐帧读 rail 的实时可见保留宽（[navigationRailVisibleInset]，由
  /// `_buildRailLayout` 同帧回填），rail 静止在场时两者同值。保留字段供冻结
  /// API 兼容与测试对照。
  double capsuleBodyLeadingInset = 0.0;

  /// 交棒目的端（胶囊侧）在**结算态**底栏是否已收起（飞行期间浮层据此算胶囊
  /// 端点的底部净空，见 [resolveCapsuleBodyRect] 的 `navVisibleAtSettle`）。
  ///
  /// 由驱动方在 [freezeResidentRectForFlight] 时写入：
  /// - 胶囊侧是 push/pop 的**二级页面**（导航交棒）：底栏收不收由
  ///   `kHideNavBarOnSecondaryPages` 决定（默认收，胶囊贴到屏底净空）；横屏
  ///   rail 布局本就没有底部导航栏，恒视为已收；
  /// - 胶囊侧是一级页（切 tab / 设置切换交棒）：竖屏底栏恒在场，胶囊要抬高一个
  ///   底栏槽位（`navBarHeight + safeBottom`），否则交棒会瞬时下沉一整段槽位；
  ///   横屏 rail 布局无底栏，同样视为已收。
  bool capsuleNavHiddenAtSettle = false;

  // —— 胶囊侧收缩态（圆盘）的事实登记（活字段，与 [residentRect] 同模式）——
  //
  // 悬浮条在二级页可被滚动收缩成 64×64 圆盘（`secondary_mini_player.dart` 的
  // `_morph`），停靠位可左/中/右、封面旋转中、文字行已淡出。交棒端点若仍按
  // 全宽展开胶囊解析（[resolveCapsuleBodyRect] 的旧行为），从圆盘态起飞的首帧
  // 会以全宽胶囊硬盖圆盘——观感即硬切。这三项由胶囊真身逐帧登记、飞行开启时
  // 冻结（见 [frozenCapsuleCollapseT] 组）。

  /// 胶囊当前收缩进度：0 = 展开胶囊，1 = 圆盘（`_morph.value` 的 clamp 值）。
  double capsuleCollapseT = 0.0;

  /// 圆盘停靠位（仅 collapse>0 有意义；展开胶囊恒全宽居中）。
  SecondaryPlayerDockSide capsuleDockSide = SecondaryPlayerDockSide.center;

  /// 圆盘封面当前旋转角（弧度，`_discAngle`；展开态恒 0 附近的累积值不消费）。
  double capsuleDiscAngle = 0.0;

  /// 交棒飞行开始那一刻的收缩态快照（与 [frozenResidentRect] 同理：飞行期间
  /// 端点必须一次性冻结，逐帧读活值会让插值端点中途漂移）。
  ///
  /// **只对「胶囊是源端」的飞行（pop 方向）有意义**；push 方向的目的端胶囊是
  /// 新页面挂出的展开态，消费方按 collapse=0 处理（见 `_buildBar`）。
  double? frozenCapsuleCollapseT;
  SecondaryPlayerDockSide? frozenCapsuleDockSide;
  double frozenCapsuleDiscAngle = 0.0;

  /// 本次交棒飞行的序号（每次 [freezeResidentRectForFlight] 自增）。
  ///
  /// 浮层据此识别「新的一次飞行」：可见形变的 [kBarFormVisibleMorphDuration]
  /// 时钟**按次起算** —— 飞行中途又发生导航（重定目标）时，新目标要从当前
  /// 形状重新走一段完整的形变，而不是沿用上一次飞行的时钟（旧时钟只会让它
  /// 贴在旧端点不动，交棒瞬间跳变，见 `_MorphBarLayerState._syncFlightClock`）。
  int flightSerial = 0;

  /// 为一次交棒飞行冻结常驻条端点（取当前结算值）并记录胶囊侧结算事实。
  void freezeResidentRectForFlight({
    required bool capsuleNavHiddenAtSettle,
    double capsuleBodyLeadingInset = 0.0,
  }) {
    frozenResidentRect = residentRect;
    this.capsuleNavHiddenAtSettle = capsuleNavHiddenAtSettle;
    this.capsuleBodyLeadingInset = capsuleBodyLeadingInset;
    frozenCapsuleCollapseT = capsuleCollapseT;
    frozenCapsuleDockSide = capsuleDockSide;
    frozenCapsuleDiscAngle = capsuleDiscAngle;
    flightSerial++;
  }

  /// 交棒飞行结束（含被撤销）/无飞行时解冻。
  void clearFrozenResidentRect() {
    frozenResidentRect = null;
    frozenCapsuleCollapseT = null;
    frozenCapsuleDockSide = null;
    frozenCapsuleDiscAngle = 0.0;
  }

  /// 当前挂在树上的胶囊所属的页面路由（`SecondaryMiniPlayer` 挂载期登记）。
  ///
  /// 用途 = 「这一页挂不挂播放条」的事实核对：push 进一个不挂胶囊的页面
  /// （设置子页、二级路由形态的设置页）时形态交棒没有可交棒的落点，必须
  /// 撤销飞行直接吸附端点（会诊 D3 的幻影翻转 ③）。按路由对象核对而不是
  /// 全局计数：后台 tab（IndexedStack 保活）也挂着胶囊，全局计数会误判。
  final Set<Route<dynamic>> _capsuleRoutes = <Route<dynamic>>{};

  void attachCapsuleRoute(Route<dynamic>? route) {
    if (route != null) _capsuleRoutes.add(route);
  }

  void detachCapsuleRoute(Route<dynamic>? route) {
    if (route != null) _capsuleRoutes.remove(route);
  }

  bool hasCapsuleForRoute(Route<dynamic>? route) =>
      route != null && _capsuleRoutes.contains(route);
}

// ─────────────────────────────────────────────────────────────────────────────
// 端点解析几何与飞行时长（纯函数，供 app.dart 的驱动与测试共用）
// ─────────────────────────────────────────────────────────────────────────────

/// 底部导航栏按「文字档位」的高度（与 `ResponsiveScaffold._buildCompactLayout`
/// 同一映射：仅图标 → 44，显示文字/未配置 → 64，见 `BottomChromeDimens`）。
///
/// 吐 m3e/material 的枚举按 `== alwaysHide` 判等（不 switch 全集），与本仓
/// 底栏分支的写法逐字同源（该处对 null 也落到 64）。
double resolveNavBarHeightForLabelBehavior(
  NavigationDestinationLabelBehavior? behavior,
) => behavior == NavigationDestinationLabelBehavior.alwaysHide
    ? BottomChromeDimens.navBarIconOnlyHeight
    : BottomChromeDimens.navBarWithLabelHeight;

/// 胶囊真身**可见本体**的结算矩形（纯解析，不测量）。
///
/// 口径 = `SecondaryMiniPlayer` 的盒子链：`SafeArea(top:false)` +
/// `Padding(16, 0, 16, 12)` + 64 高胶囊，贴在壳层 body 底端。二级页面结算时：
/// - 底栏收起（默认）→ body 到屏底、body 内补回 safeBottom →
///   `bottom = 屏高 − safeBottom − 12`；
/// - 底栏仍可见（`kHideNavBarOnSecondaryPages` 关）→ body 底端上移一个底栏槽位
///   （`navBarHeight + safeBottom`，槽位高口径见 ResponsiveScaffold），胶囊
///   随之抬高，否则会被底栏盖住一截。
///
/// **横屏 rail 布局口径**（[leadingReserve] > 0）：真身胶囊挂在 scaffold 的 body
/// 内，横屏时 body 从 rail + 分隔线右缘起（responsive_layout 的 `_buildRailLayout`），
/// 端点解析必须以同一内容区为基准 —— center 停靠取**内容区**中心、left 停靠贴
/// 内容区左缘，否则交棒横移差整段 rail 宽。内容区左缘由调用方逐帧给出（rail
/// 滑出/滑入动画期间逐帧变化，交棒浮层读 [navigationRailVisibleInset] 跟随；
/// 竖屏 / rail 已收起 = 0）。
///
/// **Pad 限宽**（[maxTrackWidth] > 0）：`SecondaryMiniPlayer` 在 Pad（最短边
/// ≥600dp）布局下把轨道限宽到该值（`BottomChromeDimens.discTrackMaxWidth`）并按
/// [dockSide] 停靠整条轨道；端点解析按同一式收缩，形变全程不出轨道。
///
/// **收缩态（圆盘）**：[collapse] = 1 时宽收缩到 64，在**轨道内**按 [dockSide]
/// 停靠收拢（左 16 / 居中 / 右 16，与真身 `Align` + `_dockBase` 的停靠几何逐值
/// 一致）；高度与圆角恒 64/32（胶囊与圆盘同高）。collapse=0 + center +
/// leadingReserve=0 + 不限宽 与旧口径逐字节相等。
///
/// **为什么必须解析而不是取登记值**：登记的是宿主外框（left=0、全屏宽），比
/// 可见本体宽 32 / 横偏 16；且转场中的登记带着路由平移量（会诊 D2/D4：
/// 实测交棒左缘 −81.9px / 右缘 −114px，换成解析几何后降到 2.1px）。
Rect resolveCapsuleBodyRect({
  required Size screenSize,
  required double safeBottom,
  double navBarHeight = 0.0,
  bool navVisibleAtSettle = false,
  double collapse = 0.0,
  SecondaryPlayerDockSide dockSide = SecondaryPlayerDockSide.center,
  double leadingReserve = 0.0,
  double maxTrackWidth = 0.0,
}) {
  final double collapsed = collapse.clamp(0.0, 1.0);
  // 胶囊真身所在的内容区：横屏 rail 布局时从 rail+分隔线右缘起，竖屏即全屏。
  final double areaLeft = leadingReserve.clamp(0.0, screenSize.width);
  final double areaWidth =
      (screenSize.width - areaLeft).clamp(0.0, screenSize.width);
  // 轨道宽 = 内容区减去两侧 16 内缩；Pad 布局再限宽（与真身
  // `trackW = min(constraints.maxWidth, discTrackMaxWidth)` 同式，
  // maxTrackWidth <= 0 = 不限宽）。
  double trackW = (areaWidth - kMorphCapsuleSideInset * 2).clamp(0.0, areaWidth);
  if (maxTrackWidth > 0) trackW = math.min(trackW, maxTrackWidth);
  final double width = lerpDouble(
    trackW,
    BottomChromeDimens.discDiameter,
    collapsed,
  )!;
  // 轨道盒按停靠位落在内容区内（真身 `Align` bottomLeft/Center/Right 的几何），
  // 收缩态在轨道内继续向停靠侧收拢（真身 `_dockBase` 的几何：展开态胶囊占满
  // 轨道，三个停靠位的左缘相同）。
  final double trackLeft;
  switch (dockSide) {
    case SecondaryPlayerDockSide.left:
      trackLeft = areaLeft + kMorphCapsuleSideInset;
    case SecondaryPlayerDockSide.right:
      trackLeft = areaLeft + areaWidth - kMorphCapsuleSideInset - trackW;
    case SecondaryPlayerDockSide.center:
      trackLeft = areaLeft + (areaWidth - trackW) / 2;
  }
  final double maxDx = (trackW - width).clamp(0.0, trackW);
  final double dockDx = switch (dockSide) {
    SecondaryPlayerDockSide.left => 0.0,
    SecondaryPlayerDockSide.center => maxDx / 2,
    SecondaryPlayerDockSide.right => maxDx,
  };
  final double bottomReserve = safeBottom + (navVisibleAtSettle ? navBarHeight : 0.0);
  return Rect.fromLTWH(
    (trackLeft + dockDx).clamp(0.0, screenSize.width),
    (screenSize.height - bottomReserve - 12.0 - BottomChromeDimens.discDiameter)
        .clamp(0.0, screenSize.height),
    width,
    BottomChromeDimens.discDiameter,
  );
}

/// 底栏形态交叉过渡的**飞行窗口**判据。
///
/// **单一出处**：浮层渲染、两端真身让位（`Offstage`）与真身的端点登记门控
/// 都必须读这一条 —— 判据一旦分叉就会出现「浮层在画但真身还在登记」之类的
/// 半状态，把冻结的端点冲掉（见 [BottomBarMorphRegistry]）。
///
/// **为什么读 [kBarFormFlightActive] 而不是 `0 < p < 1`（2026-10-12 会诊 W1）**：
/// `p` 在端点时无法区分「静止」与「飞行刚起跑」，而交棒必须在起跑那帧就让
/// 目的真身让位 —— 否则目的真身抢闸画出（跳变）。窗口开关与让位同帧置位，
/// `p` 保持端点值由动画自身推进。
///
/// **窗口判据与可见形变解耦**（K1）：窗口整段铺满（≈740ms，见
/// [resolveMorphFlightDuration]）；可见形态另按帧时钟前置到窗口开头的
/// [kBarFormVisibleMorphDuration] 内完成（见 [resolveVisibleBarFormProgress]）。
/// 两端真身的让位/登记门控必须继续读这条，**不要**改用可见形变进度 —— 那会让
/// 窗口在 260ms 处提前关闭、真身在转场未结束时接管那根条。
bool inBottomBarFormFlight() => kBarFormFlightActive.value;

/// 窗口内**某一形态的真身**是否应让位（`Offstage`）。
///
/// 窗口内两端真身都**保持挂载**（不改挂载条件），可见性由它分流：
/// - **源端**不 offstage（浮层天然盖住它，`保挂载` 成立，封面 State 不重建）；
/// - **目的端** offstage（避免「浮层 + 目的真身」同屏双条）。
///
/// [formIsCapsule]：被查询真身的形态（true = 悬浮胶囊端）。窗口外恒 false（各归各位）。
bool barFormRealBarStandsDown(bool formIsCapsule) {
  if (!inBottomBarFormFlight()) return false;
  final bool residentIsSource = kBarFormResidentIsSource.value;
  return formIsCapsule != !residentIsSource;
}

/// 浮层渲染 / 两端真身让位的公共订阅：窗口开关 + 窗口进度 + 源端标记。
Listenable get bottomBarFormFlightListenable => Listenable.merge([
  kBarFormFlightActive,
  kBottomBarFormProgress,
  kBarFormResidentIsSource,
]);

/// 转场收敛 → 底栏收起/恢复启动之间的固定延迟余量（两帧）。
///
/// 延迟链路：路由动画收敛 → 深度观察者 settle 回调（**帧末**补报）→
/// `ResponsiveScaffold.didUpdateWidget` 起收起控制器 → 控制器的首个 tick 是
/// elapsed=0。实测（回归测试）：按 [kBottomChromeToggleDuration] 整算会让交棒
/// 恰好早 1~2 帧发生，残差约 2.4px（底栏槽位高 88dp 的最后几个百分点）。
const Duration kBarFormFlightSettleSlack = Duration(milliseconds: 32);

/// 交棒飞行的持续时长。
///
/// 窗口必须覆盖**整段路由转场**（[transition]，导航时刻信号给出）：p 在转场期间
/// 贴旧端点就会出现「胶囊已就位后常驻条凭空长出」（会诊 D1/D3）。
/// 底栏还会在转场收敛瞬间起收起/恢复动画（[navWillToggle]）——两端真身要等它
/// 结束才落到结算端点，所以窗口再顺延一段 [kBottomChromeToggleDuration] 加
/// [kBarFormFlightSettleSlack]，否则 p 到达端点交棒时真身仍在半路
/// （交棒差 = 整个底栏槽位高，真机可见）。
Duration resolveMorphFlightDuration({
  required Duration transition,
  required bool navWillToggle,
}) => navWillToggle
    ? transition + kBottomChromeToggleDuration + kBarFormFlightSettleSlack
    : transition;

/// 可见形态变形要在**飞行窗口开头**走完的时长（K1：「变形太慢」的提速口径）。
///
/// **为什么是"前置完成"而不是缩短窗口**：窗口（= 转场 + 底栏收起 260ms + 2 帧
/// 容差，Android 默认转场 450ms 下 ≈740ms；见 [resolveMorphFlightDuration]）的
/// 时长与三个职责都保留 —— ① 浮层独占渲染；② 覆盖整段路由转场（窗口一短，
/// 两端真身会在转场未结束时接管那根条，条跟着页面继续滑，正是前几轮修掉的
/// "严重跳变"）；③ 覆盖转场后底栏收起/恢复的落定。提速只动**曲线**：把窗口
/// 进度 → 可见形态进度的映射折成"开头 260ms 走完全程、之后停在端点"（见
/// [resolveVisibleBarFormProgress]），窗口本身的判据（[inBottomBarFormFlight]
/// 读的未缓动进度）一帧不差。
///
/// 取值 = 底栏收起/恢复同一档（`kBottomChromeToggleDuration`，260ms）：形态
/// 交棒与底栏动效手感同源。**注意它必须 ≤ 最短的飞行窗口**（设置切换 / 切 tab
/// 线的窗口恰为 260ms），否则可见形变会被窗口提前掐断。
const Duration kBarFormVisibleMorphDuration = Duration(milliseconds: 260);

/// 可见形态进度（0 = 常驻条端点，1 = 悬浮胶囊端点）：把窗口进度折成"前置完成"
/// 的形变 —— 自飞行开始 [kBarFormVisibleMorphDuration] 内走完全程、之后停在
/// 端点（纯函数，端点可直接断言）。
///
/// [forward] = 飞向胶囊（常驻条 → 胶囊），[elapsed] = 自本次飞行开始已用时
/// （由浮层逐帧取帧时钟差，见 `_MorphBarLayerState`）。
///
/// 映射（`C` = [M3ExpressiveMotion.barFormMorphEasing]，强 ease-out）：
/// - 前向：`C(u)`；
/// - 反向：`C(1 − u)` —— 与 `CurvedAnimation(reverseCurve: Interval(1 − portion,
///   1.0, curve: C))` 逐值等价（反向时父值由 1 递减，镜像后同样在反向**开头**
///   就把形变走完，而不是拖到窗口末尾）。
/// 其中 `u = (elapsed / kBarFormVisibleMorphDuration).clamp(0, 1)`。
///
/// 端点精确：`u == 0` / `u == 1` 时 `C` 的入参恰为 0 / 1，而 `Curve.transform`
/// 对 t == 0 / 1 有精确短路 —— 交棒两端帧逐值等于真身端点（不会留亚像素残差）。
@visibleForTesting
double resolveVisibleBarFormProgress({
  required bool forward,
  required Duration elapsed,
}) {
  final Curve easing = M3ExpressiveMotion.barFormMorphEasing;
  final double u =
      (elapsed.inMicroseconds / kBarFormVisibleMorphDuration.inMicroseconds)
          .clamp(0.0, 1.0);
  return forward ? easing.transform(u) : easing.transform(1.0 - u);
}

/// 一次交叉过渡的几何解算结果（纯数据，端点/插值可直接断言）。
///
/// 除 [barLeft]/[barTop]/[barWidth]/[barHeight] 为屏幕坐标外，其余均为**条内局部**坐标。
@immutable
class MorphBarLayout {
  const MorphBarLayout({
    required this.t,
    required this.barLeft,
    required this.barTop,
    required this.barWidth,
    required this.barHeight,
    required this.barRadius,
    required this.coverLeft,
    required this.coverTop,
    required this.coverSize,
    required this.coverRadius,
    required this.rowLeft,
    required this.rowRight,
    required this.rowTop,
    required this.rowBottom,
    required this.progressHeight,
    required this.lyricOpacity,
    required this.lyricWidthFactor,
    required this.rowOpacity,
    required this.coverRotation,
  });

  /// 形态进度（0 = 常驻条，1 = 悬浮胶囊）。
  final double t;

  final double barLeft;
  final double barTop;
  final double barWidth;
  final double barHeight;
  final double barRadius;

  /// 封面盒（条内局部）。
  final double coverLeft;
  final double coverTop;
  final double coverSize;
  final double coverRadius;

  /// 内容行（条内局部）：[rowLeft]/[rowRight] 为左右边界，[rowTop]/[rowBottom] 为上下内缩。
  final double rowLeft;
  final double rowRight;
  final double rowTop;
  final double rowBottom;

  /// 进度盒高：常驻条 = 贴顶 2dp 直线，胶囊 = 整条 64（内缘包边）。
  final double progressHeight;

  /// 「桌面歌词」按钮（常驻条有、胶囊无）：不透明度与宽度收缩系数。
  final double lyricOpacity;
  final double lyricWidthFactor;

  /// 内容行（文字 + 按钮）整体不透明度：常驻端 1；胶囊端 = 1 − 收缩进度
  /// （圆盘态文字行已淡出，形变时随展开连续浮现）。
  final double rowOpacity;

  /// 封面旋转角（弧度，绕封面中心）：圆盘端 = 冻结的 `_discAngle`，常驻端 0
  /// —— 从旋转中的圆盘起飞时首帧与其逐角度对齐，向常驻条端旋正归零。
  final double coverRotation;
}

/// 解算交叉过渡几何（纯函数、无副作用）。
///
/// 端点由两端**实测矩形**给出（[residentRect] / [capsuleRect]，含底端净空口径），
/// 故 `p == 0` 逐值等于常驻条端点、`p == 1` 逐值等于胶囊端点（见测试）。中间线性插值。
MorphBarLayout resolveMorphBarLayout({
  required double p,
  required Rect residentRect,
  required Rect capsuleRect,
  double capsuleCollapse = 0.0,
  double capsuleDiscAngle = 0.0,
}) {
  final double t = p.isFinite ? p.clamp(0.0, 1.0) : 0.0;
  double l(double a, double b) => lerpDouble(a, b, t)!;
  // 胶囊端的「端点内插值」：收缩进度 c 先与形态进度 t 分离 —— 端点几何
  // （[capsuleRect]）已按 c 折算过，这里只处理**端点内部**随 c 变化的量
  // （封面尺寸/内缩/行透明度）。
  final double c = capsuleCollapse.clamp(0.0, 1.0);

  final double barLeft = l(residentRect.left, capsuleRect.left);
  final double barTop = l(residentRect.top, capsuleRect.top);
  final double barWidth = l(residentRect.width, capsuleRect.width);
  // 常驻条端高度取**实测** `residentRect.height`（含底部净空 clearance）：真身高度
  // = 内容 50 + `clearance.bottom`（无底栏 / 横屏侧栏 / 二级页时 ≈20dp），硬编码 50
  // 会让端点矮一段、条底错位（2026-10-12 会诊 W3）。约定 `residentRect` 恒含净空
  // （登记口径见 mini_player 的 `_scheduleRegisterResidentRect`，兜底见
  // `_fallbackResidentRect`），故无需再加项。
  final double barHeight = l(
    residentRect.height,
    BottomChromeDimens.discDiameter,
  );
  final double barRadius = l(0.0, BottomChromeDimens.discDiameter / 2);

  // 封面盒（条内局部）：两端都锚在**可见封面**的真实左上角 —— 常驻条 left = 4
  // （内容行内缩 4）、胶囊 left = 3（64 盒里 58 封面居中）；圆盘端封面 56 在
  // 64 盒里内缩 4（`kMorphDiscCoverSize` / [kMorphDiscCoverInset]）。
  //
  // **不能**用 `capsuleRect.left - barLeft`（= 0）当胶囊端：那是胶囊**宿主**左缘，
  // 封面容器虽然左缘钉死在 0，但可见封面在容器里还内缩 3dp —— 会诊 D2 实测
  // 末帧 56@left0 vs 真身 58@left3，交棒瞬间封面横跳 3px。
  final double capsuleCoverSize = lerpDouble(
    kMorphCapsuleCoverSize,
    kMorphDiscCoverSize,
    c,
  )!;
  final double capsuleCoverInset = lerpDouble(
    kMorphCapsuleCoverInset,
    kMorphDiscCoverInset,
    c,
  )!;
  final double coverLeft = l(kMorphResidentSideInset, capsuleCoverInset);
  final double coverSize = l(kMorphResidentCoverSize, capsuleCoverSize);
  final double coverRadius = l(
    kMorphResidentCoverRadius,
    // 随收缩插值的封面半径（圆盘端 56/2=28）：用常量 29 会让圆盘端差 1dp。
    capsuleCoverSize / 2,
  );

  // 内容行：左起笔由"封面 + 间隙"决定，右端各留自身内边距。行盒坐标恒**相对
  // 条体盒**（渲染时 Positioned 在条盒内），常驻端取自身常量、不得再减
  // `residentRect.left` —— 横屏 rail 布局下常驻条盒左缘 = rail 保留宽（非 0），
  // 旧式 `常量 − barLeft` 会把行盒推出条盒左缘（实测 −41px）。
  final double rowLeft = l(kMorphResidentTextLeft, kMorphCapsuleTextLeft);
  final double rowRight = l(
    residentRect.width - kMorphResidentRowRight,
    barWidth - kMorphCapsuleRowRight,
  );

  return MorphBarLayout(
    t: t,
    barLeft: barLeft,
    barTop: barTop,
    barWidth: barWidth,
    barHeight: barHeight,
    barRadius: barRadius,
    coverLeft: coverLeft,
    // 常驻条 4（进度 2 + 内边距 2）→ 胶囊 3（(64 − 58) / 2），逐值锚在两端
    // 真身可见封面的顶端（旧写法恒 4，胶囊端差 1px）。
    coverTop: l(kMorphResidentCoverTop, capsuleCoverInset),
    coverSize: coverSize,
    coverRadius: coverRadius,
    rowLeft: rowLeft,
    rowRight: rowRight,
    // 常驻条内容行上下为 4/2（进度占 2 + 行上内边距 2、行下方 2），胶囊为
    // 0/0（行居中于 64）。上行内缩取 `kMorphResidentCoverTop`（= 4，与封面顶端
    // 同源）——恒等于常驻条真身行盒，旧注释写的 2/2 与实际值不符。
    rowTop: l(kMorphResidentCoverTop, 0.0),
    rowBottom: l(2.0, 0.0),
    progressHeight: l(kPlayerBarProgressLineStroke, barHeight),
    lyricOpacity: 1.0 - t,
    lyricWidthFactor: 1.0 - t,
    // 圆盘态文字行已淡出（真身 `textOpacity = 1 − t/0.6` 在 t=1 时为 0）：
    // 端点取 1 − c，形变中随 t 连续浮现。胶囊端歌词按钮本就随 t 淡出，不叠乘。
    rowOpacity: lerpDouble(1.0, 1.0 - c, t)!,
    // 起飞帧与旋转中的圆盘逐角度对齐（端点 = 冻结角 × t），向常驻端归零。
    coverRotation: capsuleDiscAngle * t,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 共用内容原子（三方共用：常驻条 / 悬浮胶囊 / 交叉过渡浮层）
//
// 只抽**内容**（歌名·歌手文字块、播放控制、桌面歌词按钮），布局参数（左内缩、
// 行宽、对齐）留在各自容器里 —— 两端本就用同一份 `bodyMedium` /
// `bodySmall(onSurfaceVariant)` 与同一套 `IconButton(visualDensity: compact)`，
// 抽出来只为让浮层不再写**第三份行内容**（同一个文案/按钮只有一个实现）。
// ─────────────────────────────────────────────────────────────────────────────

/// 底栏「歌名 + 歌手」文字块（三方共用）。
class PlayerBarText extends StatelessWidget {
  const PlayerBarText({
    super.key,
    required this.song,
    required this.titleStyle,
    required this.subtitleStyle,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.textAlign,
    this.lineAlignment,
    this.miniLineAlign = Alignment.centerLeft,
  });

  final Song song;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;

  /// 块内两行的横向对齐（常驻条 `start`、胶囊 `center`）。[lineAlignment] 非空时忽略。
  final CrossAxisAlignment crossAxisAlignment;

  /// 单行文字在自身盒内的对齐（常驻条不传 = `start`，胶囊 `center`）。
  ///
  /// **交叉过渡浮层不要再传它**：`TextAlign` 是**离散**枚举，按 t 硬切一次就是
  /// 一次可见台阶（实测：长标题被省略号截断时，中段一跳 5.5px）。浮层改用
  /// [lineAlignment] 做连续插值 —— 它配合 [lineAlignment] 非空时的
  /// `TextWidthBasis.longestLine`（见 build）让**每一行的盒**都收缩到行宽，
  /// 于是摆位权回到连续的 `Align`，两端逐值等价真身（`t=0` 贴左 = 常驻条；
  /// `t=1` 逐行居中 = 胶囊）。
  final TextAlign? textAlign;

  /// 非空时：**每一行各自**按该对齐在所在整行宽内定位（列改为 `stretch`，行盒 =
  /// 容器宽），`Alignment.lerp(centerLeft, center)` 即可把常驻条「两行都靠左」
  /// 连续插值到胶囊「每行各自居中」。
  ///
  /// **为什么必须是行级而不是把整块 `Align`（会诊项，四条报障之「歌手/专辑文字
  /// 对齐方式突变」）**：块级对齐只能把「整块」挪到中间，块内两行始终保持左对齐。
  /// 歌名比歌手长时（常态），交棒瞬间歌手行会从「块的左缘」跳到「整行居中」，
  /// 横移 = (歌名宽 − 歌手宽) / 2 —— 用户看到的就是「文字对齐方式突变」。
  /// 胶囊真身的实现是 `CrossAxisAlignment.center` 逐行居中（
  /// `secondary_mini_player.dart` 的 `_expandedRow`），行级插值的 `t == 1` 端点
  /// 与它逐值等价；`t == 0`（两行都贴左缘）与常驻条真身逐值等价。
  final Alignment? lineAlignment;

  /// 本块作为**飞行起点**时上报给形变层的行对齐（见
  /// [PlayerCoverMorphBus.miniTextAlign]）。缺省贴左 = 常驻条口径；胶囊真身逐行
  /// 居中，须传 [Alignment.center]，否则飞行层从贴左起飞、交棒瞬间文字跳左。
  final Alignment miniLineAlign;

  @override
  Widget build(BuildContext context) {
    final lineAlign = lineAlignment;
    Widget line(Text text) =>
        lineAlign == null ? text : Align(alignment: lineAlign, child: text);
    // 行级插值时把「行盒」收缩到**该行文字自己的宽度**（`longestLine`）：
    // 否则被省略号截断的行会撑满容器宽（`TextAlign` 才有事可做的唯一场景），
    // 连续插值的 `Align` 反而没有可摆位的余量 —— 摆位权被迫交回离散的
    // `TextAlign`，中段就是一条看得见的台阶（实测长标题 5.5px）。
    // 盒宽 = 行宽之后：`t=1` 的 `Align(center)` 位移 = `(容器宽 − 行宽)/2`，
    // 与胶囊真身 `textAlign: center` 的位移逐值相等（实测 88.38 ↔ 88.38）；
    // `t=0` 的 `Align(centerLeft)` 位移 = 0，与常驻条真身逐值相等。
    // 只在 `lineAlignment` 非空时启用，两端真身的静态外观零变化。
    final textWidthBasis = lineAlign == null
        ? TextWidthBasis.parent
        : TextWidthBasis.longestLine;
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      // stretch 让每行占满容器宽，行级 Align 才有可摆位的余量；两端真身
      // （常驻条 start / 胶囊 center + 紧宽列）不受影响。
      crossAxisAlignment: lineAlign != null
          ? CrossAxisAlignment.stretch
          : crossAxisAlignment,
      children: [
        line(
          Text(
            song.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            textWidthBasis: textWidthBasis,
            style: titleStyle,
          ),
        ),
        line(
          Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            textWidthBasis: textWidthBasis,
            style: subtitleStyle,
          ),
        ),
      ],
    );
    // 探针包在文字块外层：上报本块的屏幕矩形作为形变起点（与两端同源）。
    return MiniPlayerTextSlot(
      title: song.displayName,
      subtitle: song.artist,
      titleStyle: titleStyle,
      subtitleStyle: subtitleStyle,
      lineAlign: miniLineAlign,
      child: column,
    );
  }
}

/// 底栏播放控制（播放/暂停 + 下一首），三方共用。
///
/// [showNext] 为 false 时只渲染播放/暂停——TV 顶栏迷你条的下一首入口移出
/// （完整播放页与通知栏均有等价入口，需求口径）。默认 true，既有调用点
/// （常驻条 / 交叉过渡浮层）逐像素不变。
class PlayerBarTransport extends StatelessWidget {
  const PlayerBarTransport({super.key, required this.player, this.showNext = true});

  final PlayerProvider player;
  final bool showNext;

  @override
  Widget build(BuildContext context) {
    // 自建重绘边界（修「Windows 鼠标点暂停整窗卡一下」）：裸 `IconButton` 的
    // 水波画在按钮内层 `Material` 的 ink 层，`markNeedsPaint` 会冒泡到最近边界；
    // 迷你条/浮层外层没有边界时，一次点击会把整条底栏之外的内容一起重绘。
    return RepaintBoundary(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: () {
              AppHaptics.click(HapticCategory.transport);
              if (player.isPlaying) {
                player.pause();
              } else {
                player.resume();
              }
            },
          ),
          if (showNext)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.skip_next),
              onPressed: () {
                AppHaptics.click(HapticCategory.transport);
                player.next();
              },
            ),
        ],
      ),
    );
  }
}

/// 底栏「桌面歌词」按钮（常驻条有、胶囊无），常驻条与浮层共用。
///
/// [opacity]/[widthFactor] 供交叉过渡浮层把它**淡出并收掉宽度**（胶囊端没有这个
/// 按钮）。常驻条侧两个参数保持 1.0，逐像素与改动前一致。
class PlayerBarLyricButton extends StatelessWidget {
  const PlayerBarLyricButton({
    super.key,
    required this.opacity,
    required this.widthFactor,
  });

  final double opacity;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    if (widthFactor <= 0.001 || opacity <= 0.001) {
      return const SizedBox.shrink();
    }
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = DesktopLyricService.instance.enabled;
    final button = IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: enabled ? '关闭桌面歌词' : '开启桌面歌词',
      icon: Icon(
        enabled ? Icons.lyrics : Icons.lyrics_outlined,
        color: enabled ? colorScheme.primary : null,
      ),
      onPressed: () => toggleDesktopLyricFromBar(context),
    );
    if (opacity >= 1.0 && widthFactor >= 1.0) return button;
    return ClipRect(
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor.clamp(0.0, 1.0),
        child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: button),
      ),
    );
  }
}

/// 切换桌面歌词并同步通知栏状态（常驻条侧与交叉过渡浮层共用，逐字等于
/// `mini_player.dart` 改动前那段 `onPressed`）。
Future<void> toggleDesktopLyricFromBar(BuildContext context) async {
  await DesktopLyricService.instance.toggle();
  if (!context.mounted) return;
  (context as Element).markNeedsBuild();
  // 同步通知栏"桌面歌词"按钮状态
  final player = context.read<PlayerProvider>();
  final song = player.currentSong;
  // 收藏状态需实时查询，避免暂停时显示为未收藏
  bool isFavorited = false;
  if (song != null) {
    try {
      isFavorited = context.read<FavoritesProvider>().isFavorite(song.id);
    } catch (_) {}
  }
  await MediaNotificationService.updateNotification(
    // 用 displayName 剥离 .mp3 等后缀，避免标题显示文件名
    title: song?.displayName ?? '',
    artist: song?.artist ?? '',
    artUrl: song?.artworkUri,
    isPlaying: player.isPlaying,
    position: player.position,
    // 时长兜底：_duration 为空时用曲目元数据自带的总时长（见
    // PlayerProvider._pushNotification 的同口径注释）。
    duration: player.duration ?? song?.duration ?? Duration.zero,
    desktopLyricEnabled: DesktopLyricService.instance.enabled,
    isFavorited: isFavorited,
    // 与 PlayerProvider._pushNotification 同口径：Windows 侧发布到 SMTC，
    // 供第三方任务栏歌词工具做身份/匹配/时间轴外推。
    album: song?.album ?? '',
    albumArtist: song?.artist ?? '',
    playbackRate: player.speed,
    loopMode: player.loopMode.name,
    shuffleEnabled: player.shuffleEnabled,
  );
}

/// 底栏文字样式的唯一取值处（两形态本就同值：`bodyMedium` / `bodySmall(onSurfaceVariant)`）。
({TextStyle? title, TextStyle? subtitle}) playerBarTextStyles(
  BuildContext context,
) {
  final textTheme = Theme.of(context).textTheme;
  final colorScheme = Theme.of(context).colorScheme;
  return (
    title: textTheme.bodyMedium,
    subtitle: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
  );
}

/// 挂在 **Navigator 之上**的底栏形态交叉过渡浮层（`app.dart` 的 Stack，
/// 位于 `PlayerDragOverlay` **之前** —— 形变层/封面层必须盖在它上面）。
///
/// 只在飞行窗口 `0 < p < 1` 渲染；`p <= 0` / `p >= 1` 返回零尺寸盒子（静止时
/// 零成本、零布局影响）。TV 构建恒不渲染（TV 本就没有常驻条↔胶囊切换）。
class BottomBarMorphOverlay extends StatelessWidget {
  const BottomBarMorphOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    if (kTvBuild) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: bottomBarFormFlightListenable,
      builder: (context, _) {
        if (!inBottomBarFormFlight()) return const SizedBox.shrink();
        return _MorphBarLayer(progress: kBottomBarFormProgress.value);
      },
    );
  }
}

/// 供测试断言的**构建计数探针**（O2）：条层子树（[_MorphBarLayerState] 的
/// `ValueListenableBuilder` builder）累计真实构建次数。
///
/// 自增包在 `assert` 里 —— release 构建零成本、不参与任何逻辑。测试用它证明
/// 「可见形变饱和后不再逐帧重建子树」：窗口后段该计数不再增长。
@visibleForTesting
int barMorphSubtreeBuildCount = 0;

/// 浮层那根条的逐帧渲染层。
///
/// **可见形变 = 窗口进度的"前置完成"映射**（K1）：[progress] 是飞行窗口进度
/// （整段铺满，[inBottomBarFormFlight] 的窗口判据一帧不动），本层再按帧时钟把
/// 它折成"开头 [kBarFormVisibleMorphDuration] 内走完、之后停在端点"的可见形态
/// 进度（[resolveVisibleBarFormProgress]）—— 用户看到的形变 ≤260ms，余下的
/// 窗口时间浮层停在端点等两端真身落定（窗口不能被砍短的理由见
/// [resolveMorphFlightDuration]）。
class _MorphBarLayer extends StatefulWidget {
  const _MorphBarLayer({required this.progress});

  final double progress;

  @override
  State<_MorphBarLayer> createState() => _MorphBarLayerState();
}

class _MorphBarLayerState extends State<_MorphBarLayer> {
  /// 可见形变时钟起点（帧时钟）。飞行开始 + [kBarFormVisibleMorphDuration]
  /// 之后可见形态停在端点。
  Duration _flightClockStart = Duration.zero;

  /// 形变方向：true = 飞向胶囊（常驻条端点起飞）。
  bool _forward = true;

  /// 已起算时钟的飞行序号（见 [BottomBarMorphRegistry.flightSerial]）。
  /// 初值 -1：挂载首帧必定起算一次。
  int _flightSerial = -1;


  /// 可见形变进度的**唯一驱动通道**（O2）。
  ///
  /// 本层每帧仍被窗口进度（[kBottomBarFormProgress]）重建，但重建只做两件事：
  /// ① `_syncFlightClock()` 维护形变时钟；② 把本帧 `visible` 写进这个 notifier。
  /// [ValueNotifier] 自带 `==` 判等 —— **数值不变就不 notify**；而可见形变在窗口
  /// 开头 [kBarFormVisibleMorphDuration] 内走完、之后恒为端点常值（`Curve.transform`
  /// 对 t == 0 / 1 有精确短路），故窗口后段每一帧都不再触发子树重建 —— 这正是被
  /// 砍掉的"静止尾巴"（≈28 帧/次）。
  final ValueNotifier<double> _visibleNotifier = ValueNotifier<double>(0.0);

  /// 胶囊端点左缘保留宽的**第二驱动通道**（横屏 rail 滑出跟随）。
  ///
  /// 横屏 rail 布局下胶囊端点的 leadingReserve 不再是冻结常量，而是逐帧跟随
  /// rail 槽位的实时保留宽（[navigationRailVisibleInset]，见 `_buildBar`）——
  /// 该值在窗口**后段**（rail 转场收敛后才起 260ms 滑出）仍在变化，而那时
  /// [kBottomBarFormProgress] 对应的可见形变早已饱和在端点、[_visibleNotifier]
  /// 不再 notify。若子树只听 visible，浮层会冻在「inset 尚未收缩」的画面里，
  /// rail 滑完后真身接管瞬间左缘跳回全宽（跳变）。因此把每帧的 live inset 也写
  /// 进这个 notifier：`==` 判等，**只有 rail 真在动才触发子树重建**；竖屏 / rail
  /// 静止时恒同值，O2 的「静止尾巴零重建」原样保留。初值 NaN：首帧必通知一次
  /// （首帧本就构建子树，等价空操作）。
  final ValueNotifier<double> _leadingInsetNotifier = ValueNotifier<double>(
    double.nan,
  );

  /// 条层子树的缓存实例（只在首帧 `??=` 构造一次，此后每帧返回**同一实例**）。
  ///
  /// Flutter 的 `Element.updateChild` 在新旧 widget 恒等时短路返回、**不进入子树**，
  /// 于是窗口后段零重建；形变推进不再依赖"父级重建顺带重建子树"，改由
  /// [_visibleNotifier] 单独驱动（见 [build]）。端点画面与饱和前逐像素同源：那段
  /// 时间里 `visible` 未变、子树输入未变，缓存实例就是最后一次饱和帧的产物。
  Widget? _subtree;

  /// 静态子件复用槽（[PlayerBarTransport]）：详见 [_transportFor]。
  PlayerProvider? _transportPlayer;
  bool? _transportPlaying;
  Widget? _transport;

  @override
  void dispose() {
    _visibleNotifier.dispose();
    _leadingInsetNotifier.dispose();
    super.dispose();
  }

  /// （重新）起算可见形变时钟（在 build 内调用，帧时钟只在帧内有效）。
  ///
  /// 起点 = 当前帧。**首帧必定起算**：本层挂载在 `kBottomBarFormProgress` 第一次
  /// 离开端点的那一帧（窗口第 2 帧），此刻形变尚未开始 ⇒ 首帧可见形态贴在起飞端
  /// 点、与让位前的真身逐像素同值（交棒无痕）。
  ///
  /// 飞行**中途**又发生导航（序号变化）时同样重算：新目标从当前形状重新走一段
  /// 完整形变，而不是沿用旧时钟贴在旧端点（沿用会让反向飞行整段停在旧端点，
  /// 窗口结束交棒到另一端时整段跳变）。
  ///
  /// 方向取"离得近的一端"（[Widget.progress] < 0.5 侧）：正常飞行在窗口头一两帧
  /// 挂载（progress ≈ 0 或 ≈ 1），判定与真实起飞端逐值一致；中途重定目标时它是
  /// 「不把已完成形变往回拽」的保守选择。
  void _syncFlightClock() {
    final int serial = BottomBarMorphRegistry.instance.flightSerial;
    if (serial == _flightSerial) return;
    _flightSerial = serial;
    _flightClockStart = SchedulerBinding.instance.currentFrameTimeStamp;
    _forward = widget.progress < 0.5;
  }

  @override
  Widget build(BuildContext context) {
    _syncFlightClock();
    // 逐帧现取帧时钟差（本层本就被窗口进度逐帧重建，不新增帧提交，
    // 也不新增 Ticker/Timer —— AGENTS §10）。
    final double visible = resolveVisibleBarFormProgress(
      forward: _forward,
      elapsed:
          SchedulerBinding.instance.currentFrameTimeStamp - _flightClockStart,
    );
    // 只在数值**真变化**时通知（[ValueNotifier] 对 `==` 相同的值不 notify）。
    // 形变走完后 visible 恒为端点常值 → 不再 notify → 子树停止逐帧重建。
    //
    // 赋值发生在 build 期、目标是本层**后代**（下方 `ValueListenableBuilder`）：
    // 框架允许「祖先正在构建时标脏其后代」，且该后代会在**同一帧**内被重建
    // （`BuildOwner.buildScope` 处理期间新增的脏元素会被重新排序并继续处理），
    // 故形变不会滞后一帧。
    _visibleNotifier.value = visible;
    // 横屏 rail 跟随（第二通道）：写本帧的 live 左缘保留宽，rail 真在动才
    // notify（见字段注释）。写在 build 期、目标是本层后代，与上面
    // `_visibleNotifier` 同一帧内被处理（框架允许祖先 build 期标脏后代）。
    _leadingInsetNotifier.value = _currentLeadingInset(context);
    // 返回缓存的子树实例（首帧 `??=` 构造）：恒等实例让 `updateChild` 短路，
    // 这就是"窗口后段不再重建子树"的落点；形变推进由 visible notifier 承担，
    // rail 滑出期的端点位移由 inset notifier 承担 —— 两条通道任一变化才重建。
    return _subtree ??= ListenableBuilder(
      listenable: Listenable.merge([_visibleNotifier, _leadingInsetNotifier]),
      builder: (context, _) => _buildBar(context, _visibleNotifier.value, null),
    );
  }

  /// 本帧胶囊端点应采用的**内容区左缘保留宽**。
  ///
  /// 横屏（rail 布局）= rail 槽位+分隔线的实时可见保留宽（[navigationRailVisibleInset]，
  /// 由 rail 的逐帧 builder 回填，滑出/滑入全程跟随）；竖屏恒 0。旧口径读驱动方
  /// 在导航时刻冻结的结算快照（[BottomBarMorphRegistry.capsuleBodyLeadingInset]），
  /// 但 rail 的滑出发生在窗口**后段**（转场收敛后才起 260ms 动画），冻结常量会让
  /// 前置完成的可见形变把胶囊提前推到全宽、盖在仍在场的 rail 上（真机横屏跳变）。
  double _currentLeadingInset(BuildContext context) =>
      usesNavigationRail(MediaQuery.sizeOf(context).width)
      ? navigationRailVisibleInset
      : 0.0;

  /// 条层子树：只在 [visible] 真变化、或所依赖的 Provider / Theme / MediaQuery
  /// 变化时重建（O2 之前是窗口内**每帧**）。
  Widget _buildBar(BuildContext context, double visible, Widget? _) {
    assert(() {
      barMorphSubtreeBuildCount++;
      return true;
    }());
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return const SizedBox.shrink();
    // 依赖收窄（O2）：Theme 一次取全、拆成需要的 aspect（避免每帧多次
    // `Theme.of` 查找）；MediaQuery 改取 size / padding 两个 **aspect** ——
    // 键盘等 viewInsets 变化不再触发本条重建（全量 `MediaQuery.of` 会）。
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final Size screenSize = MediaQuery.sizeOf(context);
    final double screenWidth = screenSize.width;
    final double screenHeight = screenSize.height;

    // 常驻条端点：**导航前最后一次结算态登记值**（飞行期间由驱动方冻结，
    // 见 BottomBarMorphRegistry.frozenResidentRect）—— 不用转场中的实时登记。
    final registry = BottomBarMorphRegistry.instance;
    final double safeBottom = MediaQuery.paddingOf(context).bottom;
    // 底栏槽位高（按文字档位：仅图标 44 / 显示文字 64）。两个端点的底部净空
    // 都要算它：常驻条端在一级页面（底栏恒在场）；胶囊端只在驱动方记录的
    // 结算态底栏已收起（[BottomBarMorphRegistry.capsuleNavHiddenAtSettle]）时
    // 才不收槽位。
    final double navBarHeight = resolveNavBarHeightForLabelBehavior(
      theme.navigationBarTheme.labelBehavior,
    );
    final bool navVisibleAtSettle = !registry.capsuleNavHiddenAtSettle;
    // 收缩态端点只对「胶囊是源端」的飞行（pop 方向）有意义：push 方向的目的端
    // 胶囊是新页面挂出的展开态，恒 collapse=0。活字段兜底仅防冻结漏写（驱动方
    // 忘调 freeze 的异常路径），正常流程冻结值在飞行开启那一刻已就位。
    final bool capsuleIsSource = !kBarFormResidentIsSource.value;
    final double collapse = capsuleIsSource
        ? (registry.frozenCapsuleCollapseT ?? registry.capsuleCollapseT)
        : 0.0;
    // 目的端胶囊（push 方向）与源端共用同一条全局停靠位（kSecondaryPlayerDock，
    // Pad 布局默认右下）：Pad 轨道限宽后三个停靠位的落点不再重合，不能再恒取
    // center；手机布局轨道 = 全宽，三停靠位几何相同，取值变化无观感影响。
    final SecondaryPlayerDockSide dockSide = capsuleIsSource
        ? (registry.frozenCapsuleDockSide ?? registry.capsuleDockSide)
        : registry.capsuleDockSide;
    final double discAngle = capsuleIsSource
        ? registry.frozenCapsuleDiscAngle
        : 0.0;
    // 横屏（rail 布局）口径：常驻条真身挂在 body 内、内容区从 rail+分隔线右缘
    // 起，且没有底部导航栏 —— 兜底矩形据此右移、不再预留底栏槽位（登记值本身
    // 是实测矩形，天然正确；只有兜底路径需要按屏幕口径现算）。
    final bool railLayout = usesNavigationRail(screenWidth);
    final residentRect =
        registry.frozenResidentRect ??
        registry.residentRect ??
        _fallbackResidentRect(
          screenWidth,
          screenHeight,
          safeBottom: safeBottom,
          navBarHeight: railLayout ? 0.0 : navBarHeight,
          // 兜底路径同样用实时可见保留宽（rail 半滑出时兜底矩形不悬空）。
          leadingReserve: railLayout ? navigationRailVisibleInset : 0.0,
        );
    // 胶囊端点：解析计算（不测量），口径与真身可见本体一致（见 resolveCapsuleBodyRect）。
    // 内容区左缘保留宽 = rail 槽位的**实时可见**保留宽（横屏 push 交棒时 rail 等
    // 转场收敛才起 260ms 滑出，端点逐帧跟随才不会在 rail 在场时把胶囊推到全宽；
    // 竖屏 / rail 已收 = 0）。旧的冻结结算快照（capsuleBodyLeadingInset）正是
    // 「点击瞬间即全宽」跳变的根源，已由逐帧跟随取代；rail 静止在场时本值恒等于
    // 旧快照（一级页交棒），行为不变。Pad 布局轨道限宽到 discTrackMaxWidth
    // （与真身 trackW 同式）。
    final capsuleRect = resolveCapsuleBodyRect(
      screenSize: screenSize,
      safeBottom: safeBottom,
      navBarHeight: navBarHeight,
      navVisibleAtSettle: navVisibleAtSettle,
      collapse: collapse,
      dockSide: dockSide,
      leadingReserve: _currentLeadingInset(context),
      maxTrackWidth: isPadLayout(context)
          ? BottomChromeDimens.discTrackMaxWidth
          : 0.0,
    );

    final layout = resolveMorphBarLayout(
      // 几何一律吃**可见**形变进度（前置完成映射后的值），不是窗口进度：
      // 形变在窗口开头 260ms 内走完、之后停在端点（K1）。
      p: visible,
      residentRect: residentRect,
      capsuleRect: capsuleRect,
      capsuleCollapse: collapse,
      capsuleDiscAngle: discAngle,
    );
    // 文字样式内联（与 `playerBarTextStyles` 逐值同源），复用上面已取好的
    // theme 两个 aspect，省掉每帧两次额外的 InheritedWidget 查找。
    final TextStyle? titleStyle = textTheme.bodyMedium;
    final TextStyle? subtitleStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final background = resolveMiniPlayerBackground(
      colorScheme,
      // 判定用用户开关本身：`backgroundImageProvider` 在无用户图时会回落到
      // 内置默认壁纸，"开关开 + 未选图"是正常状态，仍属壁纸模式。
      //（此前误用 isBackgroundImageEffective，会让这类状态下底色退化成纯色。）
      useBackgroundImage: context.watch<ThemeProvider>().useBackgroundImage,
    );
    // 两端进度轨道色不同（plan §2 修正段）：常驻条 = surfaceContainerHighest
    // （调用点显式覆盖值），胶囊 = onSurfaceVariant@0.16。按 formT 插值后再交给
    // 同一个 painter（active 两形态同为 primary）。
    final trackColor =
        Color.lerp(
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurfaceVariant.withValues(alpha: 0.16),
          layout.t,
        )!;

    // 进度取**真身同一条通道**（常驻条的 `positionNotifier`，见 mini_player 的
    // 进度 ValueListenableBuilder）：生产里 `_updatePosition` 把 `_position` 与
    // notifier 一起写（player_provider.dart:733-738），读哪个都同源同值；
    // 这里读 notifier 是为了让「交棒两端同值」可在测试里直接对账。
    // 采样本就不用新起定时器：浮层由 kBottomBarFormProgress 逐帧重建，
    // 每帧现取即可（AGENTS §10 口径）。
    final position = player.positionNotifier.value;
    final duration = player.duration;
    final double playbackProgress = (duration != null &&
            duration.inMilliseconds > 0)
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          // 条体在屏内，无需溢出裁剪；默认 hardEdge 即可（与浮层其余成员一致）。
          children: [
            Positioned(
              left: layout.barLeft,
              top: layout.barTop,
              width: layout.barWidth,
              height: layout.barHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(layout.barRadius),
                child: Stack(
                  children: [
                    // 底色（含底部净空）：与两端同源取色（resolveMiniPlayerBackground），
                    // 端点处与真身逐像素同值。
                    Positioned.fill(child: ColoredBox(color: background)),
                    // 进度：同一个 painter 从贴顶直线（formT=0）连续变形为内缘包边
                    // （formT=1）。盒子高由 2 插值到整条高，中心线随之张开。
                    Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      height: layout.progressHeight,
                      child: CustomPaint(
                        painter: PlayerBarProgressPainter(
                          progress: playbackProgress,
                          formT: layout.t,
                          // 中心线锚在**条盒**中心（不是进度盒中心）：进度盒高由 2
                          // 长到整条高，若中心线恒取进度盒中线，中段包边会贴在条体
                          // 偏上处、被后画的封面盖住（2026-10-12 会诊 W2）。端点不变
                          // （t=0 退化为贴顶直线，t=1 = 条盒中心 = 胶囊真身中心）。
                          barHeight: layout.barHeight,
                          trackColor: trackColor,
                          activeColor: colorScheme.primary,
                          cornerRadius: layout.barRadius,
                          gapSize: kPlayerBarProgressLineGap,
                          strokeCap: StrokeCap.round,
                          stopIndicatorSize: kPlayerBarProgressLineStopSize,
                        ),
                      ),
                    ),
                    // 封面：44/圆角 6 → 58/正圆（圆盘端 56）。盒（left/top/size/
                    // radius）由 `resolveMorphBarLayout` 逐帧插值，且两端逐值锚在
                    // 真身可见封面上；位图解码尺寸恒为胶囊档 58（见
                    // `_MorphCoverArtwork`），由 FittedBox 承担缩放，避免逐帧换
                    // 解码尺寸。圆盘起飞时按冻结角旋转、向常驻端归零（Transform
                    // 在 Clip 内侧，旋转中也不会溢出封面盒裁切）。
                    Positioned(
                      left: layout.coverLeft,
                      top: layout.coverTop,
                      width: layout.coverSize,
                      height: layout.coverSize,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(layout.coverRadius),
                        child: Transform.rotate(
                          angle: layout.coverRotation,
                          child: FittedBox(
                            fit: BoxFit.fill,
                            child: SizedBox(
                              width: kMorphCapsuleCoverSize,
                              height: kMorphCapsuleCoverSize,
                              child: _MorphCoverArtwork(song: song),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 内容行：文字块 + 桌面歌词按钮（渐隐收缩）+ 播放控制。
                    // 圆盘端整行已隐（rowOpacity = 1 − collapse），随形变连续浮现。
                    Positioned(
                      left: layout.rowLeft,
                      right: layout.barWidth - layout.rowRight,
                      top: layout.rowTop,
                      bottom: layout.rowBottom,
                      child: Opacity(
                        opacity: layout.rowOpacity.clamp(0.0, 1.0),
                        child: Row(
                        children: [
                          Expanded(
                            child: PlayerBarText(
                              key: const ValueKey('morph-bar-text'),
                              song: song,
                              titleStyle: titleStyle,
                              subtitleStyle: subtitleStyle,
                              // 行级对齐连续插值：两端逐值等于常驻条「两行贴左」
                              // 与胶囊「每行居中」，中途不再有对齐突变。
                              // **不传 `textAlign`**：那是离散枚举，按 t 硬切会
                              // 在中段留一条可见台阶（旧写法 `t < 0.5 ? start :
                              // center`，实测长标题 5.5px）；`lineAlignment`
                              // 配合 `longestLine` 之后，行盒收缩到行宽，摆位
                              // 全由这条连续的 `Align` 承担，两端与真身逐值等价。
                              lineAlignment: Alignment.lerp(
                                Alignment.centerLeft,
                                Alignment.center,
                                layout.t,
                              ),
                            ),
                          ),
                          PlayerBarLyricButton(
                            opacity: layout.lyricOpacity,
                            widthFactor: layout.lyricWidthFactor,
                          ),
                          _transportFor(player),
                        ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 静态子件（[PlayerBarTransport]）复用：内容只随播放态变、**不随 visible 变**，
  /// 按 (player 实例, isPlaying) 记忆化，形变期间不逐帧重建那排按钮。
  ///
  /// **不缓存 `PlayerBarLyricButton`**：它的 `opacity`/`widthFactor` 逐帧吃
  /// `layout.t`（`1 → 0` 的淡出收缩），无条件缓存会把它钉死在某个中间态。
  Widget _transportFor(PlayerProvider player) {
    final bool playing = player.isPlaying;
    final Widget? cached = _transport;
    if (cached != null &&
        identical(_transportPlayer, player) &&
        _transportPlaying == playing) {
      return cached;
    }
    _transportPlayer = player;
    _transportPlaying = playing;
    return _transport = PlayerBarTransport(player: player);
  }
}

/// 常驻条矩形缺失时的兜底：贴内容底端、内容区全宽、内容高 50。
///
/// 底端净空 = safeBottom + 底栏槽位高（有底栏时常驻条压在底栏上方）。旧版兜底
/// 底端落在屏底、漏了整段净空 —— 真机手机会差一个安全区（会诊 D4：24dp）。
/// 横屏 rail 布局由调用方传 [leadingReserve]（rail+分隔线保留宽）与
/// navBarHeight=0：常驻条在 body 内从 rail 右缘起、屏底没有底栏。
Rect _fallbackResidentRect(
  double width,
  double height, {
  double safeBottom = 0.0,
  double navBarHeight = 0.0,
  double leadingReserve = 0.0,
}) {
  final double bottom = (height - safeBottom - navBarHeight).clamp(0.0, height);
  final double left = leadingReserve.clamp(0.0, width);
  return Rect.fromLTWH(
    left,
    (bottom - kMorphResidentBarHeight).clamp(0.0, height),
    (width - left).clamp(0.0, width),
    kMorphResidentBarHeight,
  );
}

/// 浮层封面本体：按歌曲 memo，转场逐帧只改外层缩放盒，不重解码（同
/// `player_cover_morph_layer.dart` 的 `_MorphCoverFlight` 思路）。
class _MorphCoverArtwork extends StatefulWidget {
  const _MorphCoverArtwork({required this.song});

  final Song song;

  @override
  State<_MorphCoverArtwork> createState() => _MorphCoverArtworkState();
}

class _MorphCoverArtworkState extends State<_MorphCoverArtwork> {
  Object? _signature;
  Widget? _artwork;

  @override
  Widget build(BuildContext context) {
    final signature = Object.hash(
      widget.song.id,
      widget.song.artworkUri,
      widget.song.localPath,
    );
    final cached = _artwork;
    if (cached != null && _signature == signature) return cached;
    // 解码尺寸恒取**两端里最大的可见尺寸**（= 胶囊档 58，即
    // `secondary_mini_player.dart` 的 `_kCoverDecode`）：① FittedBox 向下缩到
    // 44 是降采样，任意中间帧都不糊、更不会在 p→1 端被放大；② `size` 参与
    // `SmartArtworkImage` 的 `cacheWidth`（image key），与胶囊**同键同档**——
    // 旧值 56 三方独有，每次飞行都是全新一档 → 首帧必走占位/淡入（「切换瞬间
    // 封面闪烁」的直接来源）；改成胶囊同键后，胶囊此前展示过就是缓存命中，
    // 且浮层在飞行中把该键保持在缓存热区，胶囊交棒首帧也是命中。
    final artwork = SmartArtworkImage(
      artworkUri: widget.song.artworkUri,
      fallbackFilePath: widget.song.localPath,
      songId: widget.song.id,
      size: kMorphCapsuleCoverSize,
      borderRadius: 0,
    );
    _signature = signature;
    _artwork = artwork;
    return artwork;
  }
}
