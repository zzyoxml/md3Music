/// myune「扫光（sweep）」字内渐变模型的纯函数移植。
///
/// 与本仓原有 classic（「字内渐变」：行内累计宽度 `maskX` + 固定过渡半宽）**并存**，
/// 由 `LyricPreferences.fillMode` 二选一，默认 sweep（扫光）。
///
/// 移植来源（只读参考 `myune_music_android-main`）：
/// - `lib/widgets/karaoke_sweep_path.dart:6-17`  → [sweepFeather]（karaokeSweepFeather）
/// - `lib/widgets/karaoke_sweep_path.dart:22-51` → [LyricSweepPath] 的区间过滤/合并与总长
/// - `lib/widgets/karaoke_sweep_path.dart:72-93` → [LyricSweepPath.frontX]（frontAt）
/// - `shaders/karaoke_ink.frag:43-44`            → [sweepRampFor]：myune 在 shader 里逐像素算
///   `highlight = clamp((uFront - point.x) * uDirection / max(uFeather, 1.0) + 0.5, 0, 1)`，
///   本仓走 canvas 线性渐变，故等价成一段 **4 停等阶带**：带内两停同色（active）、
///   带外两停同色（inactive），带内即 myune 的线性斜坡。
///
/// 本文件只依赖 `dart:ui`（[Color] / [Rect]），不含任何 Flutter widget 依赖，
/// 便于单测与真机调参。
library;

import 'dart:math' as math;
import 'dart:ui';

/// 扫光模型全部可调常量（集中一处，便于真机调参）。
///
/// 每个常量的来源函数见字段注释；改这里等于改扫光观感，classic 不受影响。
class LyricSweepTuning {
  LyricSweepTuning._();

  /// 羽化基线 = 行高（`fontSize × rowHeightFactor`）的该比例。
  /// 来源：myune `karaokeFeatherWidth()`（行高 × highlightFeatherFraction）。
  static const double featherBaselineFactor = 0.72;

  /// 羽化基线钳制下限（px）。来源：myune `karaokeFeatherWidth()` clamp(12, 18)。
  static const double featherBaselineMin = 12;

  /// 羽化基线钳制上限（px）。来源：myune `karaokeFeatherWidth()` clamp(12, 18)。
  static const double featherBaselineMax = 18;

  /// 慢字羽化系数：`wordWidth × 该值`。来源：myune `karaokeSweepFeather` 的 `width * .22`。
  static const double slowWidthFactor = 0.22;

  /// 慢字羽化下限（px）。来源：myune `karaokeSweepFeather` 的 clamp 下界 4.0。
  static const double slowMin = 4.0;

  /// 慢字羽化上限（px）。来源：myune `karaokeSweepFeather` 的 `math.min(8.0, baseline)`。
  static const double slowMax = 8.0;

  /// 速度映射下界（px/s）：<= 该速度视为最慢（取 slow）。
  /// 来源：myune `karaokeSweepFeather` 的 `((speed - 12) / 36)`。
  static const double speedLow = 12;

  /// 速度映射上界（px/s）：>= 该速度视为最快（取 baseline）。
  static const double speedHigh = 48;

  /// 结果钳制下界系数：`fontSize × 该值`。
  /// 来源：任务规格（防止极小字号下羽化退化为 0）。
  static const double resultMinFactor = 0.12;

  /// 结果钳制上界系数：`fontSize × 该值`。
  /// 来源：任务规格（防止大字重下过渡带糊掉整行）。
  static const double resultMaxFactor = 1.20;
}

/// 行内墨迹区间（行内 x 坐标，已排除字间空白）。
///
/// 构造参数为位置参数：`LyricInkSpan(start, end)`。
class LyricInkSpan {
  const LyricInkSpan(this.start, this.end);

  /// 区间起点（行内累计 x）。
  final double start;

  /// 区间终点（行内累计 x，不含）。
  final double end;

  @override
  String toString() => 'LyricInkSpan($start, $end)';
}

