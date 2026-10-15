import 'dart:math' as math;

/// 谱流量 onset（瞬态）检测器。**纯 Dart、零 Flutter 依赖**，可被 `flutter test` 直接覆盖。
///
/// 输入是一路**能量标量**的时间序列（低频带能量判 kick、高频带能量判 snare），
/// 输出是"这一帧是不是一个瞬态"。
///
/// **为什么不是 BPM 追踪**：BPM/拍点需要秒级 lookahead 才能确定，而震动只需要
/// 踩在瞬态上。用户要的是"打在鼓点上"，而鼓点本身就是最强的瞬态。
///
/// 算法是通用谱流量法（正向差分 → 平方 → 平滑 → 自适应阈值 → 上升沿触发 → 冷却）：
///
/// - **只保留上升沿并平方**：把幅度转成能量，放大尖锐瞬态、压制小噪声。
/// - **一阶平滑**：单帧噪声不足以把阈值拉起来。
/// - **EMA 均值 + 标准差的自适应阈值**：古典乐与电子乐的动态范围差几个数量级，
///   固定阈值不可能通用。
/// - **上升沿立即触发（不再做真峰确认）**：旧实现要求 flux 为三帧局部极大，
///   天然晚 1~2 帧（45~200ms），是"震动迟于拍点"的最大单项。去重由
///   冷却 + 阈值掩码承担：hump 后续帧被掩码压住，跨 hump 被冷却压住。
/// - **包络跟随器（[envelopeDecay]）**：触发后把阈值抬到本次流量的 70%。
///   衰减**按真实 dt 折算**（`0.95^(dt/refHopMs)`），帧率变化时行为不变。
/// - **相对噪声门（[relativeGate]）**：flux 还须超过 EMA 均值的 [relativeGate] 倍。
///   特征是未归一化 FFT 幅度（真机量纲几十），绝对门在响歌上形同虚设、
///   在安静段又过紧；"上升量 ≥ 平均上升量的一半"是尺度无关的。
/// - **冷却时间**：马达有机械恢复时间，高频触发会进入嗡鸣状态且明显发热。
///
/// 状态全部是标量，无分配、无定时器，可在特征流的回调里直接跑。
class MusicOnsetDetector {
  MusicOnsetDetector({
    this.sensitivity = 1.0,
    this.cooldown = const Duration(milliseconds: 130),
    this.noiseGate = 0.015,
    this.relativeGate = 0.5,
    this.envelopeDecay = 0.95,
    this.fluxSmoothing = 0.3,
    this.statisticsAlpha = 0.02,
    this.minStdDev = 0.005,
  });

  /// 灵敏度，越大越容易触发。
  ///
  /// 阈值 = `emaMean + thresholdMultiplier * stdDev`，而
  /// [thresholdMultiplier] = `1.5 / sensitivity` 并夹在 `[0.5, 4.0]`。
  double sensitivity;

  /// 两次触发之间的最小间隔。低于 130ms 时马达开始发糊并升温。
  Duration cooldown;

  /// 谱流量绝对值下限：低于它的"上升"一律当噪声。与 [relativeGate] 取交集。
  double noiseGate;

  /// 相对噪声门：flux 必须超过 `emaMean × relativeGate` 才允许触发。
  /// 尺度无关的背景抑制——EMA 均值为 0（冷启动）时本门自动失效。
  final double relativeGate;

  /// 包络跟随器的每帧衰减系数（按 [refHopMs] 的真实 dt 折算）。
  final double envelopeDecay;

  /// 谱流量的一阶平滑系数（保留多少上一帧的值）。
  final double fluxSmoothing;

  /// EMA 统计量的更新速率；越小越"迟钝"，对长期动态的适应越慢。
  final double statisticsAlpha;

  /// 标准差下限，防止阈值在绝对安静时塌到 0。
  final double minStdDev;

