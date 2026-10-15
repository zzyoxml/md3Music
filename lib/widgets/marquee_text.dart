import 'package:flutter/material.dart';

import '../core/services/player_frame_driver.dart';

/// 优雅的单行滚动文字：文本不溢出时完全静止；溢出时以"起停往返"节奏
/// 缓动滚动（两端停顿 + easeInOut + 边缘渐隐），而非传统匀速循环跑马灯。
///
/// 用于播放页封面下方的歌名 / 艺人·专辑等可能过长、又不希望换行的位置。
class GentleScrollingText extends StatefulWidget {
  const GentleScrollingText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.left,
    this.dwell = const Duration(milliseconds: 2000),
    this.pixelsPerSecond = 45.0,
    this.fadeWidth = 16.0,
  });

  final String text;
  final TextStyle? style;

  /// 文本不溢出时的对齐方式（溢出时一律从左侧起滚）。
  final TextAlign textAlign;

  /// 两端停顿时长。
  final Duration dwell;

  /// 滚动线速度（px/s），用于按溢出距离折算滚动时长，避免长文本滚得太快。
  final double pixelsPerSecond;

  /// 两端渐隐遮罩宽度（仅滚动时启用）。
  final double fadeWidth;

  @override
  State<GentleScrollingText> createState() => _GentleScrollingTextState();
}

