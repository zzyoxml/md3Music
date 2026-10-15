import 'dart:async';

import 'package:flutter/widgets.dart';

/// 交错柱状图组件：柱子从 0 高度生长到目标高度
///
/// 使用 [AnimationController] + `Future.delayed` 实现延迟启动，非常驻 Ticker。
/// 动画结束后控制器自动 dispose，符合 AGENTS §10 限帧约定。
class StaggeredBar extends StatefulWidget {
  const StaggeredBar({
    super.key,
    required this.index,
    required this.totalItems,
    required this.heightFactor,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.interItemDelay = const Duration(milliseconds: 100),
    this.curve = Curves.easeOutCubic,
  });

  /// 当前索引（0-based），用于计算延迟时间
  final int index;

  /// 总项数（用于确定最大延迟）
  final int totalItems;

  /// 目标高度因子 (0.0 ~ 1.0)
  final double heightFactor;

  /// 柱子内容
  final Widget child;

  /// 动画持续时间
  final Duration duration;

  /// 每项之间的间隔时间
  final Duration interItemDelay;

  /// 缓动曲线
  final Curve curve;

  @override
  State<StaggeredBar> createState() => _StaggeredBarState();
}

class _StaggeredBarState extends State<StaggeredBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _heightAnim;

  @override
  void initState() {
    super.initState();

    // 计算延迟时间
    final delay = widget.interItemDelay * widget.index;

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _heightAnim = Tween<double>(
      begin: 0.0,
      end: widget.heightFactor.clamp(0.0, 1.0),
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    ));

    // 延迟启动动画
    Future.delayed(delay, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 必须在**有界高度**内使用（调用方用 Expanded 包住）：
    // FractionallySizedBox(heightFactor) 在无界高度约束下会算出 NaN 约束而崩溃。
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: _heightAnim.value,
        child: widget.child,
      ),
    );
  }
}

/// 交错进度条组件：从 0 宽度延伸到目标宽度
class StaggeredProgressBar extends StatefulWidget {
  const StaggeredProgressBar({
    super.key,
    required this.index,
    required this.totalItems,
    required this.targetValue,
    this.minWidthFactor = 0.08,
    this.height = 7.0,
    this.color,
    this.gradient,
    this.duration = const Duration(milliseconds: 350),
    this.interItemDelay = const Duration(milliseconds: 100),
    this.curve = Curves.easeOutCubic,
  });

  final int index;
  final int totalItems;
  final double targetValue;
  final double minWidthFactor;
  final double height;
  final Color? color;
  final Gradient? gradient;
  final Duration duration;
  final Duration interItemDelay;
  final Curve curve;

  @override
  State<StaggeredProgressBar> createState() => _StaggeredProgressBarState();
}

class _StaggeredProgressBarState extends State<StaggeredProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _widthAnim;

  @override
  void initState() {
    super.initState();

    final delay = widget.interItemDelay * widget.index;

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _widthAnim = Tween<double>(
      begin: 0.0,
      end: widget.targetValue.clamp(0.0, 1.0),
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    ));

    Future.delayed(delay, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: _widthAnim.value.clamp(widget.minWidthFactor, 1.0),
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: widget.color,
          gradient: widget.gradient,
        ),
      ),
    );
  }
}

/// 交错上浮淡入：内容从下方 [offset] 处上浮并淡入到位。
///
/// 与 [StaggeredBar] / [StaggeredProgressBar] 同族：按 index 交错延迟启动，
/// 一次性动画收敛即停（非常驻 Ticker，符合 AGENTS §10 限帧约定）。
/// 适合区块/行级入场（专辑 banner、列表行）。
class StaggeredSlideFade extends StatefulWidget {
  const StaggeredSlideFade({
    super.key,
    required this.index,
    required this.totalItems,
    required this.child,
    this.offset = 16.0,
    this.duration = const Duration(milliseconds: 350),
    this.interItemDelay = const Duration(milliseconds: 100),
    this.curve = Curves.easeOutCubic,
  });