  /// 掩码衰减的参考帧间隔（毫秒）：`envelopeDecay^(dt/refHopMs)`。
  /// 45ms 是特征流的历史标称帧率，改它等于整体加快/放慢掩码回落。
  static const double refHopMs = 45.0;

  /// 自适应阈值里的标准差倍数，由 [sensitivity] 推导并夹在 `[0.5, 4.0]`。
  double get thresholdMultiplier =>
      (1.5 / math.max(0.1, sensitivity)).clamp(0.5, 4.0);

  /// 最近一次 [process] 用到的自适应阈值（供设置页状态行展示与排障）。
  double get lastThreshold => _lastThreshold;
  double _lastThreshold = 0;

  double _emaMean = 0;
  double _emaVariance = 0;

  /// 当前帧的平滑谱流量 —— 上升沿判定用的就是它，不保留历史帧。
  double _flux0 = 0;

  double _thresholdMask = 0;
  double _prevEnergy = 0;
  bool _hasPrev = false;
  Duration _lastNow = Duration.zero;

  /// null 表示"从未触发过"——用 0 会让冷却在时钟原点附近误判为"还在冷却"。
  Duration? _lastTrigger;

  /// 喂入一帧能量，返回本帧是否判定为一个瞬态。
  ///
  /// [now] 由调用方注入（单调时钟）。**帧间隔可以不均匀**：掩码衰减按
  /// 真实 dt 折算，冷却用真实时钟——帧率无关。
  bool process(double energy, Duration now) {
    if (!_hasPrev) {
      _prevEnergy = energy;
      _hasPrev = true;
      _lastNow = now;
      return false;
    }
    final dtMs = (now - _lastNow).inMilliseconds.toDouble();
    _lastNow = now;

    final diff = energy - _prevEnergy;
    _prevEnergy = energy;

    // 只保留上升沿，平方转能量域
    final rawFlux = diff > 0 ? diff * diff : 0.0;
    final smoothed = rawFlux * (1 - fluxSmoothing) + _flux0 * fluxSmoothing;

    _flux0 = smoothed;

    // 自适应阈值：均值 + k·标准差，再与包络跟随器取大
    final stdDev = math.max(minStdDev, math.sqrt(_emaVariance));
    final threshold = math.max(
      _emaMean + thresholdMultiplier * stdDev,
      _thresholdMask,
    );
    _lastThreshold = threshold;

    // 上升沿立即触发：本帧 flux 过阈值就点火，不等"确认是局部极大"
    final aboveThreshold = _flux0 > threshold &&
        _flux0 > noiseGate &&
        _flux0 > relativeGate * _emaMean;
    final last = _lastTrigger;
    final cooldownPassed = last == null || (now - last) >= cooldown;

    final triggered = aboveThreshold && cooldownPassed;
    if (triggered) {
      _lastTrigger = now;
      _thresholdMask = _flux0 * 0.7;
    } else {
      // 帧率无关的掩码回落：真实时间每过 refHopMs 衰减一次 envelopeDecay
      _thresholdMask *= math.pow(envelopeDecay, dtMs / refHopMs);
    }

    // EMA 统计放在最后：本帧的统计量不该反过来影响本帧的阈值判定
    final delta = _flux0 - _emaMean;
    _emaMean += statisticsAlpha * delta;
    _emaVariance =
        (1 - statisticsAlpha) * (_emaVariance + statisticsAlpha * delta * delta);

    return triggered;
  }

  /// 清空全部状态。切歌、数据源重建、重新开启功能时必须调用：
  /// 残留的均值/方差会让新歌的前几秒阈值偏高或偏低。
  void reset() {
    _emaMean = 0;
    _emaVariance = 0;
    _flux0 = 0;
    _thresholdMask = 0;
    _prevEnergy = 0;
    _hasPrev = false;
    _lastNow = Duration.zero;
    _lastTrigger = null;
    _lastThreshold = 0;
  }
}