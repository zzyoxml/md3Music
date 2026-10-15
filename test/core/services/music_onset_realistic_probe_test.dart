// [MH-PROBE] 临时诊断测试（验证完删除）：用合成"现代流行"混音复刻原生特征管线
// （44.1kHz / 1024 Hann 窗 / 45ms 跳步 / 频带均值），把 low/high 喂给真实的
// MusicOnsetDetector，对照已知鼓点时间统计触发对齐率 —— 用于定位
// "震动跟鼓点关系不大" 的根因。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/music_onset_detector.dart';

void main() {
  test('PROBE: realistic mix → onset alignment', () {
    const sr = 44100;
    const durSec = 30.0;
    final n = (sr * durSec).toInt();
    final mix = Float64List(n);
    final rng = math.Random(7);

    final kicks = <double>[];
    final snares = <double>[];
    final bassNotes = <double>[];

    // ── 合成 ──────────────────────────────────────────────
    // 底鼓：每拍（0.5s），110→50Hz 扫频 + 指数衰减
    for (var t = 0.0; t < durSec; t += 0.5) {
      kicks.add(t);
      final start = (t * sr).toInt();
      final len = (0.25 * sr).toInt();
      var phase = 0.0;
      for (var i = 0; i < len && start + i < n; i++) {
        final tt = i / sr;
        final f = 50.0 + 60.0 * math.exp(-tt / 0.035);
        phase += 2 * math.pi * f / sr;
        final env = math.exp(-tt / 0.09);
        mix[start + i] += 0.9 * env * math.sin(phase);
      }
    }
    // 军鼓：2/4 拍（+0.25s 偏移），带通噪声感 + 200Hz 鼓身
    for (var t = 0.25; t < durSec; t += 0.5) {
      snares.add(t);
      final start = (t * sr).toInt();
      final len = (0.18 * sr).toInt();
      for (var i = 0; i < len && start + i < n; i++) {
        final tt = i / sr;
        final env = math.exp(-tt / 0.045);
        mix[start + i] +=
            0.30 * env * (rng.nextDouble() * 2 - 1) +
            0.15 * env * math.sin(2 * math.pi * 200 * tt);
      }
    }
    // 贝斯：八分音符（0.25s 网格，与军鼓同拍混叠）—— 低频带的实际主角
    const bassScale = [55.0, 55.0, 82.41, 55.0, 73.42, 55.0, 82.41, 98.0];
    var noteIdx = 0;
    for (var t = 0.0; t < durSec; t += 0.25) {
      bassNotes.add(t);
      final f = bassScale[noteIdx++ % bassScale.length];
      final start = (t * sr).toInt();
      final len = (0.24 * sr).toInt();
      for (var i = 0; i < len && start + i < n; i++) {
        final tt = i / sr;
        final atk = math.min(1.0, tt / 0.015);
        final rel = math.min(1.0, (0.24 - tt) / 0.04);
        final env = atk * rel;
        mix[start + i] += 0.5 *
            env *
            (math.sin(2 * math.pi * f * tt) +
                0.3 * math.sin(2 * math.pi * 2 * f * tt));
      }
    }
    // 人声：乐句式（3s 开 / 1.5s 关），220Hz 基频 + 泛音 + 颤音
    for (var t = 0.5; t < durSec; t += 4.5) {
      final end = math.min(durSec, t + 3.0);
      for (var i = (t * sr).toInt(); i < end * sr && i < n; i++) {
        final tt = i / sr;
        final syll = 0.55 + 0.45 * math.sin(2 * math.pi * (tt % 0.3) / 0.3);
        final f0 = 220.0 + 3.0 * math.sin(2 * math.pi * 5 * tt);
        mix[i] += syll *
            (0.12 * math.sin(2 * math.pi * f0 * tt) +
                0.06 * math.sin(2 * math.pi * 2 * f0 * tt) +
                0.03 * math.sin(2 * math.pi * 3 * f0 * tt));
      }
    }
    // 踩镲：每八分音符反拍，高频噪声短促
    for (var t = 0.125; t < durSec; t += 0.25) {
      final start = (t * sr).toInt();
      final len = (0.06 * sr).toInt();
      for (var i = 0; i < len && start + i < n; i++) {
        final tt = i / sr;
        mix[start + i] += 0.06 * math.exp(-tt / 0.02) * (rng.nextDouble() * 2 - 1);
      }
    }
    // 无声段（24s~26s）：只有底噪，模拟歌曲间隙 —— 全功能必须零触发
    for (var i = (24.0 * sr).toInt(); i < (26.0 * sr).toInt() && i < n; i++) {
      mix[i] = 0;
    }
    // 底噪
    for (var i = 0; i < n; i++) {
      mix[i] += 0.003 * (rng.nextDouble() * 2 - 1);
    }

    // ── 特征提取（复刻 SpectrumFft.magnitudesFrom + SpectrumFeatures 频带均值）──
    const fftSize = 1024;
    const hzPerBin = sr / fftSize;
    final hann = Float64List(fftSize);
    for (var i = 0; i < fftSize; i++) {
      hann[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (fftSize - 1)));
    }
    // magIndex(30Hz)=0, magIndex(300Hz)=6 → low = mean(mags[0..6))，FFT bin 1..6
    const lowBins = [1, 2, 3, 4, 5, 6];
    // magIndex(3000)=68, magIndex(8000)=184 → high = mean(mags[68..184))，bin 69..184
    final highBins = List<int>.generate(116, (i) => 69 + i);

    double goertzelMag(Float64List frame, int bin) {
      final coeff = 2 * math.cos(2 * math.pi * bin / fftSize);
      var s1 = 0.0, s2 = 0.0;
      for (var i = 0; i < fftSize; i++) {
        final s = frame[i] + coeff * s1 - s2;
        s2 = s1;
        s1 = s;
      }
      return math.sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2);
    }

    final frame = Float64List(fftSize);
    const hopMs = 45;
    final hop = (sr * hopMs / 1000).round();
    final kickDet = MusicOnsetDetector();
    final snareDet = MusicOnsetDetector(
      sensitivity: 0.8,
      cooldown: const Duration(milliseconds: 160),
      noiseGate: 0.008,
    );
    final triggerLog = <String>[]; // [MH-PROBE] 触发记录
    final lows = <double>[];
    final clockMs = <int>[];

    for (var start = 0; start + fftSize <= n; start += hop) {
      for (var i = 0; i < fftSize; i++) {
        frame[i] = mix[start + i] * hann[i];
      }
      var lowSum = 0.0;
      for (final b in lowBins) {
        lowSum += goertzelMag(frame, b);
      }
      final low = lowSum / lowBins.length;
      var highSum = 0.0;
      for (final b in highBins) {
        highSum += goertzelMag(frame, b);
      }
      final high = highSum / highBins.length;

      final tMs = (start / sr * 1000).round();
      lows.add(low);
      clockMs.add(tMs);
      final t = Duration(milliseconds: tMs);
      if (kickDet.process(low, t)) {
        triggerLog.add('KICK t=${(tMs / 1000).toStringAsFixed(2)}');
      }
      if (snareDet.process(high, t)) {
        triggerLog.add('SNARE t=${(tMs / 1000).toStringAsFixed(2)}');
      }
    }

    // ── 统计 ──────────────────────────────────────────────
    lows.sort();
    double pct(double p) => lows[(p * (lows.length - 1)).round()];
    // ignore: avoid_print
    print('[PROBE] low 能量分布: p10=${pct(0.1).toStringAsFixed(1)} '
        'p50=${pct(0.5).toStringAsFixed(1)} p90=${pct(0.9).toStringAsFixed(1)} '
        'p99=${pct(0.99).toStringAsFixed(1)}');

    var kickAligned = 0, kickOnBassOnly = 0;
    final kickTriggers = <double>[];
    for (final line in triggerLog) {
      if (!line.startsWith('KICK')) continue;
      final t = double.parse(line.split('t=')[1]) * 1000; // ms
      kickTriggers.add(t);
      final nearestKick = _nearest(kicks, t);
      final nearestBass = _nearest(bassNotes, t);
      if (nearestKick.$2 <= 90) {
        kickAligned++;
      } else if (nearestBass.$2 <= 90) {
        kickOnBassOnly++;
      }
      // ignore: avoid_print
      print('[PROBE] $line 最近Kick=${nearestKick.$2}ms 最近Bass=${nearestBass.$2}ms');
    }
    var snareAligned = 0, snareTotal = 0;
    for (final line in triggerLog) {
      if (!line.startsWith('SNARE')) continue;
      snareTotal++;
      final t = double.parse(line.split('t=')[1]) * 1000;
      if (_nearest(snares, t).$2 <= 90) snareAligned++;
      // ignore: avoid_print
      print('[PROBE] $line 最近Snare=${_nearest(snares, t).$2}ms');
    }
    // ignore: avoid_print
    print('[PROBE] kick触发=${kickTriggers.length} 踩中Kick=$kickAligned '
        '只踩中Bass=$kickOnBassOnly | snare触发=$snareTotal 踩中=$snareAligned');
    // ignore: avoid_print
    print('[PROBE] 触发序列: $triggerLog');

    // ── 回归门 ──
    expect(kickTriggers, isNotEmpty, reason: '探针至少要触发一次才有诊断意义');

    // 无声段零触发（R2 噪声触发回归锁）
    final silentHits = triggerLog.where((l) {
      final t = double.parse(l.split('t=')[1]);
      return t >= 24.0 && t < 26.0;
    });
    expect(silentHits, isEmpty, reason: '无声段（仅底噪）不得有任何触发：$silentHits');

    // kick 对齐率：上升沿 + 23ms hop 下应 ≥ 75%（探针改造前 39/47 ≈ 83%，含真峰延迟）
    final alignedRatio = kickTriggers.isEmpty
        ? 0.0
        : kickAligned / kickTriggers.length;
    expect(alignedRatio, greaterThanOrEqualTo(0.75),
        reason: 'kick 对齐率 ${(alignedRatio * 100).toStringAsFixed(1)}% 低于 75% 门限');

    // 检测延迟：上升沿触发后 |Δ| ≤ 70ms 的比例应 ≥ 60%（改造前中位 Δ≈50-70ms）
    final deltas = <double>[];
    for (final t in kickTriggers) {
      deltas.add(_nearest(kicks, t).$2);
    }
    deltas.sort();
    final medianDelta = deltas[deltas.length ~/ 2];
    expect(medianDelta, lessThanOrEqualTo(70),
        reason: 'kick 检测延迟中位数 ${medianDelta.toStringAsFixed(0)}ms 超过 70ms');
  });
}

/// (最近事件时刻, 距离 ms)
(double, double) _nearest(List<double> events, double tMs) {
  var best = 1e9;
  var bestT = 0.0;
  for (final e in events) {
    final d = (e * 1000 - tMs).abs();
    if (d < best) {
      best = d;
      bestT = e;
    }
  }
  return (bestT, best);
}
