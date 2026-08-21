import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/motion_constants.dart';
import '../../providers/theme_provider.dart';
import '../../utils/landscape_immersive.dart';
import 'full_player.dart';
import 'full_player_am.dart';

/// 全局过渡进度（0.0 = mini，1.0 = full）。
///
/// 由 [DraggablePlayerRoute] 内部的 AnimationController 同步驱动，
/// MiniPlayer 与 FullPlayer 通过 [ValueListenableBuilder] 监听此值，
/// 实现淡入淡出效果与拖拽距离线性绑定。
final ValueNotifier<double> playerExpansion = ValueNotifier<double>(0.0);

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

/// 松手判定：距离达标、速度达标、加速度达标三者任一即展开。
/// 加速度取绝对值：快速甩动时起手加速、末端减速，两者都代表强甩动。
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
double playerDragOriginTop = 0.0;

/// 兼容旧引用：返回 true 表示当前 FullPlayer 在栈顶。
/// 新代码应直接监听 [playerExpansion]。
bool get isFullPlayerOnTop => playerExpansion.value > 0.5;

/// 创建并返回可拖拽的 FullPlayer 路由。
///
/// 调用方可在拖拽手势 start 时调用并 push，然后通过 `route.controller`
/// 在拖动期间手动设置进度，释放时调用 [DraggablePlayerRoute.settleToFull] /
/// [DraggablePlayerRoute.dismiss]。
///
/// [dragOriginTop]/[screenHeight] 由 MiniPlayer 上滑拖拽传入（拖拽模式）：
/// - 拖拽模式：FullPlayer 顶端从 [dragOriginTop]（= MiniPlayer 顶端）开始
///   跟随手指上移，透明度在前 20% 屏高内线性 0→1；
/// - 不传（点击打开）：保持原有淡入 + 15% 上滑动画。
DraggablePlayerRoute<void> fullPlayerRoute(
  BuildContext context, {
  double? dragOriginTop,
  double? screenHeight,
}) {
  final useAm = context.read<ThemeProvider>().useAmStylePlayer;
  return DraggablePlayerRoute<void>(
    builder: (_) => useAm ? const AmStyleFullPlayer() : const FullPlayer(),
    dragOriginTop: dragOriginTop,
    screenHeight: screenHeight,
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
///   透明度在前 20% 屏高内 0→1；松手后 [settleToFull]（easeOutCubic）完整展开
///   或 [dismiss] 收起
/// - [controller] 暴露给外部手势：拖动期间 `controller.stop()` + `controller.value = x`，
///   释放时调用 [settleToFull] / [dismiss]
class DraggablePlayerRoute<T> extends PageRoute<T> {
  DraggablePlayerRoute({
    required this.builder,
    this.dragOriginTop,
    this.screenHeight,
  });

  final WidgetBuilder builder;

  /// MiniPlayer 顶端全局 Y 坐标（拖拽模式下非空）。
  final double? dragOriginTop;

  /// 拖拽开始时的屏幕高度（拖拽模式下非空）。
  final double? screenHeight;

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
    // ignore: avoid_print
    print(
      '[Route] dismiss v=${controller.value} animating=${controller.isAnimating}',
    );
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

  /// 松手后完整展开：播放 300ms easeOutCubic 前向动画。
  void settleToFull() {
    if (_isDismissing) return;
    _animStartValue = controller.value;
    _animDirection = 1;
    // ignore: avoid_print
    print(
      '[Route] settleToFull v=${controller.value} animating=${controller.isAnimating}',
    );
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
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 300),
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

  /// 松手动画期间（forward/reverse）归一化应用 easeOutCubic：
  /// 以动画起点 [_animStartValue] 为基准，把「起点 → 目标值」的剩余区间
  /// 归一化后套用曲线，保证动画起点与拖拽终点连续、不跳变。
  double _easedPosition(double raw) {
    final start = _animStartValue.clamp(0.0, 1.0);
    if (_animDirection > 0) {
      // 展开：raw 从 start → 1
      if (start >= 1.0) return raw;
      final t = ((raw - start) / (1.0 - start)).clamp(0.0, 1.0);
      return start + (1.0 - start) * Curves.easeOutCubic.transform(t);
    }
    // 收起：raw 从 start → 0
    if (start <= 0.0) return raw;
    final t = ((start - raw) / start).clamp(0.0, 1.0);
    return start * (1.0 - Curves.easeOutCubic.transform(t));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
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

        // —— 原路返回映射（MiniPlayer 上滑展开 / 顶栏向下拖拽收起）——
        // 位置与透明度独立映射：
        // 位置：dy = origin*(1-pos)，顶端沿「展开路径」1:1 跟手
        // 透明度：前 20% 屏高线性 0→1，之后保持 1
        // origin = 拖拽模式的 MiniPlayer 顶端；顶栏拖拽（含 tap 模式）用
        // topBarDragTotal（= MiniPlayer 顶端），实现点击进入也能原路返回
        if (isDragMode || topBarDrag) {
          final height = screenHeight ?? MediaQuery.sizeOf(context).height;
          final origin = topBarDragTotal ?? dragOriginTop!;
          final pos = controller.isAnimating ? _easedPosition(raw) : raw;
          final dy = origin * (1 - pos);
          final opacity = (pos * origin / (kPlayerExpandDistanceRatio * height))
              .clamp(0.0, 1.0);
          if (pos != playerExpansion.value) {
            playerExpansion.value = pos;
          }
          return Opacity(
            opacity: opacity,
            child: Transform.translate(offset: Offset(0, dy), child: child),
          );
        }

        // —— tap 模式（点击打开）：淡入 + 抽屉上滑感 ——
        // 展开动画播放期间（forward/reverse）应用过冲 curve，带轻微过冲感
        // 拖拽期间 controller.value 被手动设置（isAnimating=false），保持跟手
        final progress = controller.isAnimating
            ? M3ExpressiveMotion.expressiveEasing.transform(raw).clamp(0.0, 1.0)
            : raw;
        // 同步到全局 playerExpansion，让 MiniPlayer 同步淡入淡出（含过冲）
        if (progress != playerExpansion.value) {
          playerExpansion.value = progress;
        }
        // 淡入：progress 0→1 时 opacity 0→1
        // 滑动：progress 0→1 时从 15% 屏幕高度下方位移滑到 0（抽屉上滑感）
        return Opacity(
          opacity: progress,
          child: FractionalTranslation(
            translation: Tween<Offset>(
              begin: const Offset(0, 0.15),
              end: Offset.zero,
            ).transform(progress),
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
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  bool didPop(T? result) {
    // pop 时立即清零进度，让 MiniPlayer 立即恢复可见
    if (playerExpansion.value != 0.0) {
      playerExpansion.value = 0.0;
    }
    return super.didPop(result);
  }
}
