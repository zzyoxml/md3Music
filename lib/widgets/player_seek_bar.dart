import 'dart:math' as math;
import 'dart:ui' show FontFeature, lerpDouble;

import 'package:flutter/material.dart';

/// 播放器进度条 —— 一条最细的轨道 + 下方一行时间。
///
/// 设计要点：
/// - 已播放段与剩余段**不叠加**：剩余段从播放点后 4px 起画（MD3 expressive
///   的间隙做法），因此剩余段那条直线不会从波形底下穿过。
/// - 已播放段末端没有手柄，只有轨道自身的圆头。
/// - 时间常显但压暗（50%），按下/拖动时提亮到全不透明并膨胀轨道；
///   数字固定占 14px 一行，不会被上方内容遮挡或截断。
/// - [wavy] 为 true（MD3 皮肤）时活动轨道画正弦波，**只在播放中起伏**：
///   暂停或拖动时波幅在 250ms 内收敛成直线（颜色不变），右端保留 MD3
///   stop indicator 圆点；AM 皮肤全程纯细线（wavy=false）。
/// - 拖动过程只更新本地画面与时间数字，**不下发 seek**（连续 seek 会把
///   音频层打满导致跟手卡顿），松手时才 seek 一次。
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
    this.climaxStart,
    this.climaxEnd,
    this.height = 38,
    this.onSeekStart,
    this.onSeekEnd,
  });

  final Duration position;
  final Duration duration;

  /// 已播放段颜色
  final Color activeColor;

  /// 未播放段轨道颜色
  final Color inactiveColor;

  /// 时间数字颜色
  final Color labelColor;

  /// 是否正在播放（决定波形是起伏还是收敛成直线）
  final bool isPlaying;

  /// 活动轨道是否画波形（MD3 皮肤 true / AM 皮肤 false）
  final bool wavy;

  /// 高潮区间起止（秒），任一为空则不画高亮
  final double? climaxStart;
  final double? climaxEnd;

  final double height;

  /// 开始拖动（用于暂停播放避免与 seek 抢位）
  final VoidCallback? onSeekStart;

  /// 松手后的最终位置
  final ValueChanged<Duration>? onSeekEnd;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar>
    with TickerProviderStateMixin {
  /// 时间行高度（[PlayerSeekBar.height] 减去它就是轨道区高度）
  static const double _labelHeight = 14;

  /// 轨道膨胀动画：0 = 常态细轨道，1 = 拖动态粗轨道
  late final AnimationController _expand;

  /// 波形相位：一个周期 3s，播放中持续推进
  late final AnimationController _phase;

  /// 波幅系数：1 = 完整起伏，0 = 直线。暂停/拖动时 250ms 收敛成直线。
  late final AnimationController _wave;

  /// 拖动中的进度比例。用 ValueNotifier 而不是 setState：
  /// 跟手时每帧只重绘画布与时间数字，不重建整个 widget 子树（避免拖动卡顿）。
  final ValueNotifier<double> _dragFraction = ValueNotifier(0);

  bool _dragging = false;
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
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.wavy && widget.isPlaying ? 1 : 0,
    );
    // 波幅收敛到 0 之后再停相位 ticker：先让波形平滑压平，再省掉每帧重绘
    _wave.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && _phase.isAnimating) {
        _phase.stop();
      }
    });
    _syncWave();
  }

  @override
  void didUpdateWidget(covariant PlayerSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.wavy != widget.wavy) {
      _syncWave();
    }
  }

  /// 只在「波形皮肤 + 正在播放 + 未拖动」时起伏；
  /// 其余状态把波幅动画回 0（变成直线，颜色不变），并在归零后停住 ticker。
  void _syncWave() {
    final shouldWave = widget.wavy && widget.isPlaying && !_dragging;
    if (shouldWave) {
      if (!_phase.isAnimating) _phase.repeat();
      _wave.forward();
    } else {
      _wave.reverse();
    }
  }

  @override
  void dispose() {
    _expand.dispose();
    _phase.dispose();
    _wave.dispose();
    _dragFraction.dispose();
    super.dispose();
  }

  /// 当前绘制用的进度比例：拖动中用手指位置，否则用播放位置
  double get _fraction {
    if (_dragging) return _dragFraction.value;
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
    _dragFraction.value = _fractionFromDx(dx);
    setState(() => _dragging = true);
    _expand.forward();
    _syncWave();
    widget.onSeekStart?.call();
  }

  /// 跟手：只更新本地比例（画布与数字跟着 ValueNotifier 重绘），
  /// 不下发 seek —— 每帧 seek 会把音频层打满，表现为拖动发卡。
  void _updateDrag(double dx) {
    if (!_dragging) return;
    _dragFraction.value = _fractionFromDx(dx);
  }

  void _endDrag() {
    if (!_dragging) return;
    final target = _durationAt(_dragFraction.value);
    setState(() => _dragging = false);
    _expand.reverse();
    _syncWave();
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
            child: RepaintBoundary(
              // 一个 AnimatedBuilder 同时驱动画布与时间数字：跟手时只重建这棵
              // 小子树（不走 setState），拖动才跟得上手指
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _expand,
                  _phase,
                  _wave,
                  _dragFraction,
                ]),
                builder: (context, _) {
                  final fraction = _fraction;
                  final elapsed = _durationAt(fraction);
                  final remaining = widget.duration - elapsed;
                  return Column(
                    children: [
                      Expanded(
                        child: CustomPaint(
                          // 必须显式给 Size.infinite：CustomPaint 无 child 时默认
                          // size 是 Size.zero，在 Column 里横向是松约束 → 宽度会被
                          // 约束成 0，画布拿到 0 宽，轨道就完全画不出来（但手势
                          // 仍在，表现为「看不见却能拖」）。
                          size: Size.infinite,
                          painter: _SeekBarPainter(
                            fraction: fraction,
                            expandT: Curves.easeOut.transform(_expand.value),
                            phase: _phase.value,
                            waveT: Curves.easeOut.transform(_wave.value),
                            activeColor: widget.activeColor,
                            inactiveColor: widget.inactiveColor,
                            wavy: widget.wavy,
                            climaxRange: _climaxRange,
                          ),
                        ),
                      ),
                      // 时间：常显但压暗，拖动时提亮到全不透明
                      SizedBox(
                        height: _labelHeight,
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: _dragging ? 1 : 0.5,
                            duration: const Duration(milliseconds: 150),
                            child: Row(
                              children: [
                                Text(_format(elapsed), style: labelStyle),
                                const Spacer(),
                                Text(
                                  '-${_format(remaining)}',
                                  style: labelStyle,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
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
    required this.waveT,
    required this.activeColor,
    required this.inactiveColor,
    required this.wavy,
    required this.climaxRange,
  });

  final double fraction;
  final double expandT;
  final double phase;

  /// 波幅系数：1 = 完整起伏，0 = 直线（暂停/拖动）
  final double waveT;
  final Color activeColor;
  final Color inactiveColor;
  final bool wavy;
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

  /// 已播放段与剩余段之间的间隙（MD3 expressive 的做法）
  static const double _segmentGap = 4;

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
    // 已播放段的末端：进度为 0 时也画一小段圆头，避免轨道左端空一块
    final activeEnd = math.max((w * fraction).clamp(0.0, w), trackH);
    final fx = activeEnd;
    // 剩余段起点 = 已播放段末端 + 间隙，两段互不叠加
    final remainStart = math.min(activeEnd + _segmentGap, w);

    // 1. 剩余段：只画播放点之后的部分（不再整条铺满，
    //    否则这条直线会从已播放段的波形底下穿过）
    if (remainStart < w) {
      canvas.drawRRect(
        RRect.fromLTRBR(remainStart, cy - r, w, cy + r, Radius.circular(r)),
        Paint()..color = inactiveColor,
      );
    }

    // 2. 高潮区间高亮：贴在轨道上，用半透明强调色
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

    // 3. 已播放段：波幅由 waveT 控制（暂停/拖动时收敛为 0，画成直线）
    final amp = wavy ? _waveAmplitude * waveT : 0.0;
    final activePaint = Paint()..color = activeColor;
    if (amp < 0.2 || fx < trackH * 2) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, cy - r, fx, cy + r, Radius.circular(r)),
        activePaint,
      );
    } else {
      final path = Path();
      bool first = true;
      for (double x = 0; x <= fx; x += 2) {
        // 靠近末端时把波幅收敛为 0，让波形平滑地接回轨道中线
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

    // 4. MD3 stop indicator：轨道末端的小圆点，进度接近末端时隐藏
    if (wavy && fx < w - trackH * 3) {
      canvas.drawCircle(Offset(w - r, cy), math.max(1.5, r), activePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter old) =>
      old.fraction != fraction ||
      old.expandT != expandT ||
      old.phase != phase ||
      old.waveT != waveT ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.wavy != wavy ||
      old.climaxRange?[0] != climaxRange?[0] ||
      old.climaxRange?[1] != climaxRange?[1];
}
