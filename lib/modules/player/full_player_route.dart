import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/motion_constants.dart';
import '../../providers/theme_provider.dart';
import '../../providers/car_mode_provider.dart';
import '../../utils/landscape_immersive.dart';
import 'full_player.dart';
import 'full_player_am.dart';
import 'player_cover_morph.dart';
import 'player_morph_scene.dart';
import 'player_panel_frame.dart';
import '../../core/layout/bottom_chrome_dimens.dart';
import '../../core/layout/bottom_chrome_sink.dart';

/// 全局过渡进度（0.0 = mini，1.0 = full）。
///
/// 状态本体在 [PlayerPanelSignal]（core/layout）：底部导航栏的下沉
/// （`BottomChromeSink`）也要读它，而 core 不能反向 import 本模块。
/// 这里保留同名顶层量作为**别名**，既有调用点无需改动。
final ValueNotifier<double> playerExpansion = PlayerPanelSignal.expansion;

/// 基础触发阈值：屏幕高度的 20%。
/// 上滑距离达到或超过该阈值后松手，FullPlayer 完整展开。
const double kPlayerExpandDistanceRatio = 0.2;

/// 速度阈值（px/s，向上为正）：快速上滑即使距离不足也展开。
const double kPlayerFlingVelocityThreshold = 900.0;

/// 加速度阈值（px/s²）：强加速度（快速甩动）即使距离不足也展开。
const double kPlayerAccelerationThreshold = 6000.0;

/// 回拉速度阈值（px/s，向下为正）：松手瞬间手指仍向下运动的速度超过该值，
/// 判定为用户「上滑后往回拉」（此时加速度方向同样向下），视为取消展开。
const double kPlayerPullBackVelocityThreshold = 100.0;

/// 点击进入时的抽屉上滑比例（`FractionalTranslation` 的 y）。
/// 与 [kPlayerExpandDistanceRatio] 一起构成"两条进入路径"的全部映射常量。
const double kPlayerTapEntryOffsetRatio = 0.15;

/// 展开（进入）时长。[DraggablePlayerRoute.createAnimationController] 与
/// `transitionDuration` / `reverseTransitionDuration` 共用此处，避免两处数值漂移。
/// 400ms：配合 [M3ExpressiveMotion.panelExpandEasing] 的长减速尾巴，
/// 位移铺满全程（旧 300ms + expressive 实际前 150ms 就走完了）。
const Duration kPlayerExpandDuration = Duration(milliseconds: 400);

/// 收起（退出）时长：展开的 65%（退出比进入快）。
const Duration kPlayerCollapseDuration = Duration(milliseconds: 260);

/// 播放页容器相对"归位"位置的本帧位移（**页面本地坐标**，dy 向下为正）。
///
/// 两条进入路径的公式不同，集中到一处，避免"路由过渡里算一遍、拖拽覆盖层里
/// 再算一遍"两处漂移（形变层要用它把实测矩形换算成归位矩形）。
///
/// - [dragOrigin] 非空（拖拽模式 / 顶栏下拉）：1:1 跟手，`dy = origin*(1-p)`；
/// - [dragOrigin] 为 null（点击进入）：`dy = 0.15*(1-p)*屏高`。
///
/// 副作用：把结果写入 [PlayerCoverMorphBus.pageOffset]。播放页在 paint 阶段
/// 量到封面矩形时读它，两次取值同帧、相减即可精确抵消（见 [coverMorphSettledRect]）。
///
/// **只服务点击进入这条路径**：拖拽 / 顶栏收起的位移由
/// `player_panel_frame.dart` 的 `playerPanelPageOffset` 写入登记簿，两式必须
/// 同式（`player_panel_geometry_test.dart` 有逐点一致性断言）。
Offset playerPageOffset({
  required double progress,
  required double? dragOrigin,
  required double screenHeight,
}) {
  final offset = dragOrigin != null
      ? Offset(0, dragOrigin * (1 - progress))
      : Offset(0, kPlayerTapEntryOffsetRatio * (1 - progress) * screenHeight);
  PlayerCoverMorphBus.instance.pageOffset = offset;
  return offset;
}

