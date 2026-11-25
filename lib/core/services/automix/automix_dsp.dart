import 'dart:math' as math;

/// 能量差分（onset）包络的窗口/跳距按**时间**而非固定样本数计算，
/// 使 44.1k / 48k 等不同采样率下的帧率一致（≈43.5 fps，与 infplayer 的
/// 48k/1024 ≈ 46.9fps 同量级）。
const double kOnsetWindowMs = 46.0;
const double kOnsetHopMs = 23.0;

/// onset 包络的帧率（帧/秒）。拍点/BPM 换算都基于它。
double envFrameRate({required int sampleRate}) {
  final hop = (sampleRate * kOnsetHopMs / 1000).round();
  return sampleRate / (hop <= 0 ? 1 : hop);
}

/// 半波整流的能量差分 onset 包络。
///
/// 1. 逐帧（win=[kOnsetWindowMs]）算 RMS 能量；
/// 2. 与前一帧取正向差分（只保留"变响"的部分，即起音）；
/// 3. 一阶 EMA([smoothing]) 平滑，压掉单帧抖动。
///
/// 返回长度 = (pcm.length - win) ~/ hop + 1；样本不足一帧时返回空列表。
List<double> onsetEnvelope(
  List<int> pcm, {
  required int sampleRate,
  double smoothing = 0.8,
}) {
  final win = (sampleRate * kOnsetWindowMs / 1000).round();
  final hop = (sampleRate * kOnsetHopMs / 1000).round();
  if (win <= 0 || hop <= 0 || pcm.length < win) return const <double>[];
  final frames = <double>[];
  var prev = 0.0;
  for (var i = 0; i + win <= pcm.length; i += hop) {
    var sum = 0.0;
    for (var k = 0; k < win; k++) {
      final v = pcm[i + k] / 32768.0;
      sum += v * v;
    }
    final energy = sum / win;
    frames.add(energy > prev ? energy - prev : 0.0);
    prev = energy;
  }
  // 从第 0 帧开始平滑：第 0 帧的差分基准是 prev=0，若跳过它，它会保留未平滑的
  // 原始尖峰（约为后续帧的 1/(1-smoothing) 倍），污染后续按峰值相对阈值的判定。
  var smoothed = 0.0;
  for (var i = 0; i < frames.length; i++) {
    smoothed = smoothed * smoothing + frames[i] * (1 - smoothing);
    frames[i] = smoothed;
  }
  return frames;
}

/// BPM 搜索下限/上限（拍点 lag 区间由它换算）。
const double kMinBpm = 60.0;
const double kMaxBpm = 180.0;

/// 倍频（sub-harmonic）抑制阈值，见 [detectBpm] 中 lag 的选择规则。
const double kSubHarmonicRatio = 0.90;

/// 八度归一的目标区间：低于 70 倍增、高于 180 倍降，
/// 修掉自相关落在倍频/半频上的常见错误（infplayer 只在 60–180 内搜，
/// 仍会有 60 与 120 这类歧义，这里补一道折叠）。
double normalizeBpm(double bpm) {
  if (!bpm.isFinite || bpm <= 0) return 0;
  var v = bpm;
  while (v < 70) {
    v *= 2;
  }
  while (v > 180) {
    v /= 2;
  }
  return v;
}

/// 归一化自相关测 BPM。
///
/// 在 [kMinBpm, kMaxBpm] 对应的 lag 区间内取归一化自相关最大值，
/// 再对峰值做抛物线插值提升分辨率（43fps 下 ±1 帧 ≈ ±5% BPM，
/// 不插值的话 beat-match 的变速量会被这个误差吃掉）。
///
/// [confidence] 即归一化自相关的峰值（0..1），低于
/// [AutomixAnalysis.kMinConfidence] 视为没测出稳定节拍。
({double bpm, double confidence}) detectBpm(
  List<double> env, {
  required double frameRate,
}) {
  if (env.length < 8 || frameRate <= 0) return (bpm: 0, confidence: 0);
  final minLag = (frameRate * 60.0 / kMaxBpm).floor();
  final maxLag = (frameRate * 60.0 / kMinBpm).ceil();
  final lo = minLag < 1 ? 1 : minLag;
  final hi = maxLag < env.length ? maxLag : env.length - 1;
  if (hi < lo) return (bpm: 0, confidence: 0);

  final scores = List<double>.filled(hi + 2, 0.0);
  var bestLag = lo;
  var bestScore = -1.0;
  for (var lag = lo; lag <= hi; lag++) {
    var dot = 0.0;
    var aa = 0.0;
    var bb = 0.0;
    for (var i = lag; i < env.length; i++) {
      final x = env[i];
      final y = env[i - lag];
      dot += x * y;
      aa += x * x;
      bb += y * y;
    }
    final denom = math.sqrt(aa * bb);
    final score = denom <= 0 ? 0.0 : dot / denom;
    scores[lag] = score;
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }
  if (!bestScore.isFinite || bestScore <= 0) {
    return (bpm: 0, confidence: 0);
  }

  // 自相关对"周期的整数倍"同样给出高值，而短 lag 端每差一帧对应的 BPM 跨度
  // 更大（43fps 下 lag≈17 时 ±1 帧 ≈ ±9 BPM），真值峰常常比它的 2 倍 lag
  // 峰低一点而被漏掉（实测 150BPM 会判成 74.8）。因此在所有达到全局峰值
  // [kSubHarmonicRatio] 的局部极大值里取**最小**的 lag。
  var pickLag = bestLag;
  var pickScore = bestScore;
  final threshold = bestScore * kSubHarmonicRatio;
  for (var lag = lo; lag <= hi; lag++) {
    final s = scores[lag];
    if (s < threshold) continue;
    if (lag > lo && scores[lag - 1] > s) continue;
    if (lag < hi && scores[lag + 1] > s) continue;
    pickLag = lag;
    pickScore = s;
    break;
  }

  // 抛物线插值：邻近三点拟合峰值的小数偏移
  var lagF = pickLag.toDouble();
  if (pickLag > lo && pickLag < hi) {
    final y0 = scores[pickLag - 1];
    final y1 = scores[pickLag];
    final y2 = scores[pickLag + 1];
    final denom = y0 - 2 * y1 + y2;
    if (denom.abs() > 1e-12) {
      final delta = 0.5 * (y0 - y2) / denom;
      if (delta.isFinite && delta.abs() <= 1.0) lagF = pickLag + delta;
    }
  }
  return (bpm: normalizeBpm(60.0 * frameRate / lagF), confidence: pickScore);
}

