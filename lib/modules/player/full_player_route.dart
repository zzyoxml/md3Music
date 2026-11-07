import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
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

/// 上拉未达阈值时的**回弹**时长。
///
/// 旧实现在松手那一刻直接把 `playerExpansion` 归零：面板/覆盖层下一帧就消失，
/// 用户看到的是「拉到一半，啪一下没了」。改成 220ms 的一次性回弹（与悬浮条
/// 圆盘吸附同一档时长）后，手势与结果之间才有因果感。
///
/// 只用于「用户直接操纵被拒绝」这一种收尾：系统打断（PointerCancel）仍瞬时归零，
/// 因为那时用户没有期待任何动画。
const Duration kPlayerDragCancelDuration = Duration(milliseconds: 220);

/// 拖拽松手后「把跟手覆盖层交接给路由」的共享实现（常驻条 / 悬浮胶囊共用）。
///
/// 交接要点（避免松手闪烁）：
/// 1. 先 `push` 路由并**停在当前进度**（不立即动画）—— push 会重建覆盖层之上的
///    一帧，此时路由尚未与 controller 同步，若直接 `settleToFull()` 会从 0 起播、
///    出现「松手瞬间弹回迷你条再展开」；
/// 2. 等**两个** post-frame：第 1 帧路由完成首建（此时它的 `buildTransitions`
///    已按 `controller.value` 画出与覆盖层同形的面板），第 2 帧覆盖层让位、
///    路由接管显示；
/// 3. 让位与续播必须在同一帧完成：先隐藏覆盖层再 forward，两者形状在那一帧
///    逐像素相同，交接不可见；
/// 4. 等待期间路由可能已被移除（用户按返回 / 页面被销毁）—— 用 [route.isActive]
///    兜住，否则会对已 dispose 的 controller 调 `forward()` 抛状态错误。
///
/// [onOverlayRelease] 由调用方决定怎么隐藏自己的跟手覆盖层（常驻条与悬浮条
/// 各自持有一个 `playerDragActive` / 回弹控制器）。
void handOffDragToRoute({
  required NavigatorState navigator,
  required DraggablePlayerRoute<void> route,
  required double progress,
  required VoidCallback onOverlayRelease,
}) {
  navigator.push(route);
  route.controller.stop();
  route.controller.value = progress.clamp(0.0, 1.0); // 路由从当前手指位置开始显示
  var frames = 0;
  void tick() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!route.isActive) {
        // 路由在等待期就被移除了：至少把覆盖层收掉，别留一块幽灵面板。
        onOverlayRelease();
        return;
      }
      frames++;
      if (frames >= 2) {
        onOverlayRelease();
        route.settleToFull();
      } else {
        tick();
      }
    });
  }

  tick();
}

/// 「上拉未达阈值 → 回弹归零」的一次性动画驱动（常驻条 / 悬浮胶囊共用）。
///
/// **为什么抽成类而不是各处手搓 `AnimationController`**：两个入口的收尾语义必须
/// 完全一致（时长、曲线、把 `playerExpansion` 逐帧写回、结束时置回
/// `playerDragActive=false`），否则「从常驻条拉」和「从胶囊拉」会是两种手感。
///
/// 生命周期：调用方持有（`initState` 建、`dispose` 释放）；[settleBack] 可重复
/// 调用（会先 `stop()` 再从新起点重播），[stop] 用于用户重新接管手势。
///
/// 系统「移除动画」下直接落端点（不播补间）——与其余转场同一套降级口径。
class DragReleaseAnimator {
  DragReleaseAnimator(TickerProvider vsync)
    : _controller = AnimationController(
        vsync: vsync,
        duration: kPlayerDragCancelDuration,
      );

  final AnimationController _controller;
  Animation<double>? _animation;
  VoidCallback? _onDone;

  /// 是否正在回弹（调用方据此决定要不要把新手指事件当作「接管」）。
  bool get isRunning => _controller.isAnimating;

  /// 把 [playerExpansion] 从当前值动画回 0，结束后回调 [onDone]。
  void settleBack({
    required bool reduceMotion,
    VoidCallback? onDone,
  }) {
    final double start = playerExpansion.value;
    _onDone = onDone;
    _controller.stop();
    if (start <= 0.0) {
      playerExpansion.value = 0.0;
      _finish();
      return;
    }
    if (reduceMotion) {
      playerExpansion.value = 0.0;
      _finish();
      return;
    }
    _animation = Tween<double>(begin: start, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: M3ExpressiveMotion.panelCollapseEasing,
      ),
    )..addListener(() {
        playerExpansion.value = _animation!.value;
      });
    _controller.forward(from: 0.0).whenCompleteOrCancel(_finish);
  }

  void _finish() {
    playerExpansion.value = 0.0;
    final done = _onDone;
    _onDone = null;
    done?.call();
  }

  /// 中止回弹（用户重新按住 / 页面销毁）。不触发 `onDone`。
  void stop() {
    _onDone = null;
    _controller.stop();
  }

  void dispose() {
    _onDone = null;
    _controller.dispose();
  }
}

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