/// 松手判定：距离达标、速度达标、加速度达标三者任一即展开。
/// 加速度取绝对值：快速甩动时起手加速、末端减速，两者都代表强甩动。
///
/// **入参统一为设计像素（dp）及其导数**：[dragDistance] / [velocity] /
/// [acceleration] 与 [screenHeight]（来自 `MediaQuery`）同处
/// `DisplayScaleScope` 的设计像素空间；调用方（MiniPlayer）的 `Listener`
/// 原始指针事件是窗口（根）坐标，必须先经 `toDisplaySpace` 换算再累计，
/// 否则非 1.0 档下距离/速度会偏 s 倍、与阈值坐标系不一致。
///
/// 回拉判定优先：松手瞬间手指仍在向下运动（velocity < -阈值）时，说明用户在
/// 上滑后又往回拉（加速度向下）。此时即使累计上滑距离超过 20%，也不展开——
/// 避免「滑上去又拉回来却仍进入 FullPlayer」的误触发。
/// 不能用加速度符号代替：向上甩动末端的减速也是负加速度，只有速度符号才能
/// 区分「末端减速的甩动」与「向下回拉」。
bool shouldExpandPlayer({
  required double dragDistance, // 向上累计距离 px（≥0）
  required double screenHeight,
  required double velocity, // 向上为正 px/s
  required double acceleration, // 向上为正 px/s²（允许为负，末端减速）
}) {
  if (velocity < -kPlayerPullBackVelocityThreshold) return false;
  return dragDistance >= screenHeight * kPlayerExpandDistanceRatio ||
      velocity > kPlayerFlingVelocityThreshold ||
      acceleration.abs() > kPlayerAccelerationThreshold;
}

/// 当前栈顶的播放器路由（拖拽复用 / 防重复 push）。
DraggablePlayerRoute? activePlayerRoute;

/// 拖拽展开进行中标志（控制页面内跟手覆盖层显示）。
/// 覆盖层位于 Navigator 之上，拖拽期间跟随手指显示 FullPlayer 预览；
/// 松手展开时隐藏覆盖层并由路由接管显示。
final ValueNotifier<bool> playerDragActive = ValueNotifier<bool>(false);

/// 拖拽起点：MiniPlayer 顶端全局 Y 坐标（= FullPlayer 展开起点）。
///
/// 状态本体在 [PlayerPanelSignal]（core/layout），见该类的说明。
double get playerDragOriginTop => PlayerPanelSignal.anchorTop;
set playerDragOriginTop(double value) => PlayerPanelSignal.anchorTop = value;

/// 迷你条底端全局 Y 坐标（设计像素）。双向展开面板用它反解条高，
/// 从而让面板在 p=0 时**恰好**等于迷你条矩形。
///
/// 与 [playerDragOriginTop] **必须成对写**（走 [publishPlayerDragOrigin]）：
/// 分两次量会在切歌 / 转屏瞬间对不上，面板起点抖一下。
double get playerDragOriginBottom => PlayerPanelSignal.anchorBottom;
set playerDragOriginBottom(double value) =>
    PlayerPanelSignal.anchorBottom = value;

/// 锚点未登记（`origin == 0`，理论上不可达的退化路径）时兜底的条高（dp）。
const double kPlayerFallbackMiniBarHeight = PlayerPanelSignal.fallbackBarHeight;

/// 登记迷你条锚点（顶端 + 底端，成对写）。
void publishPlayerDragOrigin({required double top, required double bottom}) =>
    PlayerPanelSignal.publishAnchor(top: top, bottom: bottom);

/// 迷你条高度（设计像素）= 底端 − 顶端；锚点未登记时回落到经验值。
double playerMiniBarHeight() {
  final h = playerDragOriginBottom - playerDragOriginTop;
  return h > 0 ? h : kPlayerFallbackMiniBarHeight;
}

