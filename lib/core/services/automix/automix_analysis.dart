/// AutoMix 的单曲分析结果（来自曲首 [windowMs] 的解码窗口）。
///
/// BPM 是整曲属性，只分析曲首即可；拍点网格由 [firstBeatSec] + 60/bpm 外推，
/// 与 infplayer `bpm.js` 的做法一致（曲速恒定时成立）。
class AutomixAnalysis {
  const AutomixAnalysis({
    required this.key,
    required this.bpm,
    required this.confidence,
    required this.firstBeatSec,
    required this.rhythmDensity,
    required this.loudnessDbfs,
    required this.windowMs,
    required this.analyzedAtMs,
  });

  /// 缓存键：`songId|urlHash`（见 automix_analyzer.dart 的 buildAutomixKey）。
  final String key;
  final double bpm;
  final double confidence;

  /// 曲首第一个 onset 的秒偏移，拍点网格的起点。
  final double firstBeatSec;

  /// 节奏复杂度 0..1（8 onsets/s 记满），用于自适应淡化时长。
  final double rhythmDensity;

  /// 窗口内 RMS 90 分位换算的 dBFS。
  final double loudnessDbfs;
  final int windowMs;
  final int analyzedAtMs;

  /// 自相关峰值低于此值视为「没测出稳定节拍」，规划时回退。
  static const double kMinConfidence = 0.35;

  bool get usable =>
      bpm > 0 &&
      bpm.isFinite &&
      confidence >= kMinConfidence &&
      firstBeatSec.isFinite;

  AutomixAnalysis copyWith({double? bpm, double? confidence}) =>
      AutomixAnalysis(
        key: key,
        bpm: bpm ?? this.bpm,
        confidence: confidence ?? this.confidence,
        firstBeatSec: firstBeatSec,
        rhythmDensity: rhythmDensity,
        loudnessDbfs: loudnessDbfs,
        windowMs: windowMs,
        analyzedAtMs: analyzedAtMs,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'bpm': bpm,
        'confidence': confidence,
        'firstBeatSec': firstBeatSec,
        'rhythmDensity': rhythmDensity,
        'loudnessDbfs': loudnessDbfs,
        'windowMs': windowMs,
        'analyzedAtMs': analyzedAtMs,
      };

  static AutomixAnalysis? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    double? d(Object? v) => v is num ? v.toDouble() : null;
    int? i(Object? v) => v is num ? v.toInt() : null;
    final bpm = d(json['bpm']);
    final conf = d(json['confidence']);
    final first = d(json['firstBeatSec']);
    final dens = d(json['rhythmDensity']);
    final loud = d(json['loudnessDbfs']);
    final win = i(json['windowMs']);
    final at = i(json['analyzedAtMs']);
    final key = json['key'];
    if (bpm == null || conf == null || first == null || dens == null ||
        loud == null || win == null || at == null || key is! String) {
      return null;
    }
    return AutomixAnalysis(
      key: key, bpm: bpm, confidence: conf, firstBeatSec: first,
      rhythmDensity: dens, loudnessDbfs: loud, windowMs: win, analyzedAtMs: at,
    );
  }
}
