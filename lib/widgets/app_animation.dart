import 'package:material_ui/material_ui.dart';

import '../core/services/player_frame_driver.dart';

class FadeInUp extends StatefulWidget {
  final Widget child;
  final int delayMs;
  final Duration duration;
  final Offset offset;

  const FadeInUp({
    super.key,
    required this.child,
    this.delayMs = 0,
    this.duration = const Duration(milliseconds: 400),
    this.offset = const Offset(0, 24),
  });

  @override
  State<FadeInUp> createState() => _FadeInUpState();
}

class _FadeInUpState extends State<FadeInUp>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: widget.offset,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
  }
}

/// 内容入场动画：向上淡入滑动，仅在首次创建时播放。
/// 与 [FadeInUp] 不同，当父组件 rebuild 时不会重播动画，
/// 适用于 TabBarView 子页面等需要保持动画状态的场景。
class ContentEntrance extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Offset offset;

  const ContentEntrance({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.offset = const Offset(0, 0.08),
  });

  @override
  State<ContentEntrance> createState() => _ContentEntranceState();
}

class _ContentEntranceState extends State<ContentEntrance>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: widget.offset,
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
  }
}

class ScaleIn extends StatefulWidget {
  final Widget child;
  final int delayMs;
  final Duration duration;

  const ScaleIn({
    super.key,
    required this.child,
    this.delayMs = 0,
    this.duration = const Duration(milliseconds: 300),
  });

  @override
  State<ScaleIn> createState() => _ScaleInState();
}

class _ScaleInState extends State<ScaleIn> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _scale = Tween<double>(begin: 0.85, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

class ShimmerLoading extends StatefulWidget {
  final double width;
  final double height;
  final double radius;

  const ShimmerLoading({
    super.key,
    this.width = double.infinity,
    this.height = 16,
    this.radius = 8,
  });

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 一轮扫光的时长。
  static const Duration _period = Duration(milliseconds: 1500);

  /// 仅作「进度值容器」：其 Ticker 永不启动（见 [_onTick]），
  /// 帧生产由共享 60fps 节拍限制（AGENTS.md §10.4.1）。
  late AnimationController _controller;

  /// 是否已挂在共享 60fps 帧驱动上（见 [_syncDriver]）。
  bool _driverBound = false;

  /// [TickerMode] 是否被关闭（被不透明路由覆盖 / 切走 tab）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台（引擎不产帧，Timer 空转纯属唤醒浪费）。
  bool _appSuspended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(vsync: this, duration: _period);
    _syncDriver();
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.valuesOf(context).enabled;
    if (muted == _tickerModeMuted) return;
    _tickerModeMuted = muted;
    _syncDriver();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncDriver();
  }

  /// 唯一收口：仅在「可见 + 前台」时挂共享 60fps 节拍（幂等）。
  ///
  /// 原实现用 `repeat()`：控制器 Ticker 每帧 scheduleFrame，120Hz 屏上骨架屏
  /// 会让整页保持 120fps（AGENTS.md §10.1.1 / §10.4.1）。
  void _syncDriver() {
    final bool shouldRun = !_tickerModeMuted && !_appSuspended;
    if (shouldRun == _driverBound) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onTick);
    } else {
      PlayerFrameDriver.instance.removeListener(_onTick);
    }
    _driverBound = shouldRun;
  }

  /// 共享节拍回调：按一轮时长步进进度（0→1 循环）。
  void _onTick() {
    _controller.value = (_controller.value +
            PlayerFrameDriver.step.inMilliseconds / _period.inMilliseconds) %
        1.0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_driverBound) {
      PlayerFrameDriver.instance.removeListener(_onTick);
      _driverBound = false;
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              colors: [
                colorScheme.surfaceContainerHighest,
                colorScheme.surfaceContainerLow,
                colorScheme.surfaceContainerHighest,
              ],
              stops: [
                _controller.value - 0.3,
                _controller.value,
                _controller.value + 0.3,
              ],
            ),
          ),
        );
      },
    );
  }
}

class HoverScale extends StatefulWidget {
  final Widget child;
  final double scale;
  final VoidCallback? onTap;

  const HoverScale({
    super.key,
    required this.child,
    this.scale = 1.05,
    this.onTap,
  });

  @override
  State<HoverScale> createState() => _HoverScaleState();
}

class _HoverScaleState extends State<HoverScale>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _animation = Tween<double>(begin: 1, end: widget.scale).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _controller.forward(),
      onExit: (_) => _controller.reverse(),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            return Transform.scale(
              scale: _animation.value,
              child: child,
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

class AnimatedPageTransition extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;

  const AnimatedPageTransition({
    super.key,
    required this.animation,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.05, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      )),
      child: FadeTransition(
        opacity: animation,
        child: child,
      ),
    );
  }
}

class AnimatedListWrapper extends StatelessWidget {
  final int index;
  final Widget child;
  final Duration? duration;
  final int? delayFactor;

  const AnimatedListWrapper({
    super.key,
    required this.index,
    required this.child,
    this.duration,
    this.delayFactor = 30,
  });

  @override
  Widget build(BuildContext context) {
    return _AnimatedListItem(
      index: index,
      duration: duration ?? const Duration(milliseconds: 300),
      delayFactor: delayFactor!,
      child: child,
    );
  }
}

class _AnimatedListItem extends StatefulWidget {
  final int index;
  final Widget child;
  final Duration duration;
  final int delayFactor;

  const _AnimatedListItem({
    required this.index,
    required this.child,
    required this.duration,
    required this.delayFactor,
  });

  @override
  State<_AnimatedListItem> createState() => _AnimatedListItemState();
}

class _AnimatedListItemState extends State<_AnimatedListItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;
  static const int _maxConcurrentAnimations = 10;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    final delay = _calculateDelay();
    Future.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  Duration _calculateDelay() {
    final baseDelay = widget.index * widget.delayFactor;
    final staggeredDelay = (widget.index ~/ _maxConcurrentAnimations) * 200;
    return Duration(milliseconds: baseDelay + staggeredDelay);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

extension AnimatedBuildContext on BuildContext {
  Future<T> pushAnimated<T>(Widget page) {
    final result = Navigator.of(this).push<T>(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            )),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
    return result.then((v) => v as T);
  }
}