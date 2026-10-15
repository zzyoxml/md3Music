import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/utils/app_haptics.dart';
import 'sleep_timer_polygon.dart';

/// 定时关闭的最小值（分钟）。
const int kSleepTimerMinMinutes = 1;

/// 定时关闭的最大值（分钟）= 24 小时。
const int kSleepTimerMaxMinutes = kSleepTimerMaxHours * 60;

/// 钳到合法区间 [1, 1440]。
///
/// 刻意**不做取整**：拖动中的表盘要能停在任意角度（无级），量化到整分钟会让
/// 指针以 6° 为步长跳格，手感是「卡」而不是「跟手」。取整只发生在显示文本和
/// 最终提交时。
double clampSleepTimerMinutes(double minutes) => minutes.clamp(
  kSleepTimerMinMinutes.toDouble(),
  kSleepTimerMaxMinutes.toDouble(),
);

/// 相对圆心的偏移 → 顺时针弧度（0 = 12 点方向），范围 [0, 2π)。
double dialAngleOf(Offset offset) {
  final a = math.atan2(offset.dx, -offset.dy);
  return a < 0 ? a + 2 * math.pi : a;
}

/// 在 [currentMinutes] 上叠加 [deltaRadians] 的转动量（顺时针为正）。
///
/// 跨过 12 点即进位/退位到相邻小时；越界钳到 [1, 1440]，不回绕。返回小数分钟，
/// 由调用方决定何时取整。
double advanceSleepTimerMinutes(double currentMinutes, double deltaRadians) {
  final deltaMinutes = deltaRadians / (2 * math.pi) * 60;
  return clampSleepTimerMinutes(currentMinutes + deltaMinutes);
}

/// 圆形定时关闭表盘。
///
/// - 拖动指针调分钟：顺时针每跨一次 12 点 +1 小时（套圈），上限 24 小时。
///   拖动是**无级**的——指针连续跟随手指，只在显示文本与提交时取整。
/// - 粗弧 = 当前圈的分钟进度；外圈细弧 = 总进度 / 24 小时。
/// - 中央是 m3e 形状（小时数一变就换一种齿轮形），显示小时与分钟；点击它即
///   [onStart]。
class SleepTimerDial extends StatefulWidget {
  const SleepTimerDial({
    super.key,
    required this.minutes,
    required this.onChanged,
    required this.onStart,
    this.maxSize = 300,
  });

  /// 当前值（分钟），应在 [kSleepTimerMinMinutes, kSleepTimerMaxMinutes] 内。
  final int minutes;

  /// 拖动产生的新值（已钳制）。
  final ValueChanged<int> onChanged;

  /// 点击中央形状。
  final VoidCallback onStart;

  /// 边长上限；实际边长取 `min(父约束宽度, maxSize)`。
  final double maxSize;

  @override
  State<SleepTimerDial> createState() => _SleepTimerDialState();
}

class _SleepTimerDialState extends State<SleepTimerDial> {
  /// 上一次采样到的弧度；拖动结束后置空。
  double? _lastAngle;