/// 首拍（第一个显著 onset）的秒偏移。
///
/// 取包络中第一个"局部极大且超过峰值 [thresholdRatio]"的帧。第 0 帧要单独
/// 参与判定：click track 的首拍就落在第 0 帧，它只有右邻居，若从 i=1 起扫会漏掉
/// 整轨首拍而误报成第二拍（120BPM @48k 实测会返回 0.48s）。
double firstOnsetSec(
  List<double> env,
  double frameRate, {
  double thresholdRatio = 0.3,
}) {
  if (env.length < 2 || frameRate <= 0) return 0;
  var maxV = 0.0;
  for (final v in env) {
    if (v > maxV) maxV = v;
  }
  if (maxV <= 0) return 0;
  final thr = maxV * thresholdRatio;
  if (env[0] >= env[1] && env[0] > thr) return 0;
  for (var i = 1; i < env.length - 1; i++) {
    if (env[i] > env[i - 1] && env[i] >= env[i + 1] && env[i] > thr) {
      return i / frameRate;
    }
  }
  return 0;
}

/// 拍点网格（秒）：从 [firstBeatSec] 起按 60/bpm 外推到 [untilSec]。
///
/// 曲速恒定时成立；曲速变化的曲子拍点会漂，规划层对这种情况走回退（见 Task 9）。
List<double> buildBeatGrid({
  required double firstBeatSec,
  required double bpm,
  required double untilSec,
  int maxPoints = 4096,
}) {
  if (!bpm.isFinite || bpm <= 0) return const <double>[];
  final step = 60.0 / bpm;
  if (!step.isFinite || step <= 0) return const <double>[];
  final grid = <double>[];
  var t = firstBeatSec < 0 ? 0.0 : firstBeatSec;
  while (t <= untilSec && grid.length < maxPoints) {
    grid.add(t);
    t += step;
  }
  return grid;
}

/// 节奏复杂度：8 onsets/秒 记满 1.0（mlaass/automix 的 complexity 简化版）。
double rhythmDensity(int onsetCount, double seconds) {
  if (seconds <= 0) return 0;
  return (onsetCount / seconds / 8.0).clamp(0.0, 1.0);
}

/// 窗口内 RMS 的 [percentile] 分位换算 dBFS（infplayer loudness.js 的简化版：
/// 取分位而非最大值，避免被单个瞬态峰值拉低整轨增益）。
///
/// 归一化除数取 32768.0（不是 32767）：Int16 的负半轴到 -32768，用 32768 才是
/// 满幅正弦 RMS=1/√2 → -3.01 dBFS 的理论值。
double loudnessDbfs(
  List<int> pcm, {
  double percentile = 0.9,
  int step = 2048,
}) {
  if (pcm.isEmpty || step <= 0) return -120;
  final vals = <double>[];
  for (var i = 0; i + step <= pcm.length; i += step) {
    var s = 0.0;
    for (var k = 0; k < step; k++) {
      final v = pcm[i + k] / 32768.0;
      s += v * v;
    }
    vals.add(math.sqrt(s / step));
  }
  if (vals.isEmpty) {
    // 不足一窗：按整段算
    var s = 0.0;
    for (final v in pcm) {
      final x = v / 32768.0;
      s += x * x;
    }
    return _toDb(math.sqrt(s / pcm.length));
  }
  vals.sort();
  final idx = (vals.length * percentile).floor().clamp(0, vals.length - 1);
  return _toDb(vals[idx]);
}

double _toDb(double rms) {
  if (rms <= 0) return -120;
  return (20 * math.log(rms) / math.log(10)).clamp(-120.0, 0.0);
}
