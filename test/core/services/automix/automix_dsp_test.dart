import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/automix/automix_dsp.dart';

/// 合成 click track：每 [periodSamples] 个样本放一个 200 样本的衰减脉冲。
Int16List clickTrack({
  required int sampleRate,
  required double bpm,
  required double seconds,
}) {
  final n = (sampleRate * seconds).round();
  final out = Int16List(n);
  final period = (sampleRate * 60.0 / bpm).round();
  const clickLen = 200;
  for (var t = 0; t + clickLen < n; t += period) {
    for (var k = 0; k < clickLen; k++) {
      final env = math.exp(-k / 40.0);
      out[t + k] = (30000 * env * (k % 2 == 0 ? 1 : -1)).round();
    }
  }
  return out;
}

void main() {
  group('onsetEnvelope', () {
    test('静音输入的包络全为 0', () {
      final env = onsetEnvelope(Int16List(48000), sampleRate: 48000);
      expect(env, isNotEmpty);
      expect(env.every((v) => v == 0), isTrue);
    });

    test('窗口太短（不足 1 帧）返回空列表，不抛异常', () {
      expect(onsetEnvelope(Int16List(10), sampleRate: 48000), isEmpty);
    });

    test('120BPM click track：包络峰值数量 ≈ 拍数（±2）', () {
      const sr = 48000;
      final pcm = clickTrack(sampleRate: sr, bpm: 120, seconds: 20);
      final env = onsetEnvelope(pcm, sampleRate: sr);
      final frameRate = envFrameRate(sampleRate: sr);
      var peaks = 0;
      var maxV = 0.0;
      for (final v in env) {
        if (v > maxV) maxV = v;
      }
      for (var i = 1; i < env.length - 1; i++) {
        if (env[i] > env[i - 1] && env[i] >= env[i + 1] && env[i] > maxV * 0.3) {
          peaks++;
        }
      }
      // 20s @120BPM = 40 拍
      expect(peaks, greaterThan(36));
      expect(peaks, lessThan(44));
      expect(frameRate, closeTo(43.48, 0.5));
    });
  });

  group('detectBpm', () {
    test('120BPM click track 测出 ≈120（±4）且置信度高', () {
      const sr = 48000;
      final env = onsetEnvelope(
        clickTrack(sampleRate: sr, bpm: 120, seconds: 20),
        sampleRate: sr,
      );
      final r = detectBpm(env, frameRate: envFrameRate(sampleRate: sr));
      expect(r.bpm, closeTo(120, 4));
      expect(r.confidence, greaterThan(0.5));
    });

    test('90BPM 与 150BPM 也落在各自真值附近', () {
      const sr = 48000;
      for (final bpm in [90.0, 150.0]) {
        final env = onsetEnvelope(
          clickTrack(sampleRate: sr, bpm: bpm, seconds: 20),
          sampleRate: sr,
        );
        final r = detectBpm(env, frameRate: envFrameRate(sampleRate: sr));
        expect(r.bpm, closeTo(bpm, 6), reason: 'bpm=$bpm');
      }
    });

    test('静音/过短输入返回 0 且置信度 0（不能返回 NaN）', () {
      final r = detectBpm(const <double>[], frameRate: 43.0);
      expect(r.bpm, 0);
      expect(r.confidence, 0);
      final flat = detectBpm(List<double>.filled(50, 0.0), frameRate: 43.0);
      expect(flat.bpm, 0);
    });
  });

  group('normalizeBpm', () {
    test('过低倍增、过高倍降，落到 [70,180]', () {
      expect(normalizeBpm(60), closeTo(120, 1e-9));
      expect(normalizeBpm(200), closeTo(100, 1e-9));
      expect(normalizeBpm(124), closeTo(124, 1e-9));
    });

    test('非法值返回 0', () {
      expect(normalizeBpm(0), 0);
      expect(normalizeBpm(-5), 0);
      expect(normalizeBpm(double.nan), 0);
    });
  });

  group('firstOnsetSec', () {
    test('click track 的首拍位置接近 0（±1 帧）', () {
      const sr = 48000;
      final env = onsetEnvelope(
        clickTrack(sampleRate: sr, bpm: 120, seconds: 20),
        sampleRate: sr,
      );
      final t = firstOnsetSec(env, envFrameRate(sampleRate: sr));
      expect(t, lessThan(0.1));
    });

    test('全零包络返回 0', () {
      expect(firstOnsetSec(List<double>.filled(100, 0.0), 43.0), 0);
    });
  });

  group('buildBeatGrid', () {
    test('从首拍起按拍长外推，不越过 untilSec', () {
      final grid = buildBeatGrid(
        firstBeatSec: 0.5, bpm: 120, untilSec: 3.0,
      );
      expect(grid.first, closeTo(0.5, 1e-9));
      expect(grid.length, 6); // 0.5,1.0,...,3.0
      expect(grid.last, closeTo(3.0, 1e-9));
    });

    test('BPM 非法或区间为空返回空列表', () {
      expect(buildBeatGrid(firstBeatSec: 0, bpm: 0, untilSec: 10), isEmpty);
      expect(buildBeatGrid(firstBeatSec: 5, bpm: 120, untilSec: 1), isEmpty);
    });
  });

  group('rhythmDensity', () {
    test('8 onsets/s 记满 1.0，2 onsets/s 得 0.25，钳在 [0,1]', () {
      expect(rhythmDensity(80, 10.0), closeTo(1.0, 1e-9));
      expect(rhythmDensity(20, 10.0), closeTo(0.25, 1e-9));
      expect(rhythmDensity(500, 10.0), 1.0);
      expect(rhythmDensity(1, 10.0), closeTo(0.0125, 1e-9));
    });

    test('时长非正返回 0（不能除零）', () {
      expect(rhythmDensity(10, 0), 0);
    });
  });

  group('loudnessDbfs', () {
    test('满幅正弦 ≈ -3 dBFS', () {
      final pcm = Int16List(48000);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (32767 * math.sin(2 * math.pi * 440 * i / 48000)).round();
      }
      expect(loudnessDbfs(pcm), closeTo(-3.01, 0.3));
    });

    test('静音返回 -120（钳位下限），不是 NaN', () {
      expect(loudnessDbfs(Int16List(48000)), closeTo(-120, 1e-9));
    });
  });
}
