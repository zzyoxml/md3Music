import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// 音量均衡（响度归一化 / ReplayGain 思路）。
///
/// 算法复刻 EchoMusic `shared/loudness.ts`：按歌曲响度（LUFS）把音量归一到一个参考
/// 响度，让不同歌之间的响度保持一致。增益基于「参考响度 - 歌曲响度」，并用歌曲峰值
/// 防削波钳位，最终把 dB 换算成线性增益交给播放器。
///
/// 关键：增益可 >1（放大安静歌），ExoPlayer 的 AudioTrack 只能衰减做不到，因此
/// 由原生 `NormalizationGainAudioSink` 在 PCM 出口按逐轨固定线性增益放大/衰减。
class VolumeNormalizationService {
  VolumeNormalizationService._();

  static const double defaultReferenceLufs = -14;

  /// 峰值上限（dBTP），与 EchoMusic `NORMALIZATION_PEAK_CEILING_DB` 一致。
  static const double peakCeilingDb = -0.5;

  static const double _minReferenceLufs = -20;
  static const double _maxReferenceLufs = -8;
  static const double _minTrackLufs = -70;
  static const double _maxTrackLufs = 0;
  static const double _minTrackPeakDb = -120;
  static const double _maxTrackPeakDb = 24;
  static const double _minGainDb = -40;
  // 与 EchoMusic MAX_NORMALIZATION_GAIN_DB = 20 * log10(3) 一致（线性 3× ≈ +9.54 dB）。
  static final double _maxGainDb = 20 * (math.log(3.0) / math.log(10.0));

  /// 计算归一增益（dB）。
  ///
  /// [lufs] 歌曲集总响度（LUFS），[peakDb] 真峰值（dBTP/dBFS，可为 null），
  /// [referenceLufs] 参考响度（默认 -14）。无有效响度数据时返回 0（旁路）。
  static double calcGainDb({
    double? lufs,
    double? peakDb,
    double referenceLufs = defaultReferenceLufs,
  }) {
    if (lufs == null || !lufs.isFinite) return 0;
    if (lufs <= _minTrackLufs || lufs >= _maxTrackLufs) return 0;
    if (peakDb != null &&
        (!peakDb.isFinite || peakDb < _minTrackPeakDb || peakDb > _maxTrackPeakDb)) {
      return 0;
    }
    final ref = referenceLufs.clamp(_minReferenceLufs, _maxReferenceLufs);
    var gainDb = ref - lufs;
    if (peakDb != null && peakDb.isFinite) {
      // 防削波：增益不能把峰值推到超过 peakCeilingDb。
      gainDb = math.min(gainDb, peakCeilingDb - peakDb);
    }
    return gainDb.clamp(_minGainDb, _maxGainDb);
  }

  /// 把 AutoMix 自测的响度（dBFS）折算成音量均衡可直接使用的响度值。
  ///
  /// **为什么需要这条通路**：真机上酷狗 `/song/url` 不返回 `volume` 字段
  /// （`KugouPlayUrl.volumeLufs` 恒为 null），现有「音量均衡」拿不到任何数据、
  /// 形同虚设 —— 于是相邻曲目的原始响度差会原样透出，实测可达 **13.7 dB**
  /// （约 4.8 倍音量），表现为「切歌时音量突然变大」。
  /// AutoMix 会为每首歌解码 25s 音频并实测出 `loudnessDbfs`，正好补这个缺口。
  ///
  /// **口径说明（重要）**：两者并不等价，属于工程近似：
  /// - `loudnessDbfs`：未加权 RMS 的 90 分位，无门限；
  /// - LUFS：K-weighting 频率加权 + 门限，通常比未加权 RMS 低 1~3 dB。
  /// 对「消除切歌响度跳变」这一用途，2~3 dB 的口径误差可接受
  /// （被补偿的原始差已达 13.7 dB 量级）。
  ///
  /// 落在 [calcGainDb] 合法区间外的值一律丢弃 —— 垃圾数据不能把音量算飞。
  static double? loudnessFromMeasuredDbfs(double? measuredDbfs) {
    if (measuredDbfs == null || !measuredDbfs.isFinite) return null;
    if (measuredDbfs <= _minTrackLufs || measuredDbfs >= _maxTrackLufs) {
      return null;
    }
    return measuredDbfs;
  }

  /// 将 dB 增益换算为线性增益。
  static double dbToLinear(double db) => math.pow(10, db / 20).toDouble();

  /// 把 dB 增益应用到 AudioSink 增益装饰器（原生放大/衰减）。
  ///
  /// 经独立 MethodChannel 广播给原生所有 AudioSink 实例，避免依赖被环境回滚的
  /// just_audio per-player 通道方法。`[player]` 仅为兼容旧调用保留，不再使用。
  static void applyGain(AudioPlayer player, double gainDb) async {
    try {
      // 走播放 isolate 已确认可达的 floating_lyric 通道（封面预取即用该通道），
      // 避免 headless/UI 双引擎下自定义通道注册不到播放 isolate 的问题。
      const channel = MethodChannel('com.md3music.md3music/floating_lyric');
      await channel.invokeMethod('setGainDb', {'gainDb': gainDb});
    } catch (e) {
      // ignore: avoid_print
      print('[NormalizationGain] applyGain failed: $e');
    }
  }
}