import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/rhythm_motion.dart';

/// [RhythmMotionEnvelope]：频谱 → 流光 `uMotion` 的标量包络语义。
///
/// 断言的核心契约（对应实现计划 §0）：
/// 1. **无数据/静音 = ambient（1.0）** —— 等价改动前「恒 1.0」，零回归；
/// 2. 有音乐时随活动度上升，顶到 `ambient + gain`（且不超过 `maxMotion`）；
/// 3. 瞬态（onset）比同等持续能量更冲，然后回落到持续能量对应的目标；
/// 4. 超过 `staleAfter` 没有新帧 → 目标回落 ambient（流断/采集停）；
/// 5. 边界输入（空/NaN/负值/dt<=0）安全，不产生 NaN/Inf。
void main() {
  // 本仓流光节拍 = 每 2 拍 32ms（30fps 档）。
  const frame = Duration(milliseconds: 32);

  /// 40 段频谱：最低 22%（9 段）为 [bass]，其余为 [rest]。
  List<double> bands({double bass = 0, double rest = 0}) {
    final list = List<double>.filled(40, rest);
    final bassCount = (40 * 0.22).round(); // = 9
    for (var i = 0; i < bassCount; i++) {
      list[i] = bass;
    }
    return list;
  }

  /// 模拟真实数据到达（~20fps → 每 2 拍喂一帧）并推进 [frames] 拍。
  void feed(
    RhythmMotionEnvelope envelope,
    List<double> frameBands,
    int frames,
  ) {
    for (var i = 0; i < frames; i++) {
      if (i.isEven) envelope.setBands(frameBands);
      envelope.advance(frame);
    }
  }

  test('无数据：恒为 ambient（= 改动前观感）', () {
    final envelope = RhythmMotionEnvelope();
    expect(envelope.motion, 1.0);
    for (var i = 0; i < 60; i++) {
      envelope.advance(frame);
    }
    expect(envelope.motion, closeTo(1.0, 1e-9));
    expect(envelope.target, closeTo(1.0, 1e-9));
  });

  test('静音/极低能量：仍在 ambient 附近（不会掉到 0）', () {
    final envelope = RhythmMotionEnvelope();
    feed(envelope, bands(bass: 0.02, rest: 0.02), 40);
    expect(envelope.motion, greaterThanOrEqualTo(1.0));
    expect(envelope.motion, lessThan(1.03));
  });

  test('持续高能量：向 ambient + gain 逼近，且不超过 maxMotion', () {
    final envelope = RhythmMotionEnvelope();
    feed(envelope, bands(bass: 1, rest: 1), 12); // 384ms < staleAfter(500ms)
    expect(envelope.motion, greaterThan(1.4));
    expect(envelope.motion, lessThanOrEqualTo(envelope.maxMotion));
    // 长跑也不会越界（stale 之外目标回落，但 motion 永远在 [ambient, maxMotion]）
    for (var i = 0; i < 200; i++) {
      envelope.advance(frame);
      expect(envelope.motion, inInclusiveRange(1.0, envelope.maxMotion));
      expect(envelope.motion.isFinite, isTrue);
    }
  });

  test('瞬态 onset 比同等持续能量更冲（先冲后回落）', () {
    final envelope = RhythmMotionEnvelope();
    // 先建立「慢低音」基线
    feed(envelope, bands(bass: 0.05), 30);
    // 低音阶跃
    envelope.setBands(bands(bass: 0.4));
    envelope.advance(frame);
    final onsetTarget = envelope.target;
    // 持续同样的能量，慢低音追上后 onset 归零 → 目标回落
    feed(envelope, bands(bass: 0.4), 40);
    final steadyTarget = envelope.target;
    expect(onsetTarget, greaterThan(steadyTarget),
        reason: '阶跃瞬间应因 onset 更冲');
    expect(envelope.motion, greaterThan(1.0));
  });

  test('超过 staleAfter 没有新帧：目标回落 ambient（流断不死亮）', () {
    final envelope = RhythmMotionEnvelope();
    feed(envelope, bands(bass: 1, rest: 1), 8);
    final loud = envelope.motion;
    expect(loud, greaterThan(1.2));
    // 停止喂数据，推进 800ms（> 500ms stale 阈值）
    for (var i = 0; i < 25; i++) {
      envelope.advance(frame);
    }
    expect(envelope.target, closeTo(1.0, 1e-9));
    expect(envelope.motion, lessThan(loud), reason: '断流后应向基线回落');
  });

  test('边界输入安全：空/NaN/负值/dt<=0', () {
    final envelope = RhythmMotionEnvelope();
    envelope.setBands(const <double>[]);
    envelope.advance(Duration.zero);
    envelope.advance(const Duration(milliseconds: -32));
    expect(envelope.motion, 1.0);
    expect(envelope.motion.isNaN, isFalse);

    envelope.setBands(List<double>.filled(40, double.nan));
    for (var i = 0; i < 10; i++) {
      envelope.advance(frame);
    }
    expect(envelope.motion.isNaN, isFalse);
    expect(envelope.motion, inInclusiveRange(1.0, 1.5));

    envelope.setBands(List<double>.filled(40, -3));
    for (var i = 0; i < 10; i++) {
      envelope.advance(frame);
    }
    expect(envelope.motion, inInclusiveRange(1.0, 1.5));
  });

  test('resetToAmbient：退订后立刻回到 1.0（下次可见首帧零回归）', () {
    final envelope = RhythmMotionEnvelope();
    feed(envelope, bands(bass: 1, rest: 1), 10);
    expect(envelope.motion, greaterThan(1.2));
    envelope.resetToAmbient();
    expect(envelope.motion, 1.0);
    expect(envelope.target, 1.0);
    expect(envelope.isSettled, isTrue);
  });

  test('自定义 ambient/gain/maxMotion 生效', () {
    final envelope = RhythmMotionEnvelope(
      ambient: 0.8,
      gain: 0.1,
      maxMotion: 0.95,
    );
    expect(envelope.motion, 0.8);
    feed(envelope, bands(bass: 1, rest: 1), 12);
    expect(envelope.motion, lessThanOrEqualTo(0.95));
    expect(envelope.motion, greaterThan(0.8));
  });
}
