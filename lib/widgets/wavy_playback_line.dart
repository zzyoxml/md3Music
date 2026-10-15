import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/services/player_frame_driver.dart';

const Duration _kFlattenDuration = Duration(milliseconds: 500);
const Duration _kColorDuration = Duration(milliseconds: 200);

/// 采样步长，一个波长内约 24 段。
const double _kSampleStep = 1.5;

/// 律动线：[isPlaying] 为 true 时波形向右流动，为 false 时收成直线。
///
/// 只表示"在响/没在响"，不带进度语义。
class WavyPlaybackLine extends StatefulWidget {
  const WavyPlaybackLine({
    super.key,
    required this.isPlaying,
    required this.color,
    this.height = 10.0,
    this.strokeWidth = 3.0,
    this.wavelength = 36.0,
    this.amplitude = 3.0,
    this.waveSpeed = 20.0,
  });

  final bool isPlaying;

  final Color color;

  final double height;
  final double strokeWidth;

  /// 相邻两个波峰的距离。
  final double wavelength;

  /// 波峰相对中线的最大偏移。
  final double amplitude;

  /// 波形横向流动速度，逻辑像素每秒。
  final double waveSpeed;

  @override
  State<WavyPlaybackLine> createState() => _WavyPlaybackLineState();
}

class _WavyPlaybackLineState extends State<WavyPlaybackLine>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _phase;
  late final AnimationController _flatten;
  late final AnimationController _color;
  late final Listenable _repaint;

  late Color _fromColor;

  /// 波形相位是否需要推进：播放中，或压平动画尚未走完（amp>0 才看得见波形）。
  bool _phaseWanted = false;

  /// 是否已把相位挂在共享 60fps 帧驱动上（见 [_syncPhaseDriver]）。
  bool _phaseDriverBound = false;

  /// [TickerMode] 是否被关闭（被不透明路由覆盖 / 切走 tab）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台（引擎不产帧，Timer 空转纯属唤醒浪费）。
  bool _appSuspended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _phase = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: widget.waveSpeed > 0
            ? (widget.wavelength / widget.waveSpeed * 1000).round()
            : 1000,
      ),
    );
    _flatten = AnimationController(
      vsync: this,
      duration: _kFlattenDuration,
      value: widget.isPlaying ? 1.0 : 0.0,
    );
    _color = AnimationController(
      vsync: this,
      duration: _kColorDuration,
      value: 1.0,
    );
    _repaint = Listenable.merge([_phase, _flatten, _color]);
    _fromColor = widget.color;
    // 振幅归零后波形不可见，停掉相位推进。
    _flatten.addStatusListener(_onFlattenStatus);
    _phaseWanted = widget.isPlaying;
    _syncPhaseDriver();
  }

  void _onFlattenStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      _phaseWanted = false;
      _syncPhaseDriver();
    }
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.valuesOf(context).enabled;
    if (muted == _tickerModeMuted) return;
    _tickerModeMuted = muted;
    _syncPhaseDriver();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncPhaseDriver();
  }

  /// 唯一收口：仅在「需要流动 + 可见 + 前台」时挂共享 60fps 节拍（幂等）。
  ///
  /// 原实现用 `_phase.repeat()`：控制器 Ticker 每帧 scheduleFrame，120Hz 屏上
  /// 即便本组件只是装饰性律动线也让整页保持 120fps（§10.1.1 / §10.4.1）。
  void _syncPhaseDriver() {
    final bool shouldRun =
        _phaseWanted && !_tickerModeMuted && !_appSuspended;
    if (shouldRun == _phaseDriverBound) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onPhaseTick);
    } else {
      PlayerFrameDriver.instance.removeListener(_onPhaseTick);
    }
    _phaseDriverBound = shouldRun;
  }

  /// 共享节拍回调：按一个波长周期步进相位（0→1 循环）。
  void _onPhaseTick() {
    final int ms = _phase.duration?.inMilliseconds ?? 0;
    if (ms <= 0) return;
    _phase.value =
        (_phase.value + PlayerFrameDriver.step.inMilliseconds / ms) % 1.0;
  }

  @override
  void didUpdateWidget(covariant WavyPlaybackLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _phaseWanted = true;
        _syncPhaseDriver();
        _flatten.forward();
      } else {
        _flatten.reverse();
      }
    }
    if (widget.color != oldWidget.color) {
      _fromColor = Color.lerp(_fromColor, oldWidget.color, _color.value)!;
      _color.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flatten.removeStatusListener(_onFlattenStatus);
    if (_phaseDriverBound) {
      PlayerFrameDriver.instance.removeListener(_onPhaseTick);
      _phaseDriverBound = false;
    }
    _phase.dispose();
    _flatten.dispose();
    _color.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        painter: _WavyLinePainter(
          repaint: _repaint,
          phase: _phase,
          flatten: _flatten,
          colorT: _color,
          fromColor: _fromColor,
          toColor: widget.color,
          strokeWidth: widget.strokeWidth,
          wavelength: widget.wavelength,
          amplitude: widget.amplitude,
        ),
      ),
    );
  }
}

class _WavyLinePainter extends CustomPainter {
  _WavyLinePainter({
    required Listenable repaint,
    required this.phase,
    required this.flatten,
    required this.colorT,
    required this.fromColor,
    required this.toColor,
    required this.strokeWidth,
    required this.wavelength,
    required this.amplitude,
  }) : super(repaint: repaint);

  final Animation<double> phase;
  final Animation<double> flatten;
  final Animation<double> colorT;
  final Color fromColor;
  final Color toColor;
  final double strokeWidth;
  final double wavelength;
  final double amplitude;

  @override
  void paint(Canvas canvas, Size size) {
    // 圆端帽会向两端各外探半个线宽，先缩进去，让可见范围正好等于给定宽度。
    final inset = strokeWidth / 2;
    final left = inset;
    final right = size.width - inset;
    if (right <= left) return;

    canvas.drawPath(
      _buildPath(size, left, right),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Color.lerp(fromColor, toColor, colorT.value)!,
    );
  }

  Path _buildPath(Size size, double left, double right) {
    final centerY = size.height / 2;
    final amp = amplitude * flatten.value;
    final path = Path();
    if (amp < 0.05) {
      path.moveTo(left, centerY);
      path.lineTo(right, centerY);
      return path;
    }
    final shift = phase.value * 2 * math.pi;
    double y(double x) =>
        centerY + amp * math.sin(x / wavelength * 2 * math.pi - shift);
    path.moveTo(left, y(left));
    for (var x = left + _kSampleStep; x < right; x += _kSampleStep) {
      path.lineTo(x, y(x));
    }
    path.lineTo(right, y(right));
    return path;
  }

  @override
  bool shouldRepaint(covariant _WavyLinePainter oldDelegate) {
    return oldDelegate.fromColor != fromColor ||
        oldDelegate.toColor != toColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.wavelength != wavelength ||
        oldDelegate.amplitude != amplitude;
  }
}