/// 播放页当前选中的 tab 下标（由播放页实例写入，拖拽覆盖层据此从同一 tab 打开）。
///
/// **为什么必须是全局信号，不能让每个实例自己读 `_tabController.index`**：
/// 拖拽 / 收起的跟手过程显示的是 `PlayerDragOverlay` 里的**另一个** FullPlayer
/// 实例，它的 `TabController` 每次都在 `initState` 里从封面 tab（`initialIndex: 1`）
/// 重新开始，与路由里那个实例的真实下标无关。后果有两个：
/// 1. 下拉时覆盖层会把界面**跳回封面 tab**（用户明明停在歌词 / 评论页）；
/// 2. 形变资格读各自 controller 时，覆盖层这一侧永远判定「封面可见」，
///    于是竖屏在非封面 tab 下拉收起时依然会飞出封面和歌名。
/// 让覆盖层从这个信号取初始下标，两个问题一起消掉。
final ValueNotifier<int> playerTabIndex = ValueNotifier<int>(1);

/// 兼容旧引用：返回 true 表示当前 FullPlayer 在栈顶。
/// 新代码应直接监听 [playerExpansion]。
bool get isFullPlayerOnTop => playerExpansion.value > 0.5;

/// 打开 FullPlayer（**统一防重复入栈**，新代码一律走这里）。
///
/// 此前各调用点各自判重且口径不一：多数用 `activePlayerRoute?.isCurrent == true`
/// ——播放页已在栈中但**非栈顶**时（用户从播放页又打开了歌单/其他页面）
/// `isCurrent=false`，仍会再 push 一个播放页；另有调用点完全不判重。结果是
/// 路由栈里同时存在多个 [AmStyleFullPlayer] 实例，每个实例各自驱动歌词 /
/// 进度等动画，整页帧率翻倍（120Hz 屏实测 ~120fps 且明显发热）。
///
/// 统一语义：
/// - 播放页已在栈顶 → 什么都不做（正常情况）
/// - 播放页在栈中但被其它页面盖住 → 回退到它（不再新建）
/// - 不存在 → push 新路由
///
/// [scene] 是调用方（入口控件）在点击那一刻采集的形态快照，随路由透传 ——
/// 悬浮胶囊这类"自己不写全局锚点"的入口必须带上它，否则展开起点只能落到
/// 全局锚点或合成兜底上（见 [PlayerMorphScene] 与 [DraggablePlayerRoute.panelAnchorFor]）。
void openFullPlayer(BuildContext context, {PlayerMorphScene? scene}) {
  // 车机模式：播放器已常驻在面板里，任何「打开全屏播放页」的入口都忽略。
  // 否则会在面板之外再 push 一个播放页 —— 两个实例各自驱动歌词/进度等动画，
  // 整页帧率翻倍。
  // active 含自动检测：命中车机屏同样忽略。
  if (context.read<CarModeProvider>().active) return;

  // rootNavigator: true —— 桌面布局下内容区是嵌套 Navigator，若走最近的
  // Navigator 会把完整播放页 push 进中央内容区（只盖住内容区、盖不住侧栏与
  // 底部播放栏）。改用根 Navigator 让播放页覆盖整个 shell。手机布局下根
  // Navigator 即唯一 Navigator，行为不变。
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
  final DraggablePlayerRoute? existing = activePlayerRoute;
  if (existing != null) {
    if (existing.isActive && !existing.isCurrent) {
      navigator.popUntil((Route<dynamic> route) => identical(route, existing));
    }
    return;
  }
  navigator.push(fullPlayerRoute(context, scene: scene));
}

