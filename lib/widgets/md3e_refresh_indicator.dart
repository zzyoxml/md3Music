import 'package:flutter/material.dart';

import 'md3e_loading_indicator.dart';

/// MD3 Expressive 风格下拉刷新指示器。
///
/// **不依赖** Flutter 原生 [RefreshIndicator]（它内部硬编码的 Material
/// elevation 会产生圆形阴影，且无法与下拉距离实时同步）。
///
/// **实现原理**：
/// - 用 [NotificationListener] 监听可滚动 widget 的 [OverscrollNotification]，
///   累积下拉距离。
/// - 在 [Stack] 顶层用 [Positioned] 显示 [MD3ELoadingIndicator]，
///   其位置、缩放、透明度随下拉距离实时变化。
/// - 用户松手（[ScrollEndNotification]）后，若累积距离超过阈值，触发 [onRefresh]；
///   否则平滑回弹隐藏。
/// - 刷新期间指示器固定显示在 [displacement] 位置，直到 onRefresh 完成。
///
/// **使用示例**：
/// ```dart
/// MD3ERefreshIndicator(
///   onRefresh: _loadData,
///   child: ListView(...),
/// )
/// ```
class MD3ERefreshIndicator extends StatefulWidget {
  /// 触发刷新的回调。
  ///
  /// 当用户下拉释放后调用。返回的 [Future] 完成后，刷新指示器消失。
  final RefreshCallback onRefresh;

  /// 可滚动的内容。
  ///
  /// 必须是可滚动 widget（[ListView]、[GridView]、[CustomScrollView] 等）。
  final Widget child;

  /// 刷新时指示器中心距顶部的距离。
  ///
  /// 默认 56.0。
  final double displacement;

  /// MD3E 指示器尺寸。
  ///
  /// 默认 40.0（pull-to-refresh 场景略小于全屏 loading 的 48dp）。
  final double indicatorSize;

  /// 触发刷新的下拉距离阈值。
  ///
  /// 默认 72.0，与 M3 pull-to-refresh 推荐值接近。
  final double triggerThreshold;

  const MD3ERefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.displacement = 56.0,
    this.indicatorSize = 40.0,
    this.triggerThreshold = 72.0,
  });

  @override
  State<MD3ERefreshIndicator> createState() => _MD3ERefreshIndicatorState();
}