/// 迷你条**左缘** X（设计像素）。`<= 0` / 未登记 = 通栏（常驻条口径）。
double get playerDragOriginLeft => PlayerPanelSignal.anchorLeft;
set playerDragOriginLeft(double value) => PlayerPanelSignal.anchorLeft = value;

/// 迷你条**宽度**（设计像素）。`<= 0` / 未登记 = 通栏（回退整屏宽）。
double get playerDragOriginWidth => PlayerPanelSignal.anchorWidth;
set playerDragOriginWidth(double value) => PlayerPanelSignal.anchorWidth = value;

/// 迷你条**外轮廓圆角**（dp）：胶囊 / 圆盘 32，常驻条 0。
double get playerDragOriginRadius => PlayerPanelSignal.anchorRadius;
set playerDragOriginRadius(double value) => PlayerPanelSignal.anchorRadius = value;

/// 锚点未登记（`origin == 0`，理论上不可达的退化路径）时兜底的条高（dp）。
const double kPlayerFallbackMiniBarHeight = PlayerPanelSignal.fallbackBarHeight;

/// 登记迷你条锚点（顶端 + 底端 + 横向范围 + 外轮廓圆角，**成组写**）。
///
/// [left]/[width]/[radius] 默认值即常驻条口径（通栏、方角），所以常驻条那几处
/// 两参调用点无需改动；但每次都会**全量写入**，胶囊登记的窄矩形/32 圆角不会
/// 泄漏给下一次常驻条拖拽。
void publishPlayerDragOrigin({
  required double top,
  required double bottom,
  double left = 0.0,
  double width = 0.0,
  double radius = 0.0,
}) => PlayerPanelSignal.publishAnchor(
  top: top,
  bottom: bottom,
  left: left,
  width: width,
  radius: radius,
);

/// 已登记锚点对应的**屏幕矩形**（设计像素）。
///
/// [screenSize] 用于把「未登记横向范围」补成通栏，并把矩形钳进屏内。
/// 高度为 0 时回落到经验条高（[kPlayerFallbackMiniBarHeight]），保证消费端永远
/// 拿得到一个有面积的矩形。
Rect playerPanelAnchorRect(Size screenSize) {
  final double w = screenSize.width.isFinite && screenSize.width > 0
      ? screenSize.width
      : 0.0;
  final double h = screenSize.height.isFinite && screenSize.height > 0
      ? screenSize.height
      : 0.0;
  final double top = playerDragOriginTop > 0
      ? playerDragOriginTop.clamp(0.0, h)
      : math.max(0.0, h - kPlayerFallbackMiniBarHeight);
  final double bottom = (playerDragOriginBottom - playerDragOriginTop) > 0
      ? playerDragOriginBottom.clamp(top, h)
      : math.min(h, top + kPlayerFallbackMiniBarHeight);
  final double width = playerDragOriginWidth > 0
      ? playerDragOriginWidth.clamp(0.0, w)
      : w;
  final double left = playerDragOriginWidth > 0
      ? playerDragOriginLeft.clamp(0.0, math.max(0.0, w - width))
      : 0.0;
  return Rect.fromLTWH(left, top, width, bottom - top);
}

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

/// 播放页在场的**歌词指挥口**，卡片深链专用（v31 起以集合承载全部在场实例）。
///
/// v43（用户拍板二次修正）：车机点媒体卡片改走「AdaptiveNav.pushDetailGlobal
/// 把播放页塞进双栏右窗格」，不再依赖本指挥口直达；守卫恢复但深链经
/// bypassCarGuardOnce 旁路。指挥口保留用于"播放页已开着时原地切歌词"。
///
/// v31：单指针改**注册集合**。覆盖层这类"后注册"的实例若在覆盖后注销，
/// 单指针会以 identical 判属把整根清空，而它先注册的"存活"路由/面板实例
/// 的命令从此静默 no-op（深链又对存量路由不 push——症状借拖拽路径复活）。
/// 集合模式实例死亡只摘自己的注册，存活者继续响应；发送对全部在场实例
/// 广播，各自幂等切页（UI 更新，不创建新实例）。
///
/// 抽象成 `void Function()`（而不是下标）：播放页窄屏结构的实际顺序是
/// [playlist, cover, lyrics, …]（下标 2 恰为歌词），但顺序随宽窄屏与
/// tab 开关动态调整——歌词页下标由在场实例按实时 `_tabLayout` 解析
/// （`lyricsIndex`，见 player_tab_layout），调用方只表达"切歌词"语义，
/// 不写死任何下标。
///
/// 没有在场实例（无路由、无面板）时发送是 **no-op**——不会凭空拉起任何
/// 页面，等下一次卡片点击再试。
typedef void PlayerLyricsCommandHandler();