/// 创建并返回可拖拽的 FullPlayer 路由。
///
/// 调用方可在拖拽手势 start 时调用并 push，然后通过 `route.controller`
/// 在拖动期间手动设置进度，释放时调用 [DraggablePlayerRoute.settleToFull] /
/// [DraggablePlayerRoute.dismiss]。
///
/// [dragOriginTop]/[screenHeight] 由 MiniPlayer 上滑拖拽传入（拖拽模式）：
/// - 拖拽模式：展开面板在 p=0 时恰好等于迷你条矩形（顶端 [dragOriginTop]、
///   高度 [dragOriginBottom]-[dragOriginTop]），上沿随手指 1:1 上移、
///   下沿同时向下扫过导航栏，直到 p=1 铺满全屏；
/// - 不传（点击打开）：保持原有淡入 + 15% 上滑动画。
///
/// [scene] 是点击 / 拖拽那一刻采集的**形态快照**（见 [PlayerMorphScene]）。
/// 二级悬浮胶囊这类"自己不写全局锚点"的入口必须走它，否则起点几何只能落到
/// 全局锚点或合成兜底上，与用户实际点的控件对不上。
DraggablePlayerRoute<void> fullPlayerRoute(
  BuildContext context, {
  PlayerMorphScene? scene,
  double? dragOriginTop,
  double? screenHeight,
  double? dragOriginBottom,
}) {
  final useAm = context.read<ThemeProvider>().useAmStylePlayer;
  return DraggablePlayerRoute<void>(
    builder: (_) => useAm ? const AmStyleFullPlayer() : const FullPlayer(),
    scene: scene,
    dragOriginTop: dragOriginTop,
    screenHeight: screenHeight,
    dragOriginBottom: dragOriginBottom,
  );
}

/// 播放器系统栏作用域。
///
/// 拖拽展开模式下，系统栏样式跟随展开进度切换：完全展开前保持主页面样式
/// （[mainPageOverlayStyle]），完全展开后切换为播放器样式（[kPlayerOverlayStyle]），
/// 避免拖拽过程中系统栏提前变成透明 + 浅色图标造成闪烁。
/// 非拖拽模式（[dragRoute] 为 null）恒为播放器样式。
/// [forceMainStyle]：拖拽覆盖层（非路由渲染的 FullPlayer）期间恒为主页面样式。
class PlayerSystemUiScope extends StatelessWidget {
  const PlayerSystemUiScope({
    super.key,
    required this.dragRoute,
    this.forceMainStyle = false,
    this.expandedOverlayStyle,
    required this.child,
  });

  /// 拖拽展开模式下的源路由；非拖拽模式为 null。
  final DraggablePlayerRoute? dragRoute;

  /// 覆盖层渲染场景（非路由）：拖拽期间系统栏保持主页面样式。
  final bool forceMainStyle;

  /// 完全展开后的系统栏样式；null 时用 [kPlayerOverlayStyle]（固定浅色）。
  /// md 播放器按主题亮度传入（浅色主题黑字 / 深色主题白字），AM 保持默认。
  final SystemUiOverlayStyle? expandedOverlayStyle;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation:
          dragRoute?.controller ?? const AlwaysStoppedAnimation<double>(1.0),
      builder: (context, _) {
        final expanded =
            dragRoute == null || dragRoute!.controller.value >= 1.0;
        final useMain = forceMainStyle || (dragRoute != null && !expanded);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: useMain
              ? mainPageOverlayStyle(context)
              : (expandedOverlayStyle ?? kPlayerOverlayStyle),
          child: child,
        );
      },
    );
  }
}

/// 可拖拽的 FullPlayer 路由。
///
/// 设计要点：
/// - [opaque] = false：路由背景透明，下层 MiniPlayer 可见，实现交叉淡入淡出
/// - 拖拽模式（[dragOriginTop] 非空）：顶端与 MiniPlayer 对齐、1:1 跟手上移、
///   透明度在前 20% 屏高内 0→1；松手后 [settleToFull]（panelExpandEasing，
///   时长按剩余行程等比缩放）完整展开或 [dismiss] 收起
/// - [controller] 暴露给外部手势：拖动期间 `controller.stop()` + `controller.value = x`，
///   释放时调用 [settleToFull] / [dismiss]
class DraggablePlayerRoute<T> extends PageRoute<T> {
  DraggablePlayerRoute({
    required this.builder,
    this.scene,
    this.dragOriginTop,
    this.screenHeight,
    this.dragOriginBottom,
  });

  final WidgetBuilder builder;

  /// 进栈那一刻的底部形态快照（含展开起点矩形），见 [PlayerMorphScene]。
  ///
  /// 有值时**优先于**一切全局锚点：它由入口自己采集，不存在"读到别的形态
  /// 留下的陈旧值"的问题。为 null 时回落到拖拽参数 / 全局锚点 / 合成兜底。
  final PlayerMorphScene? scene;

  /// MiniPlayer 顶端全局 Y 坐标（拖拽模式下非空）。
  final double? dragOriginTop;