class _GentleScrollingTextState extends State<GentleScrollingText>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 仅作「进度值容器」：其 Ticker 永不启动（见 [_onTick]），
  /// 帧生产由共享 60fps 节拍限制（AGENTS.md §10.4.1）。
  late final AnimationController _controller = AnimationController(vsync: this);
  Animation<double> _progress = const AlwaysStoppedAnimation(0.0);
  double _overflow = 0.0;

  /// 是否已挂在共享 60fps 帧驱动上（见 [PlayerFrameDriver]）。
  bool _boundToDriver = false;

  /// 渐隐遮罩 shader 缓存：`ShaderMask` 每次 paint 都会重新调用
  /// `shaderCallback`，而滑动期间本层每帧都要重绘 —— 不缓存就是每帧新建一个
  /// `LinearGradient` + shader。按 bounds 尺寸比对复用（对齐 AppleLyricsView
  /// 的 `_fadeShaderFor`）。
  Shader? _fadeShader;
  Rect? _fadeShaderBounds;

  /// 文本测量缓存：build 可能被父级高频触发，`TextPainter.layout()` 是纯排版
  /// 开销，只在 (文本, 样式, 可用宽) 变化时重算。
  TextPainter? _measurePainter;
  String? _measuredText;
  TextStyle? _measuredStyle;
  double? _measuredMaxWidth;

  /// TickerMode 是否被关闭（被不透明路由覆盖 / TabBarView 切走）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台（引擎不产帧，Timer 空转纯属唤醒浪费，§10.7）。
  bool _appSuspended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起，
  /// 否则「组件不可见仍持续产帧」——本仓最常见的漏电点（§10.4.3）。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.valuesOf(context).enabled;
    if (muted != _tickerModeMuted) {
      _tickerModeMuted = muted;
      _syncDriver();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncDriver();
  }

  /// 唯一收口：仅在「确实需要滚动 + 可见 + 前台」时挂共享节拍（幂等）。
  void _syncDriver() {
    final bool shouldRun =
        _overflow > 0.5 && !_tickerModeMuted && !_appSuspended;
    if (shouldRun == _boundToDriver) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onTick);
    } else {
      PlayerFrameDriver.instance.removeListener(_onTick);
    }
    _boundToDriver = shouldRun;
  }

  /// 共享节拍回调：按当前节奏总时长步进进度（0→1 循环）。
  ///
  /// 用步进 `.value` 而不是 `repeat()`：controller 的 Ticker 不会被启动，
  /// 帧生产由 16ms 共享定时器限制到 60fps（`repeat()` 会让 120Hz 屏整页
  /// 保持 120fps，见 AGENTS.md §10.1.1 / §10.4.1）。
  void _onTick() {
    final int ms = _controller.duration?.inMilliseconds ?? 0;
    if (ms <= 0) return;
    _controller.value =
        (_controller.value + PlayerFrameDriver.step.inMilliseconds / ms) % 1.0;
  }

  @override
  void didUpdateWidget(covariant GentleScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文本/样式变化（切歌等）→ 复位节奏，重新按新宽度决定是否滚动。
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller
        ..stop()
        ..reset();
      _overflow = 0.0;
      _syncDriver();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_boundToDriver) {
      PlayerFrameDriver.instance.removeListener(_onTick);
      _boundToDriver = false;
    }
    _controller.dispose();
    super.dispose();
  }

  /// 溢出距离变化时（重）构造往返节奏；不溢出时复位并停驱动。
  ///
  /// [overflow] 传 0（或其值 ≤0.5）表示当前不溢出 —— 静止普通文本。
  void _configure(double overflow) {
    if (overflow <= 0.5) {
      // 不溢出：复位并停驱动（§10.4.6「画面静止」必须停帧）。
      if (_overflow != 0.0) {
        _overflow = 0.0;
        _controller.value = 0.0;
      }
      _syncDriver();
      return;
    }
    // 判据由 `_controller.isAnimating` 改为 `_boundToDriver`：改用共享节拍后
    // controller 的 Ticker 永不启动，`isAnimating` 恒为 false，原判据会失效。
    if ((overflow - _overflow).abs() < 0.5 && _boundToDriver) return;
    _overflow = overflow;
    final dwellMs = widget.dwell.inMilliseconds;
    final scrollMs = (overflow / widget.pixelsPerSecond * 1000)
        .clamp(1500.0, 9000.0)
        .round();
    _controller
      ..stop()
      ..duration = Duration(milliseconds: dwellMs * 2 + scrollMs * 2);
    _progress = TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem(tween: ConstantTween(0.0), weight: dwellMs.toDouble()),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: scrollMs.toDouble(),
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: dwellMs.toDouble()),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: scrollMs.toDouble(),
      ),
    ]).animate(_controller);
    _syncDriver();
  }

  /// 复用缓存的渐隐遮罩 shader（按 bounds 尺寸比对）。
  Shader _fadeShaderFor(Rect bounds) {
    if (_fadeShader != null && bounds == _fadeShaderBounds) {
      return _fadeShader!;
    }
    final fade = (widget.fadeWidth / bounds.width).clamp(0.0, 0.5);
    final shader = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const [
        Colors.transparent,
        Colors.black,
        Colors.black,
        Colors.transparent,
      ],
      stops: [0.0, fade, 1 - fade, 1.0],
    ).createShader(bounds);
    _fadeShader = shader;
    _fadeShaderBounds = bounds;
    return shader;
  }

  /// 复用缓存的排版结果（按 文本 / 样式 / 可用宽 比对）。
  TextPainter _measure(
    TextStyle style,
    double maxWidth,
    TextDirection direction,
  ) {
    final cached = _measurePainter;
    if (cached != null &&
        _measuredText == widget.text &&
        _measuredStyle == style &&
        _measuredMaxWidth == maxWidth) {
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: 1,
      textDirection: direction,
    )..layout();
    _measurePainter = painter;
    _measuredText = widget.text;
    _measuredStyle = style;
    _measuredMaxWidth = maxWidth;
    return painter;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = widget.style ?? DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final painter = _measure(
          effectiveStyle,
          maxWidth,
          Directionality.of(context),
        );
        final overflow = painter.width - maxWidth;
        final bool overflows = overflow > 0.5 && maxWidth.isFinite;

        // 溢出与否都走同一条收口；放在 post-frame 里以免在 build 中启停驱动。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _configure(overflows ? overflow : 0.0);
        });

        if (!overflows) {
          // 不溢出：完全静止的普通文本。
          return Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            textAlign: widget.textAlign,
            style: effectiveStyle,
          );
        }

        final textWidget = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: effectiveStyle,
        );

        // 高度必须收敛为单行文本高度：下方 OverflowBox 会把自身尺寸取为
        // constraints.biggest，在 Column（纵向约束无界）里会解析成无限高度，
        // 导致 ShaderMask 拿到无限 rect、shader 画不出内容 → 文本整块消失
        // （横屏左栏窄、dense，过长歌名/艺人/专辑更易触发，即“横屏过长时消失”的根因）。
        return SizedBox(
          height: painter.height,
          // 滑动期间每帧只动内部 Transform：独立绘制层把重绘限制在本组件内，
          // 不让 60fps 的文本位移扩散到整个播放页（AGENTS.md §10）。
          child: RepaintBoundary(
            child: ClipRect(
              child: ShaderMask(
                shaderCallback: _fadeShaderFor,
                blendMode: BlendMode.dstIn,
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (context, child) => OverflowBox(
                    alignment: Alignment.centerLeft,
                    maxWidth: double.infinity,
                    child: Transform.translate(
                      offset: Offset(-overflow * _progress.value, 0),
                      child: child,
                    ),
                  ),
                  child: textWidget,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