final Set<PlayerLyricsCommandHandler> _lyricsCommandHandlers =
    <PlayerLyricsCommandHandler>{};

void registerPlayerLyricsCommand(PlayerLyricsCommandHandler handler) =>
    _lyricsCommandHandlers.add(handler);

void unregisterPlayerLyricsCommand(PlayerLyricsCommandHandler handler) =>
    _lyricsCommandHandlers.remove(handler);

void sendDockPlayerLyricsCommand() {
  for (final handler
      in List<PlayerLyricsCommandHandler>.of(_lyricsCommandHandlers)) {
    // v32：单实例异常不阻断后续实例（现状都是 postFrame+pager 空守卫，
    // 实害低，这里固化"注册者不得打进命令语义"的兜底）。
    try {
      handler();
    } catch (_) {}
  }
}

/// 兼容旧引用：返回 true 表示当前 FullPlayer 在栈顶。
/// 新代码应直接监听 [playerExpansion]。
bool get isFullPlayerOnTop => playerExpansion.value > 0.5;

/// 打开 FullPlayer（**统一防重复入栈**，新代码一律走这里）。
///
/// v43：恢复车机忽略守卫（防双实例双动画，v21 实测帧率翻倍+发热），深链经
/// `bypassCarGuardOnce` 旁路一次；v42 的废弃 force 参数已删除（全仓无调用点）。
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
void openFullPlayer(
  BuildContext context, {
  PlayerMorphScene? scene,
  bool bypassCarGuardOnce = false,
}) {
  // MD3Music fork v43：恢复 v21 守卫（车机面板常驻播放器 + 全屏页 = 双实例
  // 双动画，v21 实测帧率翻倍+发热），深链经 bypassCarGuardOnce 旁路一次——
  // 深链优先走 AdaptiveNav.pushDetailGlobal 进双栏右窗格，旁路只是无双栏
  // 场景（手机竖屏车机模式）的兜底。
  if (context.read<CarModeProvider>().active && !bypassCarGuardOnce) return;

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
  return DraggablePlayerRoute<void>(
    lightweightDesktopEntry: context.read<ThemeProvider>().useAmStylePlayer,
    builder: (_) => Consumer<ThemeProvider>(
      builder: (context, theme, _) => theme.useAmStylePlayer
          ? const AmStyleFullPlayer()
          : const FullPlayer(),
    ),
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
///   透明度在前 20% 屏高内 0→1；松手后 [settleToFull]（panelSettleEasing，
///   时长按剩余行程等比缩放）完整展开或 [dismiss] 收起
/// - [controller] 暴露给外部手势：拖动期间 `controller.stop()` + `controller.value = x`，
///   释放时调用 [settleToFull] / [dismiss]
class DraggablePlayerRoute<T> extends PageRoute<T> {
  DraggablePlayerRoute({
    required this.builder,
    this.lightweightDesktopEntry = false,
    this.scene,
    this.dragOriginTop,
    this.screenHeight,
    this.dragOriginBottom,
  });

  final WidgetBuilder builder;

  /// Windows AM 点击入口使用固定布局合成，不参与迷你条到全屏的轮廓形变。
  /// 显式拖拽或顶栏下拉接管时仍走原来的跟手路径。
  final bool lightweightDesktopEntry;
  bool get usesLightweightDesktopEntry => lightweightDesktopEntry &&
      defaultTargetPlatform == TargetPlatform.windows && !isDragMode &&
      topBarDragTotal == null;

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

  /// 本次转场的**起点外轮廓**（矩形 + 圆角），设计像素。
  ///
  /// 这是「悬浮条外轮廓 → 覆盖全屏」形变的几何入口：[PlayerPanelFrame] 用它算
  /// 窗口矩形与四角圆角，`p=0` 时与源形态可见本体逐值相等。
  ///
  /// **纵向一律委托 [panelAnchorFor]**，本函数只补「横向范围 + 圆角」。必须同源
  /// 的原因：底栏下沉量（`bottom_chrome_sink.dart`）与页面位移都按那条纵向映射
  /// 推导，这里若自己再推一遍 top/height，两处会在转屏 / 小窗 resize 途中分叉，
  /// 面板下沿与底栏之间露出空带。
  ///
  /// 横向与圆角的来源与纵向**同优先级**：
  /// - 有 [scene]：快照矩形（可见本体，含左右内缩）+ `scene.panelRadius`；
  /// - 否则：全局锚点的 `anchorLeft/Width/Radius`（胶囊上拉会写；常驻条不写 →
  ///   通栏 + 方角，与引入这两个字段之前逐像素一致）；
  /// - 未登记（width ≤ 0）：按整屏宽铺，等价旧行为。
  ({Rect rect, double radius}) panelGeometryFor(Size screenSize) {
    final double w = screenSize.width.isFinite && screenSize.width > 0
        ? screenSize.width
        : 0.0;
    final double h = screenSize.height.isFinite && screenSize.height > 0
        ? screenSize.height
        : 0.0;
    // 纵向唯一来源：panelAnchorFor（scene / 拖拽参数 / 全局锚点 / 合成兜底），
    // 钳进当前屏后取回。
    final anchor = panelAnchorFor(h);
    final double top = anchor.top.clamp(0.0, h);
    final double bottom = (top + anchor.height).clamp(top, h);

    final s = scene;
    if (s != null && s.panelRect.height > 0) {
      final r = s.panelRect;
      // 快照的横向可能来自**旧视口**（转屏途中）：钳进当前屏。
      final double left = r.left.isFinite ? r.left.clamp(0.0, w) : 0.0;
      final double right = r.right.isFinite ? r.right.clamp(left, w) : w;
      return (
        rect: Rect.fromLTRB(left, top, right, bottom),
        radius: s.panelRadius,
      );
    }
    final double width = playerDragOriginWidth > 0
        ? playerDragOriginWidth.clamp(0.0, w)
        : w;
    final double left = playerDragOriginWidth > 0
        ? playerDragOriginLeft.clamp(0.0, math.max(0.0, w - width))
        : 0.0;
    return (
      rect: Rect.fromLTWH(left, top, width, bottom - top),
      radius: playerDragOriginRadius,
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

  /// 松手后完整展开：从当前进度续播 panelSettleEasing 前向动画
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
      duration: transitionDuration,
      reverseDuration: reverseTransitionDuration,
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
      PlayerCoverMorphBus.instance.simplePageTransition = false;
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
  /// 在叠加封面/文字形变后两端都呈现掉帧感。
  ///
  /// **展开按「起点是不是手指」分两条曲线**（只此一条分叉，别继续加）：
  /// - 起点 = 0（点击进入：`didPush` 起播，[_animStartValue] 保持字段初值 0）
  ///   → [M3ExpressiveMotion.panelExpandEasing]，对称 S 型（起步慢、中段最快、
  ///   末端慢着陆）。这是用户能看清整段位移的唯一入口，慢起步才读得出「非线性」；
  /// - 起点 > 0（拖拽松手续展 [settleToFull] / 顶栏下拉后弹回全屏）
  ///   → [M3ExpressiveMotion.panelSettleEasing]，形状与旧版展开曲线**逐值相同**。
  ///   原因：这一段前面是 1:1 跟手，画面此刻的速度是**手指的速度**；换成慢起步
  ///   等于「手指一停画面先刹一停」，观感是顿挫而不是优雅。位移已完成的行程
  ///   不重走（归一化保证），只把剩余行程送到底。
  ///
  /// 收起侧不分叉：拖拽收起与系统返回都从全屏附近起，[panelCollapseEasing]
  /// 的轻推起步（斜率 ~0.67）本就贴合下拉初速。
  ///
  /// tap 模式与拖拽松手共用本函数；跟手阶段（controller 未在动画中）直接
  /// 透传 raw，1:1 线性不受影响。
  double _easedPosition(double raw) {
    final start = _animStartValue.clamp(0.0, 1.0);
    if (_animDirection > 0) {
      // 展开：raw 从 start → 1
      if (start >= 1.0) return raw;
      final curve = start == 0.0
          ? M3ExpressiveMotion.panelExpandEasing
          : M3ExpressiveMotion.panelSettleEasing;
      final t = ((raw - start) / (1.0 - start)).clamp(0.0, 1.0);
      return start + (1.0 - start) * curve.transform(t);
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
    final simpleEntry = usesLightweightDesktopEntry;
    PlayerCoverMorphBus.instance.simplePageTransition = simpleEntry;
    if (simpleEntry) {
      // 页面只布局一次，逐帧仅合成平移/透明度，不再改变整屏裁剪轮廓。
      return AnimatedBuilder(
        animation: animation,
        child: RepaintBoundary(child: child),
        builder: (context, content) {
          final progress = reduceMotion
              ? (_animDirection > 0 ? 1.0 : 0.0)
              : _easedPosition(animation.value);
          if (progress != playerExpansion.value) {
            scheduleMicrotask(() {
              if (identical(activePlayerRoute, this)) playerExpansion.value = progress;
            });
          }
          final offset = Offset(0, 16 * (1 - progress));
          PlayerCoverMorphBus.instance.pageOffset = offset;
          return Opacity(opacity: progress, child: Transform.translate(
            offset: offset, child: content));
        },
      );
    }
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
        // 位置、外轮廓圆角与透明度各自独立映射：
        // 位置：播放页仍是**整屏尺寸**，只按 dy = 轮廓上沿整体下移，再由
        //   PlayerPanelFrame 裁剪到 [轮廓上沿, +轮廓高] 的窗口里 ——
        //   pos=0 时窗口恰好等于源形态（悬浮胶囊 / 圆盘 / 常驻条）的**可见本体**
        //   矩形，pos=1 铺满全屏；
        // 圆角：源形态外轮廓（胶囊/圆盘 32、常驻条 0）→ 设备上报的屏幕 r 角，
        //   这是「悬浮条外轮廓完美过渡到覆盖全屏」那条形变的主轴；
        // 透明度：页面内容前 20% 屏高线性 0→1，面板底色前 4% 行程 0→1。
        //
        // 为什么裁剪而不是压扁播放页：压扁会让它逐帧重新布局（歌词/封面/控件
        // 全部 reflow），且封面形变层那套「减去 pageOffset 换算归位矩形」的
        // 前提（页面只做平移）也不再成立。见 player_panel_frame.dart 的说明。
        //
        // **点击进入也走这里**（原先是「淡入 + 15% 抽屉上滑」）：用户要求非拖拽
        // 进出与拖拽观感一致。锚点未知时由 [panelGeometryFor] 合成一个胶囊本体
        // 起点，起点 opacity=0 所以估不准不可见。
        final size = Size(
          MediaQuery.sizeOf(context).width,
          screenHeight ?? MediaQuery.sizeOf(context).height,
        );
        if (size.height > 0 && size.width > 0) {
          final geometry = panelGeometryFor(size);
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
          // 顶栏下拉：整页沿「展开路径」原路下滑，窗口上沿同时跟着走。
          // 语义 = **把整个起点矩形平移到手指位置**（而不是只改上沿）：条高、
          // 横向范围与圆角都保持源形态口径，`p=0` 时窗口仍是「迷你条大小」，
          // 与旧式 `top = dragTop*(1-p)` + `miniHeight` 的推导逐值等价。
          final double? dragTotal = topBarDragTotal;
          final Rect originRect = dragTotal == null
              ? geometry.rect
              : geometry.rect.shift(Offset(0, dragTotal - geometry.rect.top));
          // 注意：**不要**在这里再包一层 Opacity。面板的不透明性由 PlayerPanelFrame
          // 内部的底色层保证，淡入只作用于页面内容（见该文件的结构说明）；
          // 把 Opacity 提到外面会把底色一起乘上透明度，过渡态照样透出背后内容。
          //
          // `pageOffset`（形变登记簿）由 PlayerPanelFrame 内部按轮廓上沿写入。
          return PlayerPanelFrame(
            progress: pos,
            originRect: originRect,
            originRadius: geometry.radius,
            screenRadii: MediaQuery.displayCornerRadiiOf(context),
            child: child,
          );
        }

        // —— 退化兜底：视口为 0（理论不可达）——
        // 此时面板几何除零，直接走「淡入 + 15% 抽屉上滑」，不做裁剪。
        // 位移、淡入淡出与 playerExpansion（形变层 / 迷你条 / 封面槽位）共用同一条
        // 进度：拆成两条长跑曲线会让飞行中的封面与它自己的槽位脱节。
        final height = size.height;
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
  Duration get transitionDuration =>
      usesLightweightDesktopEntry ? const Duration(milliseconds: 180) :
      defaultTargetPlatform == TargetPlatform.windows && !isDragMode
          ? const Duration(milliseconds: 220)
          : kPlayerExpandDuration;

  @override
  Duration get reverseTransitionDuration =>
      usesLightweightDesktopEntry ? const Duration(milliseconds: 160) :
      defaultTargetPlatform == TargetPlatform.windows && !isDragMode
          ? const Duration(milliseconds: 180)
          : kPlayerCollapseDuration;

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