  /// MiniPlayer 底端全局 Y 坐标（拖拽模式下非空）。双向展开面板据此在
  /// p=0 时贴合迷你条矩形；为 null 时回落到全局锚点。
  final double? dragOriginBottom;

  /// 拖拽开始时的屏幕高度（拖拽模式下非空）。
  final double? screenHeight;

  /// 本次转场的底部锚点（顶端 + 高度，设计像素）。
  ///
  /// [screenHeight] 取**当下**的屏高（拖拽模式可用手势开始时的快照兜底），
  /// 以便锚点未知时能合成一条贴底的兜底窗口。
  ///
  /// 锚点来源优先级：
  /// 1. [scene]（且其矩形有高度）：入口自己采集的形态快照，最可信；
  /// 2. 拖拽参数 [dragOriginTop]/[dragOriginBottom]（上滑展开时由 MiniPlayer
  ///    传入的实测值）；
  /// 3. 全局锚点 `playerDragOriginTop > 0`（点击进入时 `MiniPlayer` 刚登记的
  ///    测量值）；
  /// 4. 兜底：合成一条**胶囊几何**的贴底条 —— 底端 = 屏底、高 =
  ///    [BottomChromeDimens.discReservedBottom]。
  ///
  /// 第 4 条覆盖「从歌单卡片、个人 FM 等处直接进播放页、这次会话还没碰过
  /// 迷你条」的场景：那类入口拿不到测量值，但**仍然走面板路径**（用户要求
  /// 非拖拽进出也一致）。合成起点完全透明（面板 p=0 时 opacity=0），所以
  /// 起点估得不准在观感上不可见。
  ///
  /// **兜底为什么合成胶囊几何而不是桌面播放栏高**：合成值只在移动端布局下
  /// 被用到，而移动端根本没有"桌面播放栏"这条 bar；用桌面栏高（旧
  /// `kPlayerFallbackMiniBarHeight` = 72）冒充会把起点算成一条与实际控件
  /// 无关的高度。胶囊是移动端贴底的悬浮形态，其几何口径与常驻条一致
  /// （底端到屏底），故取它作为兜底。
  ({double top, double height}) panelAnchorFor(double screenHeight) {
    final s = scene;
    if (s != null && s.panelRect.height > 0) {
      return (top: s.panelTop, height: s.panelHeight);
    }
    final top = dragOriginTop ?? playerDragOriginTop;
    if (top > 0) {
      final bottom = dragOriginBottom ?? playerDragOriginBottom;
      final h = bottom - top;
      return (
        top: top,
        height: h > 0 ? h : BottomChromeDimens.discReservedBottom,
      );
    }
    return (
      top: math.max(0, screenHeight - BottomChromeDimens.discReservedBottom),
      height: BottomChromeDimens.discReservedBottom,
    );
  }

  /// 是否为拖拽模式（MiniPlayer 上滑展开）。
  bool get isDragMode => dragOriginTop != null && screenHeight != null;

  /// 顶栏向下拖拽收起时的完整收起距离（px）。
  /// 非空表示顶栏拖拽激活中（含 tap 模式点击进入的播放页）：
  /// 播放页跟随手指沿「展开路径」原路下滑（dy = total*(1-pos)）。
  /// 拖拽结束/取消时由调用方置回 null，恢复原有动画映射。
  double? topBarDragTotal;

  /// 顶栏拖拽是否激活中（松手动画期间保持 true）。
  /// 用于防竞态：松手动画（settleToFull）完成时若用户已重新开始拖拽
  /// （whenCompleteOrCancel 异步回调晚于 start 重新赋值），不得清空映射。
  bool topBarDragging = false;

  /// 由 [createAnimationController] 赋值，外部手势可读取此字段直接驱动。
  /// 重写父类（[TransitionRoute]）的同名 getter（返回 `AnimationController?`），
  /// 收窄为非空类型，便于调用方直接使用而无需 null-check。
  @override
  late AnimationController controller;

  /// 是否正在执行 dismiss 流程（reverse 动画 + removeRoute），
  /// 防止手势/按钮重复触发。
  bool _isDismissing = false;

