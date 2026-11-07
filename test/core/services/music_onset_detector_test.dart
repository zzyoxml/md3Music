import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/music_onset_detector.dart';

/// 谱流量 onset 检测器的行为契约。
///
/// 每一条都对应一个真实的失败模式：不冷却 → 马达嗡鸣；不设自适应阈值 →
/// 古典乐与电子乐不可能用同一个固定阈值；不加包络跟随器 → 安静段落方差趋零、
/// 阈值塌到 0，然后连续误报。测试用合成时钟，不依赖真实时间。
void main() {
  const step = Duration(milliseconds: 45);

  /// 跑一串能量值，返回触发发生时的帧下标。
  List<int> triggerFrames(
    MusicOnsetDetector detector,
    List<double> energies, {
    Duration start = const Duration(seconds: 1),
  }) {
    final hits = <int>[];
    var clock = start;
    for (var i = 0; i < energies.length; i++) {
      if (detector.process(energies[i], clock)) hits.add(i);
      clock += step;
    }
    return hits;
  }

  test('首帧只建立基线，不触发', () {
    final d = MusicOnsetDetector();
    expect(d.process(0.5, const Duration(seconds: 1)), isFalse);
  });

  test('阈值倍数按灵敏度取值并夹在 [0.5, 4.0]', () {
    expect(MusicOnsetDetector(sensitivity: 1.0).thresholdMultiplier, 1.5);
    // 1.5 / 4.0 = 0.375 → 夹到下限
    expect(MusicOnsetDetector(sensitivity: 4.0).thresholdMultiplier, 0.5);
    // 1.5 / 0.2 = 7.5 → 夹到上限
    expect(MusicOnsetDetector(sensitivity: 0.2).thresholdMultiplier, 4.0);
  });

  test('阶跃上升沿当帧立即触发，hump 内不连发', () {
    final d = MusicOnsetDetector();
    // 下标:   0    1    2    3    4    5    6    7
    // 能量: 1.0  1.0  1.0  1.0  3.0  1.0  1.0  1.0
    // 阶跃发生在下标 4；上升沿当帧（下标 4）触发，不再滞后一帧
    final hits = triggerFrames(d, const [1, 1, 1, 1, 3, 1, 1, 1].map((e) => e.toDouble()).toList());
    expect(hits, [4]);
  });

  test('冷却期内不重复触发：间隔 90ms 的两次阶跃只算一次', () {
    final d = MusicOnsetDetector(cooldown: const Duration(milliseconds: 130));
    // 下标 4 阶跃（当帧触发），下标 6 阶跃（只隔 90ms，被冷却拦下）
    final hits = triggerFrames(
      d,
      const [1, 1, 1, 1, 3, 1, 3, 1, 1, 1, 1].map((e) => e.toDouble()).toList(),
    );
    expect(hits, hasLength(1));
    expect(hits.single, 4);
  });

  test('冷却期过后同样的阶跃能再次触发', () {
    final d = MusicOnsetDetector(cooldown: const Duration(milliseconds: 130));
    final energies = <double>[
      ...List<double>.filled(4, 1.0),
      3.0, // 下标 4 阶跃 → 下标 4 当帧触发
      ...List<double>.filled(9, 1.0), // 静默 9 帧 = 405ms，远超冷却
      3.0, // 下标 14 阶跃 → 下标 14 当帧触发
      ...List<double>.filled(3, 1.0),
    ];
    final hits = triggerFrames(d, energies);
    expect(hits, hasLength(2));
    expect(hits.first, 4);
    expect(hits.last, 14);
  });

  test('安静段落不因方差塌零而连续误报', () {
    final d = MusicOnsetDetector();
    final hits = triggerFrames(d, List<double>.filled(60, 0.0));
    expect(hits, isEmpty);
  });

  test('稳态信号不触发（谱流量只认上升沿）', () {
    final d = MusicOnsetDetector();
    final hits = triggerFrames(d, List<double>.filled(60, 2.0));
    expect(hits, isEmpty);
  });

  test('自适应阈值：响段之后同一个弱阶跃不再触发', () {
    // 对照组：全新检测器上，1.0 → 1.3 的弱阶跃会触发
    final fresh = MusicOnsetDetector();
    final freshHits = triggerFrames(
      fresh,
      const [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.3, 1.0, 1.0].map((e) => e.toDouble()).toList(),
    );
    expect(freshHits, isNotEmpty, reason: '弱阶跃在干净背景下应当被检出');

    // 实验组：先用一段强信号把 EMA 均值/方差抬起来，再给同一个弱阶跃
    final warmed = MusicOnsetDetector();
    final warmup = <double>[];
    for (var i = 0; i < 30; i++) {
      warmup.add(i.isEven ? 0.2 : 6.0);
    }
    triggerFrames(warmed, warmup);
    final warmedHits = triggerFrames(
      warmed,
      const [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.3, 1.0, 1.0].map((e) => e.toDouble()).toList(),
    );
    expect(warmedHits, isEmpty, reason: '背景被抬高后，弱阶跃不应再被当鼓点');
  });

  test('灵敏度越低阈值越高（同样信号下阈值严格有序）', () {
    final sensitive = MusicOnsetDetector(sensitivity: 4.0);
    final dull = MusicOnsetDetector(sensitivity: 0.2);
    var clock = const Duration(seconds: 1);
    // 交替信号把 EMA 方差抬起来，乘数才真正起作用
    for (final e in const [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0]) {
      sensitive.process(e, clock);
      dull.process(e, clock);
      clock += step;
    }
    expect(sensitive.lastThreshold, lessThan(dull.lastThreshold));
  });

  test('reset 后与全新实例逐帧一致', () {
    final reused = MusicOnsetDetector();
    var clock = const Duration(seconds: 1);
    for (final e in const [1.0, 5.0, 1.0, 1.0, 1.0, 7.0, 1.0]) {
      reused.process(e, clock);
      clock += step;
    }
    reused.reset();

    final fresh = MusicOnsetDetector();
    final sequence = const [1.0, 1.0, 1.0, 1.0, 3.0, 1.0, 1.0, 1.0, 3.0, 1.0];

    final reusedHits = triggerFrames(reused, sequence);
    final freshHits = triggerFrames(fresh, sequence);
    expect(reusedHits, freshHits);
  });

  test('掩码衰减按真实 dt 折算：不同步进下触发时刻按墙钟一致', () {
    // 刺激定义在**墙钟**上（基线 180ms，之后每 450ms 一个 45ms 宽的脉冲），
    // 步进只改变采样密度 —— 帧率无关化成立则触发时刻（真实时间）必须一致，
    // 允许一帧粒度（= 粗步进）的误差。
    // 注意：不能按"固定帧数 × 变步长"定义刺激 —— 那样步长一变信号本身就变了，
    // 墙钟对齐无从谈起（计划初稿就栽在这里，由 subagent 汇报后修正）。
    List<int> hitsAtMs(int stepMs) {
      final d = MusicOnsetDetector();
      final hits = <int>[];
      const baselineMs = 180;
      const beatMs = 450;
      const pulseMs = 45;
      final totalMs = baselineMs + beatMs * 6;
      for (var t = 0; t < totalMs; t += stepMs) {
        final inPulse =
            t >= baselineMs && (t - baselineMs) % beatMs < pulseMs;
        if (d.process(inPulse ? 3.0 : 1.0, Duration(milliseconds: t))) {
          hits.add(t);
        }
      }
      return hits;
    }

    final fast = hitsAtMs(45);
    final slow = hitsAtMs(90);
    expect(fast, isNotEmpty, reason: '刺激本身必须能触发，否则断言无意义');
    // 触发次数允许差 1（EMA 按帧更新，粗步进下自适应略慢），时刻误差 ≤ 一帧
    expect((slow.length - fast.length).abs(), lessThanOrEqualTo(1),
        reason: '触发次数不应随步进明显变化（fast=$fast slow=$slow）');
    for (var i = 0; i < math.min(fast.length, slow.length); i++) {
      expect((fast[i] - slow[i]).abs(), lessThanOrEqualTo(90),
          reason: '触发时刻按墙钟对齐：fast=${fast[i]}ms slow=${slow[i]}ms');
    }
  });

  test('相对噪声门：背景抬升后微小抖动不再触发（scale-free 复核）', () {
    // 能量放大 100 倍（模拟真机 FFT 原始幅度量纲），同样的相对形状必须同样触发
    final tiny = MusicOnsetDetector();
    final huge = MusicOnsetDetector();
    final seq = [1.0, 1.0, 1.0, 1.0, 3.0, 1.0, 1.0, 3.0, 1.0];
    var clock = const Duration(seconds: 1);
    var tinyHits = 0;
    var hugeHits = 0;
    for (final e in seq) {
      if (tiny.process(e, clock)) tinyHits++;
      if (huge.process(e * 100, clock)) hugeHits++;
      clock += const Duration(milliseconds: 45);
    }
    expect(tinyHits, hugeHits,
        reason: '能量整体缩放不应改变触发次数（tiny=$tinyHits huge=$hugeHits）');
  });
}
