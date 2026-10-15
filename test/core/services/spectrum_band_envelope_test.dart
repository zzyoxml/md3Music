import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/spectrum_band_envelope.dart';

void main() {
  group('SpectrumBandEnvelope', () {
    test('回落速度与节拍频率无关（8ms×2 与 16ms×1 结果一致）', () {
      // 这是本设计的核心不变量：衰减必须按**时间**算，不能按调用次数。
      // 若哪天有人把 advance 改回「每次衰减固定比例」，这条会立刻红。
      final a = SpectrumBandEnvelope(bandCount: 1);
      final b = SpectrumBandEnvelope(bandCount: 1);
      a.setTarget([1.0]);
      b.setTarget([1.0]);
      a.advance(const Duration(milliseconds: 16));
      b.advance(const Duration(milliseconds: 16));
      expect(a.values[0], 1.0, reason: '上升应瞬时到位');

      a.setTarget([0.0]);
      b.setTarget([0.0]);
      a.advance(const Duration(milliseconds: 8));
      a.advance(const Duration(milliseconds: 8));
      b.advance(const Duration(milliseconds: 16));

      expect(a.values[0], closeTo(b.values[0], 1e-12));
    });

    test('上升瞬时到位', () {
      final e = SpectrumBandEnvelope(bandCount: 3);
      e.setTarget([0.8, 0.2, 1.0]);
      e.advance(const Duration(milliseconds: 16));
      expect(e.values[0], 0.8);
      expect(e.values[1], 0.2);
      expect(e.values[2], 1.0);
    });

    test('回落单调递减且不过冲', () {
      final e = SpectrumBandEnvelope(bandCount: 1);
      e.setTarget([0.8]);
      e.advance(const Duration(milliseconds: 16));
      expect(e.values[0], 0.8);

      e.setTarget([0.0]);
      var previous = e.values[0];
      for (var i = 0; i < 40; i++) {
        e.advance(const Duration(milliseconds: 16));
        final current = e.values[0];
        expect(current, lessThanOrEqualTo(previous), reason: '第 $i 拍出现回升');
        expect(current, greaterThanOrEqualTo(0.0), reason: '第 $i 拍越过 0');
        previous = current;
      }
      expect(previous, lessThan(0.8));
    });

    test('收敛后 isSettled 为真，目标变化后立即为假', () {
      final e = SpectrumBandEnvelope(bandCount: 3);
      e.setTarget([0.9, 0.5, 0.2]);
      e.advance(const Duration(milliseconds: 16));
      expect(e.isSettled, isTrue, reason: '上升瞬时到位后应已收敛');

      e.setTarget([0.0, 0.0, 0.0]);
      expect(e.isSettled, isFalse);

      // τ=120ms，1.6s（100 拍 × 16ms）后必然落到 1e-3 以内
      for (var i = 0; i < 100; i++) {
        e.advance(const Duration(milliseconds: 16));
      }
      expect(e.isSettled, isTrue);
    });

    test('目标长度不匹配时补零或截断，values 长度恒为 bandCount', () {
      final short = SpectrumBandEnvelope(bandCount: 4);
      short.setTarget([1.0, 1.0]);
      short.advance(const Duration(milliseconds: 16));
      expect(short.values.length, 4);
      expect(short.values[0], 1.0);
      expect(short.values[1], 1.0);
      expect(short.values[2], 0.0);
      expect(short.values[3], 0.0);

      final long = SpectrumBandEnvelope(bandCount: 2);
      long.setTarget([0.3, 0.6, 0.9, 1.0]);
      long.advance(const Duration(milliseconds: 16));
      expect(long.values.length, 2);
      expect(long.values[0], 0.3);
      expect(long.values[1], 0.6);
    });

    test('reset 归零并立即收敛', () {
      final e = SpectrumBandEnvelope(bandCount: 2);
      e.setTarget([1.0, 1.0]);
      e.advance(const Duration(milliseconds: 16));
      e.reset();
      expect(e.values, everyElement(0.0));
      expect(e.isSettled, isTrue);
    });

    test('dt 为 0 或负数时不动值', () {
      final e = SpectrumBandEnvelope(bandCount: 1);
      e.setTarget([1.0]);
      e.advance(const Duration(milliseconds: 16));
      e.setTarget([0.0]);
      final before = e.values[0];

      e.advance(Duration.zero);
      expect(e.values[0], before);
      e.advance(const Duration(microseconds: -500));
      expect(e.values[0], before);
    });

    test('目标值被钳制到 0..1', () {
      final e = SpectrumBandEnvelope(bandCount: 2);
      e.setTarget([1.5, -0.5]);
      e.advance(const Duration(milliseconds: 16));
      expect(e.values[0], 1.0);
      expect(e.values[1], 0.0);
    });

    test('defaultReleaseTau 为 120ms（与旧「50ms 衰减到 65%」等效）', () {
      expect(
        SpectrumBandEnvelope.defaultReleaseTau,
        const Duration(milliseconds: 120),
      );
    });
  });
}