  /// 松手动画起点（controller.value 快照），用于归一化缓动、保证动画起点连续。
  double _animStartValue = 0.0;

  /// 松手动画方向：1 = 展开（forward），-1 = 收起（reverse）。
  int _animDirection = 1;

  /// 收起播放器：播放 reverse 动画，完成后移除路由。
  /// 供 FullPlayer 内部的按钮/手势调用。
  void dismiss() {
    if (_isDismissing) return;
    _isDismissing = true;
    _animStartValue = controller.value;
    _animDirection = -1;
    controller.reverse().then((_) {
      // 强制归零，避免 removeRoute 不触发 didPop 导致 playerExpansion 残留非零值
      // （didPop 只在系统 pop 时触发，dismiss 走 removeRoute 不触发）
      if (playerExpansion.value != 0.0) {
        playerExpansion.value = 0.0;
      }
      if (navigator?.mounted ?? false) {
        navigator!.removeRoute(this);
      }
    });
  }

  /// 收起别名：与 [dismiss] 相同，供 MiniPlayer 拖拽松手未达阈值时调用。
  void collapse() => dismiss();

  /// 松手后完整展开：从当前进度续播 panelExpandEasing 前向动画
  /// （时长按剩余行程等比缩放，见 AnimationController.forward）。
  void settleToFull() {
    if (_isDismissing) return;
    _animStartValue = controller.value;
    _animDirection = 1;
    controller.forward().whenCompleteOrCancel(() {
      // 松手动画结束（或被新的拖拽取消）时，若没有新拖拽激活则恢复原映射；
      // 若用户在动画期间重新开始拖拽（topBarDragging=true，回调晚于 start
      // 重新赋值 topBarDragTotal），则保留映射交给新拖拽管理
      if (!topBarDragging) {
        topBarDragTotal = null;
      }
    });
  }

  /// 拖拽接管已存在的路由（半途回拖场景）：
  /// 取消进行中的 dismiss、停止当前动画并从 0 重新开始。
  void beginDrag() {
    _isDismissing = false;
    topBarDragging = false;
    controller.stop();
    controller.value = 0.0;
  }