  final int index;
  final int totalItems;
  final Widget child;

  /// 上浮起始偏移（逻辑像素）。
  final double offset;

  final Duration duration;
  final Duration interItemDelay;
  final Curve curve;

  @override
  State<StaggeredSlideFade> createState() => _StaggeredSlideFadeState();
}

class _StaggeredSlideFadeState extends State<StaggeredSlideFade>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnim;
  late Animation<double> _opacityAnim;

  @override
  void initState() {
    super.initState();

    final delay = widget.interItemDelay * widget.index;

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _slideAnim = Tween<Offset>(
      begin: Offset(0, widget.offset),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    ));

    _opacityAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    Future.delayed(delay, () {
      if (mounted) {
        _controller.forward();
      }
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
      position: _slideAnim,
      child: FadeTransition(
        opacity: _opacityAnim,
        child: widget.child,
      ),
    );
  }
}

/// 数字计数动画文本：从 from 递增/递减到 to
class CounterAnimationText extends StatelessWidget {
  const CounterAnimationText({
    super.key,
    required this.from,
    required this.to,
    this.duration = const Duration(milliseconds: 500),
    this.curve = Curves.easeOutCubic,
    this.suffix = '',
    this.style,
    this.alignment = TextAlign.left,
  });

  final int from;
  final int to;
  final Duration duration;
  final Curve curve;
  final String suffix;
  final TextStyle? style;
  final TextAlign alignment;

  @override
  Widget build(BuildContext context) {
    // 必须用 IntTween：Tween<int> 的默认 lerp 会算出 double 而抛异常。
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: from, end: to),
      duration: duration,
      curve: curve,
      builder: (context, value, child) {
        return Text(
          '$value$suffix',
          style: style,
          textAlign: alignment,
        );
      },
    );
  }
}

/// 延迟淡入：经过 [delay] 后从透明渐显到不透明。
///
/// 注意不能用「AnimatedOpacity(opacity: 0)」裸实现——该 widget 只在属性**变化**
/// 时插值，初始值即终值等于永不显示。必须由状态翻转驱动。
class FadeIn extends StatefulWidget {
  const FadeIn({
    super.key,
    this.delay,
    this.duration = const Duration(milliseconds: 200),
    this.curve = Curves.easeOut,
    required this.child,
  });

  final Widget child;

  /// 延迟时长；null 或零表示立即显示（不套动画）。
  final Duration? delay;

  final Duration duration;
  final Curve curve;

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    final d = widget.delay;
    if (d == null || d == Duration.zero) {
      _visible = true;
    } else {
      Future.delayed(d, () {
        if (mounted) setState(() => _visible = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.0,
      duration: widget.delay == null ? Duration.zero : widget.duration,
      curve: widget.curve,
      child: widget.child,
    );
  }
}

/// [FadeIn] 的便捷函数形式。
Widget fadeIn(
  Widget child, {
  Duration? delay,
  Duration duration = const Duration(milliseconds: 200),
  Curve curve = Curves.easeOut,
}) {
  return FadeIn(
    delay: delay,
    duration: duration,
    curve: curve,
    child: child,
  );
}

/// 缩放 + 淡入复合入场容器（整体进场用）。
class EntranceScaleFade extends StatefulWidget {
  const EntranceScaleFade({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.curve = Curves.easeOutBack,
  });

  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  State<EntranceScaleFade> createState() => _EntranceScaleFadeState();
}

class _EntranceScaleFadeState extends State<EntranceScaleFade>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _opacityAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _scaleAnim = Tween<double>(begin: 0.85, end: 1.0).chain(
      CurveTween(curve: widget.curve),
    ).animate(_controller);

    _opacityAnim = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
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
    return AnimatedBuilder(
      animation: _scaleAnim,
      builder: (context, child) {
        return Opacity(
          opacity: _opacityAnim.value,
          child: Transform.scale(
            scale: _scaleAnim.value,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