/// 扫光前端沿「墨迹长度」推进的路径。
///
/// 与 myune `KaraokeSweepPath` 一致：
/// 1. 构造时过滤非有限值 / `end <= start` 的区间，按 `start` 升序排序；
/// 2. 重叠或相接（`span.start <= last.end`）的区间合并；
/// 3. [totalInk] = 合并后各段长度之和（字间空白不计入）；
/// 4. [frontX] 按累计墨迹长度定位前端，**间隙处瞬时跨越**（不占推进距离）。
///
/// 一个实例建好即不可变，可在行绑定期构造一次后每帧复用。
class LyricSweepPath {
  LyricSweepPath(List<LyricInkSpan> spans) {
    final List<LyricInkSpan> ordered =
        spans
            .where(
              (s) =>
                  s.start.isFinite && s.end.isFinite && s.end > s.start,
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    // 合并重叠 / 相接区间（myune :29-40）；相接合并避免出现零宽间隙。
    final List<LyricInkSpan> merged = <LyricInkSpan>[];
    for (final span in ordered) {
      if (merged.isNotEmpty && span.start <= merged.last.end) {
        final LyricInkSpan previous = merged.removeLast();
        merged.add(LyricInkSpan(previous.start, math.max(previous.end, span.end)));
      } else {
        merged.add(span);
      }
    }
    _starts = List<double>.filled(merged.length, 0);
    _ends = List<double>.filled(merged.length, 0);
    _inkEnds = List<double>.filled(merged.length, 0);
    double advance = 0;
    for (int i = 0; i < merged.length; i++) {
      advance += merged[i].end - merged[i].start;
      _starts[i] = merged[i].start;
      _ends[i] = merged[i].end;
      _inkEnds[i] = advance;
    }
    _totalInk = advance;
  }

  late final List<double> _starts;
  late final List<double> _ends;

  /// 第 i 段结束时的累计墨迹长度（含第 i 段）。
  late final List<double> _inkEnds;
  late final double _totalInk;

  /// 是否没有任何有效墨迹区间（空输入 / 全被过滤）。
  bool get isEmpty => _starts.isEmpty;

  /// 合并后墨迹总长（px）。字间空白不计入。
  double get totalInk => _totalInk;

  /// 合并后的区间数量（供测试断言）。
  int get spanCount => _starts.length;

  /// `phase ∈ [0,1]` → 行内 x 坐标。
  ///
  /// 前端行程域是 `[-feather/2, totalInk + feather/2]`（myune :72-93）：
  /// 保证扫光带（宽 = feather）在首尾能完整进出画面，起唱瞬间不会「凭空半亮」。
  /// - `phase = 0` → 首段起点之前 `feather/2`；
  /// - `phase = 1` → 末段终点之后 `feather/2`；
  /// - 中间按累计墨迹长度二分定位所在段，间隙处瞬时跨越；
  /// - [rtl] 为 true 时相位反向（从行尾向行首推进）；
  /// - 空输入返回 0。
  double frontX(double phase, {required double feather, bool rtl = false}) {
    if (_starts.isEmpty) return 0;
    final double directionPhase = (rtl ? 1.0 - phase : phase)
        .clamp(0.0, 1.0)
        .toDouble();
    final double f = feather.isFinite ? feather : 0.0;
    final double distance = (_totalInk + f) * directionPhase - f / 2;
    if (distance <= 0) return _starts.first + distance;
    if (distance >= _totalInk) {
      return _ends.last + distance - _totalInk;
    }
    // 二分：找第一个「累计墨迹长度 > distance」的段（与 myune 同式）。
    int low = 0;
    int high = _starts.length - 1;
    while (low < high) {
      final int mid = (low + high) >> 1;
      if (distance >= _inkEnds[mid]) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final double previous = low == 0 ? 0.0 : _inkEnds[low - 1];
    return _starts[low] + distance - previous;
  }
}

/// myune `karaokeSweepFeather` 的等价移植（单位 px）。
///
/// 语义：**按字宽 + 时长的自适应羽化**——慢/短音节收窄过渡带（边缘更锐利、
/// 更贴近「扫光」观感），快字放宽到基线以保证过渡可见。
///
/// 公式（myune `karaoke_sweep_path.dart:6-17`）：
/// ```
/// baseline = (fontSize * rowHeightFactor * featherBaselineFactor).clamp(12, 18)
/// slow     = (wordWidth * slowWidthFactor).clamp(4.0, min(8.0, baseline))
/// speed    = (wordWidth + baseline) * 1e6 / wordDurationUs
/// t        = ((speed - speedLow) / (speedHigh - speedLow)).clamp(0, 1)
/// feather  = slow + (baseline - slow) * (t*t*(3-2t))
/// ```
/// 结果再 `.clamp(fontSize * resultMinFactor, fontSize * resultMaxFactor)`。
///
/// 边界守卫（myune :11）：`wordWidth` 非有限或 `<= 0`、时长 `<= 0` 时
/// **直接返回基线**，绝不返回 0 / NaN。
double sweepFeather({
  required double fontSize,
  required double rowHeightFactor,
  required double wordWidth,
  required Duration wordDuration,
}) {
  final double baseline = (fontSize * rowHeightFactor *
          LyricSweepTuning.featherBaselineFactor)
      .clamp(
        LyricSweepTuning.featherBaselineMin,
        LyricSweepTuning.featherBaselineMax,
      )
      .toDouble();
  final double durationUs = wordDuration.inMicroseconds.toDouble();
  if (!wordWidth.isFinite ||
      wordWidth <= 0 ||
      !durationUs.isFinite ||
      durationUs <= 0) {
    return baseline;
  }
  final double slow = (wordWidth * LyricSweepTuning.slowWidthFactor)
      .clamp(
        LyricSweepTuning.slowMin,
        math.min(LyricSweepTuning.slowMax, baseline),
      )
      .toDouble();
  final double speed = (wordWidth + baseline) * 1000000 / durationUs;
  final double t =
      ((speed - LyricSweepTuning.speedLow) /
              (LyricSweepTuning.speedHigh - LyricSweepTuning.speedLow))
          .clamp(0.0, 1.0)
          .toDouble();
  final double blend = t * t * (3 - 2 * t); // smoothstep
  final double feather = slow + (baseline - slow) * blend;
  final double lower = fontSize * LyricSweepTuning.resultMinFactor;
  final double upper = fontSize * LyricSweepTuning.resultMaxFactor;
  return feather.clamp(lower, upper).toDouble();
}

/// 单点采样 myune shader 的逐像素公式（`dart:ui` 侧的等价形式）。
///
/// `highlight = clamp((front - x) * (rtl ? -1 : 1) / max(feather, 1) + 0.5, 0, 1)`，
/// 用于逐字符路径的「均匀色」采样（无可见过渡带时的回退值）。
double sweepAlphaAt(double front, double feather, double x, {bool rtl = false}) {
  if (!front.isFinite || !x.isFinite) return 0;
  final double f = (!feather.isFinite || feather < 1.0) ? 1.0 : feather;
  final double direction = rtl ? -1.0 : 1.0;
  return ((front - x) * direction / f + 0.5).clamp(0.0, 1.0).toDouble();
}

/// 4 停渐变（等价 myune 的逐像素 clamp 斜坡）。
///
/// `t0 = (front - feather/2 - rect.left) / rect.width`，
/// `t1 = (front + feather/2 - rect.left) / rect.width`，
/// `stops = [0, clamp01(t0), clamp01(t1), 1]`，
/// `colors = [active, active, inactive, inactive]`。
///
/// [rtl] 为 true 时以 `rect.right` 为基准镜像：一维线性渐变下镜像等价于
/// **停点不变、颜色序列反转**（`[inactive, inactive, active, active]`），
/// 即已播区从右侧进入。
///
/// 退化（返回 `null`，调用方走均匀色、零 saveLayer）：
/// - `rect.width` 非有限或 `<= 0`；
/// - `front` / `feather` 非有限，或 `feather <= 0`；
/// - 整段矩形完全落在已播侧（`t1 <= 0`）或未播侧（`t0 >= 1`）——无可见过渡带。
///
/// 注意：[front] 必须与 [rect] 处于**同一坐标系**（canvas 坐标）。
({List<double> stops, List<Color> colors})? sweepRampFor({
  required Rect rect,
  required double front,
  required double feather,
  required Color active,
  required Color inactive,
  required bool rtl,
}) {
  if (!rect.width.isFinite || rect.width <= 0) return null;
  if (!front.isFinite || !feather.isFinite || feather <= 0) return null;
  final double half = feather / 2;
  final double t0 = ((front - half) - rect.left) / rect.width;
  final double t1 = ((front + half) - rect.left) / rect.width;
  if (!t0.isFinite || !t1.isFinite) return null;
  if (t1 <= 0 || t0 >= 1) return null;
  final List<Color> colors = rtl
      ? <Color>[inactive, inactive, active, active]
      : <Color>[active, active, inactive, inactive];
  return (
    stops: <double>[
      0.0,
      t0.clamp(0.0, 1.0).toDouble(),
      t1.clamp(0.0, 1.0).toDouble(),
      1.0,
    ],
    colors: colors,
  );
}
