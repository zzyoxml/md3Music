import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/volume_normalization_service.dart';

void main() {
  group('loudnessFromMeasuredDbfs（AutoMix 实测响度 → 音量均衡数据源）', () {
    test('正常实测值原样返回', () {
      expect(
        VolumeNormalizationService.loudnessFromMeasuredDbfs(-8.7),
        closeTo(-8.7, 1e-9),
      );
      expect(
        VolumeNormalizationService.loudnessFromMeasuredDbfs(-22.4),
        closeTo(-22.4, 1e-9),
      );
    });

    test('null / NaN / 无穷返回 null（不能把垃圾值喂给 calcGainDb）', () {
      expect(VolumeNormalizationService.loudnessFromMeasuredDbfs(null), isNull);
      expect(
        VolumeNormalizationService.loudnessFromMeasuredDbfs(double.nan),
        isNull,
      );
      expect(
        VolumeNormalizationService.loudnessFromMeasuredDbfs(double.infinity),
        isNull,
      );
    });

    test('落在 calcGainDb 合法区间外（<= -70 或 >= 0）一律丢弃', () {
      expect(VolumeNormalizationService.loudnessFromMeasuredDbfs(-70), isNull);
      expect(VolumeNormalizationService.loudnessFromMeasuredDbfs(-120), isNull);
      expect(VolumeNormalizationService.loudnessFromMeasuredDbfs(0), isNull);
      expect(VolumeNormalizationService.loudnessFromMeasuredDbfs(3), isNull);
    });

    test('实测 -8.7dBFS 接进 calcGainDb：-14 参考下产生约 -5.3dB 衰减', () {
      final lufs = VolumeNormalizationService.loudnessFromMeasuredDbfs(-8.7)!;
      final gain = VolumeNormalizationService.calcGainDb(lufs: lufs);
      expect(gain, closeTo(-5.3, 0.05));
    });

    test('实测 -22.4dBFS 低于参考：产生约 +8.4dB（交由 LoudnessEnhancer 放大）', () {
      final lufs = VolumeNormalizationService.loudnessFromMeasuredDbfs(-22.4)!;
      final gain = VolumeNormalizationService.calcGainDb(lufs: lufs);
      expect(gain, closeTo(8.4, 0.05));
    });

    test('回归：真机实测的相邻响度差 13.7dB（-22.4 → -8.7）被补偿后收敛到 0', () {
      // 这两个值来自真机 AutoMix 缓存（53ED688E / E7971FFE），
      // 是用户报「切歌时音量突然变大」的直接来源。
      const quietDbfs = -22.4;
      const loudDbfs = -8.7;
      final quietGain = VolumeNormalizationService.calcGainDb(
        lufs: VolumeNormalizationService.loudnessFromMeasuredDbfs(quietDbfs)!,
      );
      final loudGain = VolumeNormalizationService.calcGainDb(
        lufs: VolumeNormalizationService.loudnessFromMeasuredDbfs(loudDbfs)!,
      );
      // 补偿后的有效响度 = 原始响度 + 增益，两者都应落到参考响度 -14
      final quietEffective = quietDbfs + quietGain;
      final loudEffective = loudDbfs + loudGain;
      expect(quietEffective, closeTo(-14.0, 0.05));
      expect(loudEffective, closeTo(-14.0, 0.05));
      // 补偿前差 13.7dB，补偿后差 ≈ 0
      expect((quietEffective - loudEffective).abs(), lessThan(0.1));
    });
  });
}