  /// Flutter 3.44 起 [TransitionRoute.createAnimationController] 不再接收
  /// `vsync` 参数——框架内部直接使用 `navigator!` 作为 TickerProvider。
  /// 我们在此重写仅是为了定制 `duration` / `reverseDuration`，并把创建的
  /// 控制器赋值到 [controller]，供外部手势读取。
  @override
  AnimationController createAnimationController() {
    controller = AnimationController(
      vsync: navigator!,
      duration: kPlayerExpandDuration,
      reverseDuration: kPlayerCollapseDuration,
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    return controller;
  }

  @override
  TickerFuture didPush() {
    if (isDragMode) {
      // 拖拽模式：完全由手势接管，跳过 super.didPush() 触发的自动入场动画
      // （forward 会与后续手势驱动/展开动画冲突，导致动画瞬跳、界面闪切）
      activePlayerRoute = this;
      controller.stop();
      controller.value = 0.0;
      return TickerFuture.complete();
    }
    final future = super.didPush();
    activePlayerRoute = this;
    return future;
  }

  @override
  void dispose() {
    if (identical(activePlayerRoute, this)) {
      activePlayerRoute = null;
      // 播放器关闭 → 信号复位。
      //
      // [playerExpansion]：归零在这里收口。收起动画期间它由动画进度逐帧驱动
      // （见 [buildTransitions]），[didPop] 不再硬跳；系统返回走 removeRoute
      // 不经过 [dismiss] 的完成回调，只有这里能兜住残留的非零值。
      // [playerTabIndex]：下一次从迷你条上拉展开时路由里并没有实例，若不复位就会
      // 沿用上一程残留的下标，覆盖层显示歌词页、路由接管后又开在封面页，末尾硬跳。
      // [playerCoverVisible]：没有播放页时「封面是否可见」这个约束不成立，
      // 必须回到 true —— 否则收起后残留的 false 会让下一次展开也不做形变。
      if (playerExpansion.value != 0.0) {
        playerExpansion.value = 0.0;
      }
      playerTabIndex.value = 1;
      playerCoverVisible.value = true;
    }
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  /// 动画播放期间（forward/reverse）归一化套用缓动：
  /// 以动画起点 [_animStartValue] 为基准，把「起点 → 目标值」的剩余区间
  /// 归一化后套用曲线，保证动画起点与拖拽终点连续、不跳变。
  ///
  /// 两个方向都是**落位**：展开落全屏、收起落回迷你条（p=0 时封面/文字由
  /// 形变层交接回两端真实组件），所以末端速度必须趋零——旧组合（进入
  /// expressive 前置冲刺 + 离场 emphasized-accelerate 末端 4 倍均速突进）
  /// 在叠加封面/文字形变后两端都呈现掉帧感。panelExpand（迟起、中段快、
  /// 软着陆）与 panelCollapse（轻推、全程平滑、软着陆，起步斜率 ~0.67
  /// 贴合下拉初速）把位移铺满全程。
  ///
  /// tap 模式与拖拽松手共用本函数；跟手阶段（controller 未在动画中）直接
  /// 透传 raw，1:1 线性不受影响。
  double _easedPosition(double raw) {
    final start = _animStartValue.clamp(0.0, 1.0);
    if (_animDirection > 0) {
      // 展开：raw 从 start → 1
      if (start >= 1.0) return raw;
      final t = ((raw - start) / (1.0 - start)).clamp(0.0, 1.0);
      return start +
          (1.0 - start) * M3ExpressiveMotion.panelExpandEasing.transform(t);
    }
    // 收起：raw 从 start → 0
    if (start <= 0.0) return raw;
    final t = ((start - raw) / start).clamp(0.0, 1.0);
    return start * (1.0 - M3ExpressiveMotion.panelCollapseEasing.transform(t));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 系统「减弱动态效果」：动画播放期间不再过渡位移与淡入斜坡，直接落到本次动画的
    // 目标端点（playerExpansion 仍被写成端点值，迷你条不会停在半透明）。
    // 松手前的 1:1 跟手拖拽属于用户直接操纵，不在此列，保持原样。
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        // 顶栏向下拖拽激活中（含 tap 模式点击进入的播放页）时，与拖拽模式一样
        // 直接用 controller.value：路由 push 后首帧 animation（框架 proxy）尚未
        // 与 controller 同步（会短暂为 1.0），用 controller 可避免首帧误显示全屏
        final topBarDrag = topBarDragTotal != null;
        final raw =
            (isDragMode || topBarDrag ? controller.value : animation.value)
                .clamp(0.0, 1.0);
        final animating = controller.isAnimating;
        // 减弱动画时本次动画的目标端点：settleToFull → 1，dismiss / didPop → 0
        final snappedTarget = _animDirection > 0 ? 1.0 : 0.0;

        // —— 双向展开面板（**全部进出路径**：上滑展开 / 松手续展 / 顶栏下拉收起 /
        //   点击进入 / 按钮收起 / 系统返回）——
        // 位置与透明度各自独立映射：
        // 位置：播放页仍是**整屏尺寸**，只按 dy = origin*(1-pos) 整体下移，
        //   再由 PlayerPanelFrame 裁剪到 [origin*(1-pos), +面板高] 的窗口里 ——
        //   pos=0 时窗口恰好等于迷你条矩形（导航栏完整可见），pos=1 铺满全屏；
        //   origin = 拖拽模式的 MiniPlayer 顶端；顶栏拖拽（含点击进入的播放页）
        //   用 topBarDragTotal，实现点击进入也能原路返回
        // 透明度：前 20% 屏高线性 0→1，之后保持 1
        //
        // 为什么裁剪而不是压扁播放页：压扁会让它逐帧重新布局（歌词/封面/控件
        // 全部 reflow），且封面形变层那套「减去 pageOffset 换算归位矩形」的
        // 前提（页面只做平移）也不再成立。见 player_panel_frame.dart 的说明。
        //
        // **点击进入也走这里**（原先是「淡入 + 15% 抽屉上滑」）：用户要求非拖拽
        // 进出与拖拽观感一致。锚点未知时由 [panelAnchorFor] 合成一条贴底的起点，
        // 起点 opacity=0 所以估不准不可见。
        final height = screenHeight ?? MediaQuery.sizeOf(context).height;
        if (height > 0) {
          final anchor = panelAnchorFor(height);
          final origin = topBarDragTotal ?? anchor.top;
          final pos = animating
              ? (reduceMotion ? snappedTarget : _easedPosition(raw))
              : raw;
          if (pos != playerExpansion.value) {
            // 让出当前 build 帧：build 阶段直接改 ValueNotifier 会触发
            // 监听者 setState() during build（_dependents/descendant 断言）。
            scheduleMicrotask(() {
              playerExpansion.value = pos;
            });
          }
          // 注意：**不要**在这里再包一层 Opacity。面板的不透明性由 PlayerPanelFrame
          // 内部的底色层保证，淡入只作用于页面内容（见该文件的结构说明）；
          // 把 Opacity 提到外面会把底色一起乘上透明度，过渡态照样透出背后内容。
          //
          // `pageOffset`（形变登记簿）由 PlayerPanelFrame 内部的
          // playerPanelPageOffset 写入，与本文件 playerPageOffset 同式（有单测）。
          return PlayerPanelFrame(
            progress: pos,
            origin: origin,
            // 条高只影响下沿起点；窗口顶边由 [origin] 决定。
            miniHeight: anchor.height,
            child: child,
          );
        }

        // —— 退化兜底：屏高为 0（理论不可达的视口）——
        // 此时面板几何除零，直接走「淡入 + 15% 抽屉上滑」，不做裁剪。
        // 位移、淡入淡出与 playerExpansion（形变层 / 迷你条 / 封面槽位）共用同一条
        // 进度：拆成两条长跑曲线会让飞行中的封面与它自己的槽位脱节。
        final progress = animating
            ? (reduceMotion ? snappedTarget : _easedPosition(raw))
            : raw;
        // 同步到全局 playerExpansion，让 MiniPlayer 同步淡入淡出。
        // 改为微任务调度：避开 build 阶段直接写 ValueNotifier 触发监听者
        // setState() during build 断言。
        if (progress != playerExpansion.value) {
          scheduleMicrotask(() {
            playerExpansion.value = progress;
          });
        }
        // 淡入：progress 0→1 时 opacity 0→1
        // 滑动：progress 0→1 时从 15% 屏幕高度下方位移滑到 0（抽屉上滑感）
        //
        // [playerPageOffset] 登记的是页面本地**像素**位移，而
        // [FractionalTranslation] 收的是**比例**；除以屏高换算回去。
        // 二者恒等：0.15*(1-progress)*h / h ≡ 0.15*(1-progress)，
        // 与原 Tween(begin: Offset(0, 0.15), end: Offset.zero) 完全一致。
        final dy = playerPageOffset(
          progress: progress,
          dragOrigin: null,
          screenHeight: height,
        ).dy;
        return Opacity(
          // 与写进 [playerExpansion] 的那条同源：形变层的绘制窗口是 0<p<1，
          // 若这里比它快，页面已不透明而封面还在半途，看起来就是「封面脱离它
          // 自己的槽位在飞」。
          opacity: progress,
          child: FractionalTranslation(
            translation: Offset(0, dy / height),
            child: child,
          ),
        );
      },
    );
  }

  // PageRoute 必需重写项
  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => kPlayerExpandDuration;

  @override
  Duration get reverseTransitionDuration => kPlayerCollapseDuration;

  @override
  bool didPop(T? result) {
    // 系统返回（手势 / 物理键）：只登记收起方向与起点，交由 buildTransitions 在
    // 收起动画期间逐帧把 playerExpansion 写回（1 → 0）。
    // 此前在这里同步置 0：下一帧的进度回写又把它拉回接近 1，迷你条出现「全亮帧」
    // 闪烁；同时形变层的端点判据（p<=0 不绘制）被触发，共享元素交接整段被跳过。
    // 归零收口在 [dispose]。
    _animStartValue = controller.value;
    _animDirection = -1;
    return super.didPop(result);
  }
}
