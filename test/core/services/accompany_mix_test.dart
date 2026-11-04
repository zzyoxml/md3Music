import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/accompany_mix.dart';

/// 伴唱混音：纯伴奏语义 + 两路音量换算 + 漂移校正判定。
///
/// 这些是纯函数（不触碰播放器），可在无音频设备的环境单测。
///
/// **伴唱固定为纯伴奏**：在线伴奏是两条独立解码管线，两路 AudioTrack 排队
/// 深度不同，比例一旦小于 1 就会听到错位（这是历史上偏移/自动对齐都没能
/// 解决的根因），因此不再提供比例调节。
void main() {
  group('AccompanyMix 纯伴奏语义', () {
    test('唯一形态是纯伴奏（伴奏占比 1.0）', () {
      expect(AccompanyMix.accompanyOnly.mix, 1.0);
      expect(AccompanyMix.accompanyOnly.isAccompanyOnly, isTrue);
      expect(AccompanyMix.accompanyOnly.isOriginalOnly, isFalse);
    });

    test('恒等于自身（去重比较用）', () {
      expect(AccompanyMix.accompanyOnly, AccompanyMix.accompanyOnly);
      expect(
        AccompanyMix.accompanyOnly.hashCode,
        AccompanyMix.accompanyOnly.hashCode,
      );
    });
  });

  group('两路音量换算', () {
    test('原曲恒静音、伴奏跟随用户音量', () {
      final v = AccompanyMix.accompanyOnly.volumes(userVolume: 1.0);
      expect(v.original, closeTo(0.0, 1e-9));
      expect(v.accompany, closeTo(1.0, 1e-9));
    });

    test('用户音量等比缩放到伴奏一路', () {
      final v = AccompanyMix.accompanyOnly.volumes(userVolume: 0.6);
      expect(v.original, closeTo(0.0, 1e-9));
      expect(v.accompany, closeTo(0.6, 1e-9));
    });

    test('响度衰减不改变伴奏音量（伴奏轨不参与归一）', () {
      final v = AccompanyMix.accompanyOnly.volumes(
        userVolume: 1.0,
        attenuation: 0.5,
      );
      // 伴奏是另一首歌，响度不同，套用原曲的衰减会误压
      expect(v.original, closeTo(0.0, 1e-9));
      expect(v.accompany, closeTo(1.0, 1e-9));
    });

    test('用户音量被钳在 0..1', () {
      final loud = AccompanyMix.accompanyOnly.volumes(userVolume: 2.0);
      expect(loud.accompany, closeTo(1.0, 1e-9));
      final negative = AccompanyMix.accompanyOnly.volumes(userVolume: -0.5);
      expect(negative.accompany, closeTo(0.0, 1e-9));
    });

    test('原曲一路恒为 0，与衰减倍率是否合法无关', () {
      final v = AccompanyMix.accompanyOnly.volumes(
        userVolume: 1.0,
        attenuation: double.nan,
      );
      expect(v.original, closeTo(0.0, 1e-9));
    });
  });

  group('漂移校正判定', () {
    test('偏差在阈值内不校正', () {
      expect(
        accompanyNeedsResync(mainPositionMs: 10000, accompanyPositionMs: 9800),
        isFalse,
      );
    });

    test('偏差超过阈值时校正', () {
      expect(
        accompanyNeedsResync(mainPositionMs: 10000, accompanyPositionMs: 9000),
        isTrue,
      );
    });

    test('伴唱超前同样校正', () {
      expect(
        accompanyNeedsResync(mainPositionMs: 10000, accompanyPositionMs: 11000),
        isTrue,
      );
    });
  });

  group('校正可行性（ready 守卫）', () {
    // just_audio.seek() 在 ProcessingState.loading 时静默丢弃（fork
    // just_audio.dart 的 `case ProcessingState.loading: return;`），
    // 因此未 ready 时发起的校正 seek 不会生效 —— 这是「伴奏有概率无法
    // 对齐」的主因。守卫必须把这类情形挡在外面，由 ready 回调补做。
    test('未 ready 时不可校正', () {
      expect(accompanyCanResync(ready: false), isFalse);
    });

    test('ready 时可校正', () {
      expect(accompanyCanResync(ready: true), isTrue);
    });
  });
}
