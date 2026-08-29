import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 播放器进度条 —— 一条最细的轨道 + 下方一行时间。
///
/// 设计要点：
/// - 已播放段与剩余段**不叠加**：剩余段从播放点后 4px 起画（MD3 expressive
///   的间隙做法）。
/// - 已播放段末端没有手柄，只有轨道自身的圆头。
/// - 时间常显但压暗（50%），按下/拖动时提亮到全不透明并膨胀轨道；
///   数字固定占 14px 一行，不会被上方内容遮挡或截断。
/// - 已播放段**播放中才有颜色**：暂停时在 220ms 内褪成与未播放段相同的
///   [inactiveColor]（拖动中视为「有颜色」，便于看清落点）。轨道全程是直线，
///   不再有波浪线样式。
/// - 位置**自驱动**：provider 的位置更新只有 ~200ms 一次（5fps），进度条内部
///   用 [Ticker] 以 30fps 自行累加时间，画面因此连续；每次收到上报就对齐一次
///   ([_rebase])，并做单调保护避免秒数回跳。倍速由 [speed] 参与推算。
/// - 拖动过程只更新本地画面与时间数字，**不下发 seek**（连续 seek 会把
///   音频层打满导致跟手卡顿），松手时才 seek 一次。
/// - [climaxStart]/[climaxEnd]（单位秒）非空时在轨道上叠加高潮区间高亮，
///   已播放的部分会被裁掉 —— 进度掠过后高亮逐渐消失。
class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.activeColor,
    required this.inactiveColor,
    required this.labelColor,
    this.isPlaying = false,
    this.md3Style = false,
    this.speed = 1.0,
    this.climaxStart,
    this.climaxEnd,
    this.height = 38,
    this.onSeekStart,
    this.onSeekEnd,
  });

  final Duration position;
  final Duration duration;

  /// 已播放段颜色（仅播放中/拖动中生效，其余时候褪成 [inactiveColor]）
  final Color activeColor;

  /// 未播放段轨道颜色
  final Color inactiveColor;

  /// 时间数字颜色
  final Color labelColor;

  /// 是否正在播放（决定已播放段是否上色、以及自驱动 ticker 是否推进）
  final bool isPlaying;

  /// MD3 皮肤：轨道 3px + 末端 stop indicator 圆点；AM 皮肤为 2px 纯细线。
  final bool md3Style;

  /// 播放倍速，用于自驱动推算位置（0.5x / 2x 时进度条不会走错速度）
  final double speed;

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

  /// 自驱动帧间隔：2fps（超过这个间隔才重绘进度条与两侧时间，
  /// 由 120Hz 屏幕节流到低频，只在校对/拖动时才高频）。
  static const int _frameIntervalMs = 500;

  /// 上报位置与推算位置差值超过这个阈值就认为发生了 seek / 切歌，硬重置
  static const int _resyncThresholdMs = 1000;

  /// 轨道膨胀动画：0 = 常态细轨道，1 = 拖动态粗轨道
  late final AnimationController _expand;

  /// 已播放段上色动画：1 = activeColor（播放中/拖动中），0 = inactiveColor
  late final AnimationController _tint;

  /// 2fps 自驱动定时器（进度条与两侧时间按此低频推进）
  Timer? _timerFrame;

  /// 自驱动帧计数：每帧 +1，驱动画布与时间数字重绘（不走 setState）
  final ValueNotifier<int> _frame = ValueNotifier(0);

  /// 拖动中的进度比例。用 ValueNotifier 而不是 setState：
  /// 跟手时每帧只重绘画布与时间数字，不重建整个 widget 子树（避免拖动卡顿）。
  final ValueNotifier<double> _dragFraction = ValueNotifier(0);

  /// 当前展示的位置（毫秒）—— 由定时器每帧间隔累加、由上报位置定期校准
  int _displayMs = 0;

  bool _dragging = false;
  double _trackWidth = 0;

  @override
  void initState() {
    super.initState();
    _expand = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _tint = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.isPlaying ? 1 : 0,
    );
    _displayMs = widget.position.inMilliseconds;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant PlayerSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position ||
        oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.duration != widget.duration) {
      _rebase();
    }
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncTint();
    }
    // duration 也要参与：切歌时常是 isPlaying 先变 true、durationStream 稍后才
    // 送来时长，若只在 isPlaying 变化时同步，ticker 的「时长已知」条件那一轮不
    // 满足就再无机会启动 → 该首歌全程退化成 200ms 上报驱动（5fps）。
    if (oldWidget.isPlaying != widget.isPlaying ||
        (oldWidget.duration > Duration.zero) !=
            (widget.duration > Duration.zero)) {
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _timerFrame?.cancel();
    _expand.dispose();
    _tint.dispose();
    _frame.dispose();
    _dragFraction.dispose();
    super.dispose();
  }

  /// 已播放段是否上色：播放中，或正在拖动（拖动会先 pause，但此时仍要看清落点）
  void _syncTint() {
    if (widget.isPlaying || _dragging) {
      _tint.forward();
    } else {
      _tint.reverse();
    }
  }

  /// 只在「播放中 + 未拖动 + 时长已知」时跑 2fps Timer，其余状态停住省电
  void _syncTicker() {
    final shouldRun =
        widget.isPlaying && !_dragging && widget.duration > Duration.zero;
    if (shouldRun) {
      // 2fps 自驱动：Timer 周期性累加位置并重绘；暂停/拖动时取消以省电
      _timerFrame ??= Timer.periodic(
        Duration(milliseconds: _frameIntervalMs),
        (_) => _advanceFrame(),
      );
    } else {
      _timerFrame?.cancel();
      _timerFrame = null;
    }
  }

  /// 2fps 自驱动推进：每帧间隔累加一次播放位置，触发画布与两侧时间重绘。
  void _advanceFrame() {
    final total = widget.duration.inMilliseconds;
    var next = _displayMs + (_frameIntervalMs * widget.speed).round();
    if (next < 0) next = 0;
    if (total > 0 && next > total) next = total;
    if (next == _displayMs) return;
    _displayMs = next;
    _frame.value++;
  }

  /// 收到新的上报位置：与自驱动的展示位置对齐。
  ///
  /// 单调保护：上报值略小于展示值（音频层上报抖动）且差距在
  /// [_resyncThresholdMs] 以内时保留展示值，避免时间数字来回跳；
  /// 差距过大（seek / 切歌）或已暂停则直接采用上报值。
  void _rebase() {
    final reported = widget.position.inMilliseconds;
    final drift = _displayMs - reported;
    if (widget.isPlaying &&
        !_dragging &&
        drift > 0 &&
        drift < _resyncThresholdMs) {
      return;
    }
    _displayMs = reported;
  }

  /// 当前绘制用的进度比例：拖动中用手指位置，否则用自驱动的展示位置
  double get _fraction {
    if (_dragging) return _dragFraction.value;
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_displayMs / total).clamp(0.0, 1.0);
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
    _syncTint();
    _syncTicker();
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
    // 松手即以落点为新的展示位置：seek 回调是异步的，等上报会先闪回旧位置
    _displayMs = target.inMilliseconds;
    _expand.reverse();
    _syncTint();
    _syncTicker();
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
              // 一个 AnimatedBuilder 同时驱动画布与时间数字：自驱动每帧与跟手
              // 都只重建这棵小子树（不走 setState），拖动才跟得上手指
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _expand,
                  _tint,
                  _frame,
                  _dragFraction,
                ]),
                builder: (context, _) {
                  final fraction = _fraction;
                  final elapsed = _durationAt(fraction);
                  final remaining = widget.duration - elapsed;
                  final trackColor =
                      Color.lerp(
                        widget.inactiveColor,
                        widget.activeColor,
                        Curves.easeOut.transform(_tint.value),
                      )!;
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
                            trackColor: trackColor,
                            inactiveColor: widget.inactiveColor,
                            climaxColor: widget.activeColor.withValues(
                              alpha: 0.45,
                            ),
                            md3Style: widget.md3Style,
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

/// 轨道绘制：未播放段 → 高潮高亮（只画未播放的那截）→ 已播放段 → stop indicator
class _SeekBarPainter extends CustomPainter {
  _SeekBarPainter({
    required this.fraction,
    required this.expandT,
    required this.trackColor,
    required this.inactiveColor,
    required this.climaxColor,
    required this.md3Style,
    required this.climaxRange,
  });

  final double fraction;
  final double expandT;

  /// 已播放段颜色（播放中为强调色，暂停时已褪成 [inactiveColor]）
  final Color trackColor;
  final Color inactiveColor;
  final Color climaxColor;
  final bool md3Style;
  final List<double>? climaxRange;

  /// 常态轨道高度：进度条是整个底部区里最细的元素。
  static const double _idleMd3Height = 3;
  static const double _idleFlatHeight = 2;

  /// 拖动态轨道高度
  static const double _dragHeight = 10;

  /// 已播放段与剩余段之间的间隙（MD3 expressive 的做法）
  static const double _segmentGap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    if (w <= 0) return;
    final cy = size.height / 2 + 2;
    final trackH = lerpDouble(
      md3Style ? _idleMd3Height : _idleFlatHeight,
      _dragHeight,
      expandT,
    )!;
    final r = trackH / 2;
    // 已播放段的末端：进度为 0 时也画一小段圆头，避免轨道左端空一块
    final activeEnd = math.max((w * fraction).clamp(0.0, w), trackH);
    final fx = activeEnd;
    // 剩余段起点 = 已播放段末端 + 间隙，两段互不叠加
    final remainStart = math.min(activeEnd + _segmentGap, w);

    // 1. 剩余段：只画播放点之后的部分
    if (remainStart < w) {
      canvas.drawRRect(
        RRect.fromLTRBR(remainStart, cy - r, w, cy + r, Radius.circular(r)),
        Paint()..color = inactiveColor,
      );
    }

    // 2. 高潮区间高亮：只画还没播到的那截 —— 已播放进度掠过后逐渐消失
    final climax = climaxRange;
    if (climax != null) {
      final left = math.max(w * climax[0], remainStart);
      final right = w * climax[1];
      if (right > left) {
        final ch = math.max(trackH * 0.7, 1.5);
        canvas.drawRRect(
          RRect.fromLTRBR(left, cy - ch, right, cy + ch, Radius.circular(ch)),
          Paint()..color = climaxColor,
        );
      }
    }

    // 3. 已播放段：直线，颜色由 trackColor 决定（暂停时与未播放段同色）
    final activePaint = Paint()..color = trackColor;
    canvas.drawRRect(
      RRect.fromLTRBR(0, cy - r, fx, cy + r, Radius.circular(r)),
      activePaint,
    );

    // 4. MD3 stop indicator：轨道末端的小圆点，进度接近末端时隐藏
    if (md3Style && fx < w - trackH * 3) {
      canvas.drawCircle(Offset(w - r, cy), math.max(1.5, r), activePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter old) =>
      old.fraction != fraction ||
      old.expandT != expandT ||
      old.trackColor != trackColor ||
      old.inactiveColor != inactiveColor ||
      old.climaxColor != climaxColor ||
      old.md3Style != md3Style ||
      old.climaxRange?[0] != climaxRange?[0] ||
      old.climaxRange?[1] != climaxRange?[1];
}