  /// 本次拖动自持的分钟数（小数，无级）。
  ///
  /// 增量不能累加在 `widget.minutes` 上：父层靠 setState 回写，一帧内到达的
  /// 多个 pointer move 会读到同一个旧值，除最后一次外的增量全被丢弃
  /// （last-write-wins）。起拖时置为 `widget.minutes`，之后只在它上面累加。
  double? _dragMinutes;

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(global);
    return local - box.size.center(Offset.zero);
  }

  /// 拖动中用于绘制的小数分钟；未拖动时回落到父层的整数值。
  double get _visualMinutes => _dragMinutes ?? widget.minutes.toDouble();

  void _onPanStart(DragStartDetails details) {
    // 只记角度，不吸附：按下即把指针吸到手指位置会让值瞬间跳一大截，
    // 手感是「跳」而不是「跟手」。要精确设定走下方的手动输入。
    _lastAngle = dialAngleOf(_toLocal(details.globalPosition));
    _dragMinutes = widget.minutes.toDouble();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final last = _lastAngle;
    final current = _dragMinutes;
    if (last == null || current == null) return;
    final angle = dialAngleOf(_toLocal(details.globalPosition));
    var delta = angle - last;
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    _lastAngle = angle;
    final next = advanceSleepTimerMinutes(current, delta);
    // 亚分钟级的移动不会改变父层的整数值（onChanged 不发），但指针要跟着动
    // → 必须自己 setState，否则指针会卡在 6° 的格子上。
    setState(() => _dragMinutes = next);
    if (next ~/ 60 != current ~/ 60) {
      AppHaptics.tick(HapticCategory.slider);
    }
    final rounded = next.round();
    if (rounded != widget.minutes) widget.onChanged(rounded);
  }

  void _onPanEnd() {
    _lastAngle = null;
    _dragMinutes = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final track = scheme.surfaceContainerHighest;
    // 文本先取整再拆分：直接对 59.7 取 %60 会得到「1 小时 60 分钟」这种脏值。
    final total = _visualMinutes.round();
    final hours = total ~/ 60;
    final minutes = total % 60;

    return LayoutBuilder(
      builder: (context, constraints) {
        final d = math.min(constraints.maxWidth, widget.maxSize);
        return SizedBox(
          width: d,
          height: d,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: (_) => _onPanEnd(),
            onPanCancel: _onPanEnd,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SleepTimerDialPainter(
                      minutes: _visualMinutes,
                      accent: accent,
                      track: track,
                      labelColor: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _buildCenter(d, hours, minutes, scheme),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 中央：M3E 多边形（点击开始计时）+ 小时/分钟文字。
  ///
  /// 文字必须是真实 [Text]（不是 painter 画的字），否则无法断言且丢无障碍语义。
  Widget _buildCenter(double d, int hours, int minutes, ColorScheme scheme) {
    final shapeSize = d * _kShapeRadius * 2;
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: shapeSize,
      height: shapeSize,
      child: GestureDetector(
        onTap: widget.onStart,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: SleepTimerPolygonPainter(
                  hours: hours,
                  color: scheme.primaryContainer,
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$hours 小时',
                  style: textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '$minutes 分钟',
                  style: textTheme.labelMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// 以下比例均相对半径 R = 边长 / 2，与示意图一致。
const double _kLapRadius = 0.84;
const double _kRingRadius = 0.7467;
const double _kTickOuter = 0.72;
const double _kTickInnerMajor = 0.64;
const double _kTickInnerMinor = 0.68;
const double _kLabelRadius = 0.9067;
/// 中央形状的外接半径。
///
/// 从 0.3733 收到 0.34：圆的误触面积按平方缩减，0 小时（圆）再叠一层
/// [sleepTimerShapeScale] 的 0.86 补偿，整体误触面积降到原来的约 56%。
const double _kShapeRadius = 0.34;
const double _kKnobRadius = 0.0667;

/// 表盘底轨 / 圈数弧 / 分钟弧 / 刻度 / 指针。
class _SleepTimerDialPainter extends CustomPainter {
  const _SleepTimerDialPainter({
    required this.minutes,
    required this.accent,
    required this.track,
    required this.labelColor,
  });

  /// 小数分钟：拖动中要能停在任意角度，故不取整。
  final double minutes;
  final Color accent;
  final Color track;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2;
    final lapMinutes = minutes % 60;
    // 整点（如 2:00）把主弧画满，否则看不出已经走了 2 圈
    final ringSweep = (minutes >= 60 && lapMinutes < 1e-6) ? 60.0 : lapMinutes;

    _stroke(canvas, c, r * _kLapRadius, 3, track, null);
    if (minutes > 1e-9) {
      _stroke(
        canvas,
        c,
        r * _kLapRadius,
        3,
        accent.withValues(alpha: 0.5),
        (minutes / kSleepTimerMaxMinutes) * 60,
      );
    }
    _stroke(canvas, c, r * _kRingRadius, 8, track, null);
    if (ringSweep > 0) {
      _stroke(canvas, c, r * _kRingRadius, 8, accent, ringSweep);
    }

    _paintTicks(canvas, c, r);

    // 指针 + 端点旋钮
    final angle = -math.pi / 2 + (lapMinutes / 60) * 2 * math.pi;
    final outer = Offset.fromDirection(angle, r * _kRingRadius);
    final handPaint = Paint()
      ..color = accent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c + Offset.fromDirection(angle, r * 0.09), c + outer, handPaint);
    canvas.drawCircle(c + outer, r * _kKnobRadius, Paint()..color = accent);
  }

  /// [sweepMinutes] 为 null 时画整圈底轨，否则按 60 分钟制画弧。
  void _stroke(
    Canvas canvas,
    Offset c,
    double radius,
    double width,
    Color color,
    double? sweepMinutes,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(center: c, radius: radius);
    if (sweepMinutes == null) {
      canvas.drawCircle(c, radius, paint);
      return;
    }
    final sweep = (sweepMinutes / 60) * 2 * math.pi;
    if (sweep >= 2 * math.pi - 1e-6) {
      canvas.drawCircle(c, radius, paint);
      return;
    }
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint);
  }

  void _paintTicks(Canvas canvas, Offset c, double r) {
    final minor = Paint()
      ..color = track
      ..strokeWidth = 1;
    final major = Paint()
      ..color = labelColor.withValues(alpha: 0.6)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 60; i++) {
      final a = -math.pi / 2 + (i / 60) * 2 * math.pi;
      final isMajor = i % 5 == 0;
      final inner = r * (isMajor ? _kTickInnerMajor : _kTickInnerMinor);
      canvas.drawLine(
        c + Offset.fromDirection(a, inner),
        c + Offset.fromDirection(a, r * _kTickOuter),
        isMajor ? major : minor,
      );
      if (isMajor) _paintLabel(canvas, c + Offset.fromDirection(a, r * _kLabelRadius), '$i');
    }
  }

  void _paintLabel(Canvas canvas, Offset center, String text) {
    // 拖动时每帧都要画这 12 个刻度数字，缓存 TextPainter 避免每帧重排
    final key = '${text}_${labelColor.toARGB32()}';
    final painter = _labelCache.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: 11, color: labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(_SleepTimerDialPainter oldDelegate) =>
      oldDelegate.minutes != minutes ||
      oldDelegate.accent != accent ||
      oldDelegate.track != track ||
      oldDelegate.labelColor != labelColor;
}

/// 刻度数字的排版缓存，key 为 `文本_颜色`。
final Map<String, TextPainter> _labelCache = {};
