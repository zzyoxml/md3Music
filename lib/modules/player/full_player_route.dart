import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/motion_constants.dart';
import '../../providers/theme_provider.dart';
import 'full_player.dart';
import 'full_player_am.dart';

/// 全局过渡进度（0.0 = mini，1.0 = full）。
///
/// 由 [DraggablePlayerRoute] 内部的 AnimationController 同步驱动，
/// MiniPlayer 与 FullPlayer 通过 [ValueListenableBuilder] 监听此值，
/// 实现淡入淡出效果与拖拽距离线性绑定。
final ValueNotifier<double> playerExpansion = ValueNotifier<double>(0.0);

/// 拖拽距离阈值（px）：拖动该距离即达到全进度。
const double kPlayerDragThreshold = 220.0;

/// 兼容旧引用：返回 true 表示当前 FullPlayer 在栈顶。
/// 新代码应直接监听 [playerExpansion]。
bool get isFullPlayerOnTop => playerExpansion.value > 0.5;

/// 创建并返回可拖拽的 FullPlayer 路由。
///
/// 调用方可在拖拽手势 start 时调用并 push，然后通过 `route.controller`
/// 在拖动期间手动设置进度，释放时调用 `forward()`/`reverse()`/`fling()`。
DraggablePlayerRoute<void> fullPlayerRoute(BuildContext context) {
  final useAm = context.read<ThemeProvider>().useAmStylePlayer;
  return DraggablePlayerRoute<void>(
    builder: (_) => useAm ? const AmStyleFullPlayer() : const FullPlayer(),
  );
}

/// 可拖拽的 FullPlayer 路由。
///
/// 设计要点：
/// - [opaque] = false：路由背景透明，下层 MiniPlayer 可见，实现交叉淡入淡出
/// - [buildTransitions]：用 [AnimationController.value] 驱动
///   `Opacity + SlideTransition`，淡入为主、抽屉上滑为辅
/// - [controller] 暴露给外部手势：拖动期间 `controller.stop()` + `controller.value = x`
///   释放时 `controller.fling(velocity: v)` / `forward()` / `reverse()`
class DraggablePlayerRoute<T> extends PageRoute<T> {
  DraggablePlayerRoute({required this.builder});

  final WidgetBuilder builder;

  /// 由 [createAnimationController] 赋值，外部手势可读取此字段直接驱动。
  /// 重写父类（[TransitionRoute]）的同名 getter（返回 `AnimationController?`），
  /// 收窄为非空类型，便于调用方直接使用而无需 null-check。
  @override
  late AnimationController controller;

  /// 是否正在执行 dismiss 流程（reverse 动画 + removeRoute），
  /// 防止手势/按钮重复触发。
  bool _isDismissing = false;

  /// 收起播放器：播放 reverse 动画，完成后移除路由。
  /// 供 FullPlayer 内部的按钮/手势调用。
  void dismiss() {
    if (_isDismissing) return;
    _isDismissing = true;
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

  /// Flutter 3.44 起 [TransitionRoute.createAnimationController] 不再接收
  /// `vsync` 参数——框架内部直接使用 `navigator!` 作为 TickerProvider。
  /// 我们在此重写仅是为了定制 `duration` / `reverseDuration`，并把创建的
  /// 控制器赋值到 [controller]，供外部手势读取。
  @override
  AnimationController createAnimationController() {
    controller = AnimationController(
      vsync: navigator!,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 250),
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    return controller;
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return builder(context);
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final raw = animation.value.clamp(0.0, 1.0);
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
  Duration get reverseTransitionDuration => const Duration(milliseconds: 250);

  @override
  bool didPop(T? result) {
    // pop 时立即清零进度，让 MiniPlayer 立即恢复可见
    if (playerExpansion.value != 0.0) {
      playerExpansion.value = 0.0;
    }
    return super.didPop(result);
  }
}