class _MD3ERefreshIndicatorState extends State<MD3ERefreshIndicator>
    with SingleTickerProviderStateMixin {
  /// 当前下拉累积距离（正值，0 表示未下拉）。
  ///
  /// 由 [OverscrollNotification.overscroll] 累积得到，带 0.5 阻尼系数
  /// 让指示器移动比手指慢，更自然。
  double _dragOffset = 0;

  /// 是否正在刷新（onRefresh 已触发，等待 Future 完成）。
  bool _isRefreshing = false;

  /// 是否正在回弹（下拉未达阈值，松手后回到 0）。
  bool _isSettling = false;

  late final AnimationController _controller;
  late Animation<double> _settleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 处理滚动通知，跟踪下拉距离并触发刷新。
  bool _handleScrollNotification(ScrollNotification notification) {
    // 刷新中或回弹中不处理
    if (_isRefreshing || _isSettling) return false;

    // 情况1：内容正常滚动（pixels > 0），说明用户已经把内容往上滑了
    // 此时如果还有下拉距离，应该让指示器平滑回弹（而不是瞬间消失）
    if (notification.metrics.pixels > 0.5) {
      if (_dragOffset > 0) {
        _settleBack();
      }
      return false;
    }

    // 以下处理内容在顶部（pixels <= 0）的情况
    if (notification is OverscrollNotification) {
      if (notification.overscroll < 0) {
        // overscroll < 0 表示在顶部继续下拉
        // 阻尼系数 0.5 让指示器移动比手指慢，模拟"橡皮筋"阻力
        _dragOffset += notification.overscroll.abs() * 0.5;
        // 限制最大下拉距离，避免无限拉伸
        if (_dragOffset > widget.triggerThreshold * 1.5) {
          _dragOffset = widget.triggerThreshold * 1.5;
        }
        _updateIndicator();
      } else {
        // overscroll > 0 表示在顶部反向滑（往上滑）
        // 按源路径反向缩小：减少下拉距离，指示器上移、缩小、淡出
        _dragOffset -= notification.overscroll.abs() * 0.5;
        if (_dragOffset < 0) _dragOffset = 0;
        _updateIndicator();
      }
    } else if (notification is ScrollEndNotification) {
      if (_dragOffset >= widget.triggerThreshold) {
        // 达到阈值，触发刷新
        _triggerRefresh();
      } else if (_dragOffset > 0) {
        // 未达阈值，平滑回弹
        _settleBack();
      }
    }
    return false;
  }

  /// 触发刷新。
  Future<void> _triggerRefresh() async {
    _isRefreshing = true;
    // 刷新时把指示器固定到 displacement 位置
    _dragOffset = widget.displacement;
    _updateIndicator();

    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        // 短暂停顿让用户看到刷新完成的视觉反馈
        await Future.delayed(const Duration(milliseconds: 150));
        _isRefreshing = false;
        _settleBack();
      }
    }
  }

  /// 平滑回弹到 0。
  void _settleBack() {
    if (_dragOffset == 0) return;
    _isSettling = true;

    final startOffset = _dragOffset;
    _settleAnimation = Tween<double>(
      begin: startOffset,
      end: 0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    void listener() {
      _dragOffset = _settleAnimation.value;
      _updateIndicator();
    }

    _settleAnimation.addListener(listener);
    _controller.forward(from: 0).then((_) {
      _settleAnimation.removeListener(listener);
      _dragOffset = 0;
      _isSettling = false;
      _updateIndicator();
    });
  }

  /// 触发指示器 UI 更新。
  ///
  /// 通过 setState 重绘 Stack，让 Positioned 的 top、Transform.scale、
  /// Opacity 随 _dragOffset 变化。
  void _updateIndicator() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 计算指示器可见性、缩放、位置
    final progress = (_dragOffset / widget.triggerThreshold).clamp(0.0, 1.0);
    final showIndicator = _isRefreshing || _dragOffset > 0;
    // 刷新时固定 1.0，下拉时随进度 0→1
    final scale = _isRefreshing ? 1.0 : progress;
    final opacity = _isRefreshing ? 1.0 : progress;
    // 指示器垂直位置：下拉时跟随 _dragOffset（但被 progress 限制，最大到 displacement），
    // 刷新时固定在 displacement
    final indicatorTop = _isRefreshing
        ? widget.displacement - widget.indicatorSize / 2
        : (_dragOffset * 0.7 - widget.indicatorSize / 2).clamp(
            -widget.indicatorSize,
            widget.displacement * 1.2,
          );

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 可滚动内容
          widget.child,
          // MD3E 指示器：下拉过程中实时显示，跟随下拉距离移动/缩放/淡入
          if (showIndicator)
            Positioned(
              top: indicatorTop,
              left: 0,
              right: 0,
              child: IgnorePointer(
                // 始终不拦截触摸事件，避免阻挡内容交互
                ignoring: true,
                child: Center(
                  child: Opacity(
                    opacity: opacity,
                    child: Transform.scale(
                      scale: scale,
                      child: _MD3EIndicatorWithContainer(
                        indicatorSize: widget.indicatorSize,
                        // 使用 primary 色，匹配 M3 pull-to-refresh 规范
                        indicatorColor: colorScheme.primary,
                        // 容器圆背景：primary 的更浅色变体（surfaceContainerHigh）
                        containerColor: colorScheme.surfaceContainerHigh,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 带圆形容器背景 + 底部阴影的 MD3E 指示器。
///
/// 在 [MD3ELoadingIndicator] 外包裹一个浅色圆形背景（容器），
/// 并在圆形底部添加柔和阴影，营造"漂浮"质感。
///
/// - 容器尺寸：[indicatorSize] * 1.35（比指示器大 35%，让背景露出一圈）
/// - 阴影：使用 [BoxShadow] 在底部偏移 3dp，blurRadius 6dp，
///   颜色为 onSurface 的 18% 透明度，营造自然光感
class _MD3EIndicatorWithContainer extends StatelessWidget {
  final double indicatorSize;
  final Color indicatorColor;
  final Color containerColor;

  const _MD3EIndicatorWithContainer({
    required this.indicatorSize,
    required this.indicatorColor,
    required this.containerColor,
  });

  @override
  Widget build(BuildContext context) {
    // 容器尺寸比指示器大 35%，让浅色背景露出一圈
    final containerSize = indicatorSize * 1.35;
    final shadowColor = Theme.of(context).colorScheme.onSurface;

    return SizedBox(
      width: containerSize,
      height: containerSize,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // 1. 圆形容器背景 + 底部阴影
          Container(
            width: containerSize,
            height: containerSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: containerColor,
              boxShadow: [
                BoxShadow(
                  // 底部阴影：向下偏移 3dp，blur 6dp，颜色为 onSurface 的 18% 透明度
                  color: shadowColor.withValues(alpha: 0.18),
                  offset: const Offset(0, 3),
                  blurRadius: 6,
                  spreadRadius: 0,
                ),
              ],
            ),
          ),
          // 2. 中心 MD3E 指示器
          MD3ELoadingIndicator(
            size: indicatorSize,
            color: indicatorColor,
          ),
        ],
      ),
    );
  }
}
