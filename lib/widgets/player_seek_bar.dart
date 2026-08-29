import 'dart:math' as math;
import 'dart:ui' show FontFeature, lerpDouble;

import 'package:flutter/material.dart';

/// 播放器进度条 —— 常态只有一条细轨道，按下时轨道膨胀并浮出时间标签。
///
/// 设计要点：
/// - 时间数字不常驻：拖动时才在轨道上方浮现（左＝已播放，右＝剩余 -m:ss）。
///   标签用 `Clip.none` 溢出到控件上方绘制，因此不占纵向布局高度，
///   进度区整体只有 [height]（默认 24）而不是 Slider 固定的 48。
/// - [wavy] 为 true（MD3 皮肤）时活动轨道画正弦波：播放中起伏、拖动时抚平，
///   并在右端画 MD3 stop indicator 圆点；AM 皮肤用纯细线（wavy=false）。
/// - [climaxStart]/[climaxEnd]（单位秒）非空时在轨道上叠加高潮区间高亮。
class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.activeColor,
    required this.inactiveColor,
    required this.labelColor,
    this.isPlaying = false,
    this.wavy = false,
    this.showHandle = true,
    this.climaxStart,
    this.climaxEnd,
    this.height = 24,
    this.onSeekStart,
    this.onSeekUpdate,
    this.onSeekEnd,
  });

  final Duration position;
  final Duration duration;

  /// 已播放段 + 手柄颜色
  final Color activeColor;

  /// 未播放段轨道颜色
  final Color inactiveColor;

  /// 拖动时浮现的时间标签颜色
  final Color labelColor;

  /// 是否正在播放（决定波形相位是否推进）
  final bool isPlaying;

  /// 活动轨道是否画波形（MD3 皮肤 true / AM 皮肤 false）
  final bool wavy;

  /// 是否画手柄（MD3 竖条手柄 / AM 无手柄，只有轨道末端圆角）
  final bool showHandle;

  /// 高潮区间起止（秒），任一为空则不画高亮
  final double? climaxStart;
  final double? climaxEnd;

  final double height;

  /// 开始拖动（用于暂停播放避免与 seek 抢位）
  final VoidCallback? onSeekStart;

  /// 拖动中的实时位置
  final ValueChanged<Duration>? onSeekUpdate;

  /// 松手后的最终位置
  final ValueChanged<Duration>? onSeekEnd;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar>
    with TickerProviderStateMixin {
  /// 轨道膨胀动画：0 = 常态细轨道，1 = 拖动态粗轨道（同时把波形抚平）
  late final AnimationController _expand;

  /// 波形相位：一个周期 3s，播放中持续推进
  late final AnimationController _phase;

  bool _dragging = false;
  double _dragFraction = 0;
  double _trackWidth = 0;

  @override
  void initState() {
    super.initState();
    _expand = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _phase = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _syncPhase();
  }

  @override
  void didUpdateWidget(covariant PlayerSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.wavy != widget.wavy) {
      _syncPhase();
    }
  }

  /// 只在「波形皮肤 + 正在播放 + 未拖动」时推进相位，其余状态停住 ticker，
  /// 避免暂停/AM 皮肤下每帧无谓重绘。
  void _syncPhase() {
    final shouldRun = widget.wavy && widget.isPlaying && !_dragging;
    if (shouldRun && !_phase.isAnimating) {
      _phase.repeat();
    } else if (!shouldRun && _phase.isAnimating) {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    _expand.dispose();
    _phase.dispose();
    super.dispose();
  }

  /// 当前绘制用的进度比例：拖动中用手指位置，否则用播放位置
  double get _fraction {
    if (_dragging) return _dragFraction;
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _durationAt(double fraction) => Duration(
    milliseconds: (widget.duration.inMilliseconds * fraction).round(),
  );

  double _fractionFromDx(double dx) =>
      _trackWidth <= 0 ? 0 : (dx / _trackWidth).clamp(0.0, 1.0);

  void _startDrag(double dx) {
    if (widget.duration.inMilliseconds <= 0) return;
    setState(() {
      _dragging = true;
      _dragFraction = _fractionFromDx(dx);
    });
    _expand.forward();
    _syncPhase();
    widget.onSeekStart?.call();
    widget.onSeekUpdate?.call(_durationAt(_dragFraction));
  }

  void _updateDrag(double dx) {
    if (!_dragging) return;
    setState(() => _dragFraction = _fractionFromDx(dx));
    widget.onSeekUpdate?.call(_durationAt(_dragFraction));
  }

  void _endDrag() {
    if (!_dragging) return;
    final target = _durationAt(_dragFraction);
    setState(() => _dragging = false);
    _expand.reverse();
    _syncPhase();
    widget.onSeekEnd?.call(target);
  }

  static String _format(Duration d) {
    final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // 等宽数字：拖动时秒数跳动不会让标签左右抖动
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: widget.labelColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final elapsed = _durationAt(_fraction);
    final remaining = widget.duration - elapsed;

    return LayoutBuilder(
      builder: (context, constraints) {
        _trackWidth = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 点按轨道任意位置即跳转（按下就进入膨胀态，松手落定）
          onTapDown: (d) => _startDrag(d.localPosition.dx),
          onTapUp: (_) => _endDrag(),
          onTapCancel: _endDrag,
          onHorizontalDragStart: (d) => _startDrag(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => _updateDrag(d.localPosition.dx),
          onHorizontalDragEnd: (_) => _endDrag(),
          onHorizontalDragCancel: _endDrag,
          child: SizedBox(
            height: widget.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 时间标签浮层：溢出到轨道上方绘制，不占布局高度
                Positioned(
                  top: -16,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _dragging ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Row(
                        children: [
                          Text(_format(elapsed), style: labelStyle),
                          const Spacer(),
                          Text('-${_format(remaining)}', style: labelStyle),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_expand, _phase]),
                      builder: (context, _) => CustomPaint(
                        painter: _SeekBarPainter(
                          fraction: _fraction,
                          expandT: Curves.easeOut.transform(_expand.value),
                          phase: _phase.value,
                          activeColor: widget.activeColor,
                          inactiveColor: widget.inactiveColor,
                          wavy: widget.wavy,
                          showHandle: widget.showHandle,
                          climaxRange: _climaxRange,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 高潮区间归一化到 0~1；缺少数据或时长未知时返回 null。
  List<double>? get _climaxRange {
    final start = widget.climaxStart;
    final end = widget.climaxEnd;
    final totalMs = widget.duration.inMilliseconds;
    if (start == null || end == null || totalMs <= 0 || end <= start) {
      return null;
    }
    return [
      (start * 1000 / totalMs).clamp(0.0, 1.0),
      (end * 1000 / totalMs).clamp(0.0, 1.0),
    ];
  }
}

/// 轨道绘制：未播放段 → 高潮高亮 → 已播放段（波形/直线）→ 手柄 → stop indicator
class _SeekBarPainter extends CustomPainter {
  _SeekBarPainter({
    required this.fraction,
    required this.expandT,
    required this.phase,
    required this.activeColor,
    required this.inactiveColor,
    required this.wavy,
    required this.showHandle,
    required this.climaxRange,
  });

  final double fraction;
  final double expandT;
  final double phase;
  final Color activeColor;
  final Color inactiveColor;
  final bool wavy;
  final bool showHandle;
  final List<double>? climaxRange;

  /// 常态轨道高度：进度条是整个底部区里最细的元素，
  /// 波形皮肤只比直线皮肤粗 1px（波峰靠 [_waveAmplitude] 撑开，不靠轨道厚度）。
  static const double _idleWavyHeight = 3;
  static const double _idleFlatHeight = 2;

  /// 拖动态轨道高度
  static const double _dragHeight = 10;

  /// 波长与波幅
  static const double _waveLength = 26;
  static const double _waveAmplitude = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    if (w <= 0) return;
    final cy = size.height / 2 + 2;
    final trackH = lerpDouble(
      wavy ? _idleWavyHeight : _idleFlatHeight,
      _dragHeight,
      expandT,
    )!;
    final r = trackH / 2;
    final fx = (w * fraction).clamp(0.0, w);

    // 1. 未播放段：整条轨道铺底
    canvas.drawRRect(
      RRect.fromLTRBR(0, cy - r, w, cy + r, Radius.circular(r)),
      Paint()..color = inactiveColor,
    );

    // 2. 高潮区间高亮：压在活动轨道下方，用半透明强调色
    final climax = climaxRange;
    if (climax != null) {
      final ch = math.max(trackH * 0.7, 1.5);
      canvas.drawRRect(
        RRect.fromLTRBR(
          w * climax[0],
          cy - ch,
          w * climax[1],
          cy + ch,
          Radius.circular(ch),
        ),
        Paint()..color = activeColor.withValues(alpha: 0.45),
      );
    }

    // 3. 已播放段
    final amp = wavy ? _waveAmplitude * (1 - expandT) : 0.0;
    final activePaint = Paint()..color = activeColor;
    if (amp < 0.5 || fx < trackH * 2) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          0,
          cy - r,
          math.max(fx, trackH),
          cy + r,
          Radius.circular(r),
        ),
        activePaint,
      );
    } else {
      final path = Path();
      bool first = true;
      for (double x = 0; x <= fx; x += 2) {
        // 靠近末端时把波幅收敛为 0，让波形平滑地接进手柄
        final taper = ((fx - x) / 14).clamp(0.0, 1.0);
        final y =
            cy +
            amp * taper * math.sin((x / _waveLength + phase) * 2 * math.pi);
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      path.lineTo(fx, cy);
      canvas.drawPath(
        path,
        Paint()
          ..color = activeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = trackH
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 4. 手柄：MD3 竖条，按下时变粗变高（AM 皮肤不画）
    if (showHandle) {
      final hw = lerpDouble(3, 5, expandT)!;
      final hh = lerpDouble(12, 20, expandT)!;
      canvas.drawRRect(
        RRect.fromLTRBR(
          (fx - hw / 2).clamp(0.0, w - hw),
          cy - hh / 2,
          (fx - hw / 2).clamp(0.0, w - hw) + hw,
          cy + hh / 2,
          Radius.circular(hw / 2),
        ),
        activePaint,
      );
    }

    // 5. MD3 stop indicator：轨道末端的小圆点，进度接近末端时隐藏
    if (wavy && fx < w - trackH * 3) {
      canvas.drawCircle(
        Offset(w - r, cy),
        math.max(1.5, r),
        activePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter old) =>
      old.fraction != fraction ||
      old.expandT != expandT ||
      old.phase != phase ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.wavy != wavy ||
      old.showHandle != showHandle ||
      old.climaxRange?[0] != climaxRange?[0] ||
      old.climaxRange?[1] != climaxRange?[1];
}
