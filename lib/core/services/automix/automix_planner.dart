import 'dart:math' as math;

import 'automix_analysis.dart';

/// 变速倍率的可信区间（±6%）。超出就说明两首不是一个节拍体系，
/// 硬拉会让下一首明显变调/变慢，此时改为不变速的长淡化。
const double kAutomixMinRate = 0.94;
const double kAutomixMaxRate = 1.06;

/// 倍率与 1.0 的差小于此值时不动速度（避免无意义的 time-stretch 开销）。
const double kAutomixRateEpsilon = 0.005;

/// 淡化时长下限/上限（与 SettingsRepository 的 crossfade 区间保持一致）。
const int kAutomixMinFadeSeconds = 2;
const int kAutomixMaxFadeSeconds = 12;

/// 拍点吸附的最大搜索半径（半拍）。超过就说明附近没有可用拍点，不吸附。
const double kBeatSnapMaxRatio = 0.5;

enum AutomixStrategy {
  /// 节拍对齐 + 保音高变速：两首 BPM 接近，能做 DJ 式对拍。
  beatmatch,

  /// 只做淡化：BPM 差太大或响度差太大，变速/对拍都不合适。
  gradualBlend,

  /// 分析不可用：完全退回现有固定时长淡化。
  fallback,
}

class AutomixPlan {
  const AutomixPlan({
    required this.strategy,
    required this.fadeDuration,
    required this.fadeStartPosition,
    required this.incomingRate,
  });

  final AutomixStrategy strategy;
  final Duration fadeDuration;

  /// 当前歌曲的**绝对位置**：到这个点才开始淡化（拍点吸附后的结果）。
  final Duration fadeStartPosition;

  /// 下一首的播放速率（1.0 = 不变速）。由 ExoPlayer 的 Sonic 保音高实现。
  final double incomingRate;
}

/// 规划一次 AutoMix 过渡。
///
/// 纯函数、无副作用，便于单测（与 `decideCrossfadePhase` 同风格）。
/// 任何一步拿不到可靠信息就降级，绝不返回会让播放错乱的参数：
/// - 分析缺失/置信度不足 → [AutomixStrategy.fallback]；
/// - BPM 差超出 ±6% → 钳位 + 降级为 [AutomixStrategy.gradualBlend]；
/// - 拍点吸附不到 → 用未吸附的理想起点。
AutomixPlan planAutomix({
  required AutomixAnalysis? outgoing,
  required AutomixAnalysis? incoming,
  required Duration position,
  required Duration? duration,
  required Duration userFade,
}) {
  final baseFade = userFade;
  if (duration == null || duration <= Duration.zero) {
    // 时长未知：无法定位尾部。起点 = 当前位置，即"立刻按用户时长淡"，
    // 由上层的时间轴判断（decideCrossfadePhase 在 duration 为空时本来就返回 idle）
    // 兜住，这里只保证不产生未来或负的起点。
    return AutomixPlan(
      strategy: AutomixStrategy.fallback,
      fadeDuration: baseFade,
      fadeStartPosition: position,
      incomingRate: 1.0,
    );
  }

  final idealStart = duration - baseFade;
  if (outgoing == null || incoming == null || !outgoing.usable || !incoming.usable) {
    return AutomixPlan(
      strategy: AutomixStrategy.fallback,
      fadeDuration: baseFade,
      fadeStartPosition: idealStart,
      incomingRate: 1.0,
    );
  }

  // —— 1. 变速倍率 ——
  //
  // 「是否算对拍成功」的判据是**两首 BPM 是否落在同一节拍体系内（±6%）**，
  // 而**不是**「是否需要变速」。二者会在一种常见情形下分叉：两首 BPM 几乎相同
  // （差 <0.5%）时不变速，但拍点对齐依然完全有效 —— 早期版本用 `rate != 1.0`
  // 判定，把这种情况误判成 gradualBlend（真机实测：119.8 → 120.4 差 0.5%，
  // 日志显示 gradualBlend rate=1.000，看起来像对拍没生效）。
  final rawRate = outgoing.bpm / incoming.bpm;
  final withinBeatRange = (rawRate - 1.0).abs() <= (kAutomixMaxRate - 1.0);
  var rate = rawRate.clamp(kAutomixMinRate, kAutomixMaxRate);
  // 差得太小就不值得动速度（省掉无意义的 time-stretch），但仍按对拍处理
  if ((rate - 1.0).abs() < kAutomixRateEpsilon) rate = 1.0;
  final tempoMatched = withinBeatRange;

  // —— 2. 自适应时长（只缩短，不延长）——
  //
  // 为什么不能延长：`decideCrossfadePhase` 以**用户设置的时长**判定起淡时刻，
  // 而起淡闸门只能把起淡点**往后推**、不能往前拉。若 plan 的淡化比用户时长更长
  // （例如默认 4s 被延长到 5s），相位判定会在 remaining≤4s 才放行，此时斜坡
  // 只剩 4s 可走 —— 淡化在曲尾被截断，音量停在半路突然切歌。
  // 因此用户设置的时长即上限，AutoMix 只在「节奏太密」时缩短，避免糊成一团。
  final density = math.max(outgoing.rhythmDensity, incoming.rhythmDensity);
  final scale = density > 0.65
      ? 0.5
      : density > 0.5
          ? 0.7
          : 1.0;
  var fadeSeconds = (baseFade.inSeconds * scale).round();
  fadeSeconds = fadeSeconds.clamp(kAutomixMinFadeSeconds, kAutomixMaxFadeSeconds).toInt();
  // 硬上限：任何时候不超过用户设置（上面 scale ≤ 1.0 已保证，这里是兜底）
  if (fadeSeconds > baseFade.inSeconds) fadeSeconds = baseFade.inSeconds;
  // 不超过曲长的 1/3，避免短歌被淡化吃掉大半
  final maxByDuration = duration.inSeconds ~/ 3;
  if (maxByDuration >= kAutomixMinFadeSeconds && fadeSeconds > maxByDuration) {
    fadeSeconds = maxByDuration;
  }
  final fade = Duration(seconds: fadeSeconds);

  // —— 3. 拍点吸附 ——
  final ideal = duration - fade;
  var start = ideal;
  final beatPeriod = 60.0 / outgoing.bpm;
  if (beatPeriod.isFinite && beatPeriod > 0 && ideal.inMicroseconds > 0) {
    final idealSec = ideal.inMicroseconds / 1e6;
    final offset = (idealSec - outgoing.firstBeatSec) / beatPeriod;
    final nearest = outgoing.firstBeatSec + offset.round() * beatPeriod;
    final deltaSec = (nearest - idealSec).abs();
    if (deltaSec <= beatPeriod * kBeatSnapMaxRatio) {
      final snapped = Duration(microseconds: (nearest * 1e6).round());
      // 不能早于当前位置（否则下一 tick 立刻起淡，等于没吸附）；
      // 也不能晚到曲子都快结束了才起淡。
      final latest = duration - Duration(milliseconds: 500);
      if (snapped >= position && snapped <= latest) start = snapped;
    }
  }

  // —— 4. 策略 ——
  final loudnessGap = (outgoing.loudnessDbfs - incoming.loudnessDbfs).abs();
  final strategy = tempoMatched && loudnessGap <= 6.0
      ? AutomixStrategy.beatmatch
      : AutomixStrategy.gradualBlend;

  return AutomixPlan(
    strategy: strategy,
    fadeDuration: fade,
    fadeStartPosition: start,
    incomingRate: strategy == AutomixStrategy.beatmatch ? rate : 1.0,
  );
}
