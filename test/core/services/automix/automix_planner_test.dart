import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/automix/automix_analysis.dart';
import 'package:md3music/core/services/automix/automix_planner.dart';

AutomixAnalysis _a({
  double bpm = 120,
  double conf = 0.8,
  double first = 0.0,
  double dens = 0.5,
  double loud = -12,
}) => AutomixAnalysis(
      key: 'k', bpm: bpm, confidence: conf, firstBeatSec: first,
      rhythmDensity: dens, loudnessDbfs: loud, windowMs: 25000, analyzedAtMs: 1,
    );

const userFade = Duration(seconds: 8);

void main() {
  group('planAutomix 回退', () {
    test('任一侧分析缺失 → fallback，时长 = 用户设置', () {
      final p = planAutomix(
        outgoing: _a(), incoming: null,
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.strategy, AutomixStrategy.fallback);
      expect(p.fadeDuration, userFade);
      expect(p.fadeStartPosition, const Duration(seconds: 192));
      expect(p.incomingRate, 1.0);
    });

    test('置信度不足 → fallback', () {
      final p = planAutomix(
        outgoing: _a(conf: 0.1), incoming: _a(),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.strategy, AutomixStrategy.fallback);
    });

    test('duration 未知 → fallback，且起点 = 当前位置（立即起淡，不产生未来/负起点）', () {
      final p = planAutomix(
        outgoing: _a(), incoming: _a(),
        position: const Duration(seconds: 100),
        duration: null,
        userFade: userFade,
      );
      expect(p.strategy, AutomixStrategy.fallback);
      expect(p.fadeStartPosition, const Duration(seconds: 100));
    });
  });

  group('planAutomix 变速倍率', () {
    test('124 → 120 BPM：倍率 = 124/120，未超 ±6% 钳位', () {
      final p = planAutomix(
        outgoing: _a(bpm: 124), incoming: _a(bpm: 120),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.incomingRate, closeTo(124 / 120, 1e-9));
      expect(p.strategy, AutomixStrategy.beatmatch);
    });

    test('120 → 127 BPM：倍率 0.945 仍在钳位区间内，保持 beatmatch', () {
      final p = planAutomix(
        outgoing: _a(bpm: 120), incoming: _a(bpm: 127),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.incomingRate, closeTo(120 / 127, 1e-9));
      expect(p.incomingRate, greaterThanOrEqualTo(kAutomixMinRate));
      expect(p.strategy, AutomixStrategy.beatmatch);
    });

    test('120 → 200 BPM：超出 ±6% → 降级 gradualBlend 且不变速（半吊子变速最难听）', () {
      final p = planAutomix(
        outgoing: _a(bpm: 120), incoming: _a(bpm: 200),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.strategy, AutomixStrategy.gradualBlend);
      expect(p.incomingRate, 1.0);
    });

    test('BPM 几乎相同（差 <0.5%）不做变速', () {
      final p = planAutomix(
        outgoing: _a(bpm: 120), incoming: _a(bpm: 120.3),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.incomingRate, 1.0);
    });

    test('BPM 几乎相同仍判为 beatmatch：不变速但拍点对齐有效', () {
      // 回归：真机实测 119.8 → 120.4（差 0.5%）被误判为 gradualBlend，
      // 因为判据写成了「需要变速」而不是「在同一节拍体系内」。
      final p = planAutomix(
        outgoing: _a(bpm: 119.8), incoming: _a(bpm: 120.4),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.strategy, AutomixStrategy.beatmatch);
      expect(p.incomingRate, 1.0, reason: '差 0.5% 不值得变速');
    });
  });

  group('planAutomix 自适应时长', () {
    test('高节奏密度（0.8）缩短到 0.5×', () {
      final p = planAutomix(
        outgoing: _a(dens: 0.8), incoming: _a(dens: 0.8),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.fadeDuration, const Duration(seconds: 4));
    });

    test('低节奏密度（0.2）不打折，且不越过用户设置（只缩短不延长）', () {
      final p = planAutomix(
        outgoing: _a(dens: 0.2), incoming: _a(dens: 0.2),
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.fadeDuration, userFade);
    });

    test('绝不延长用户设置：无论密度多低，淡化都不超过 userFade', () {
      // 回归：曾把低密度延长到 1.15×，导致起淡点被 decideCrossfadePhase 卡住，
      // 斜坡在曲尾被截断（音量停在半路突然切歌）。
      for (final dens in [0.0, 0.1, 0.2, 0.34]) {
        final p = planAutomix(
          outgoing: _a(dens: dens), incoming: _a(dens: dens),
          position: const Duration(seconds: 100),
          duration: const Duration(seconds: 200),
          userFade: userFade,
        );
        expect(
          p.fadeDuration,
          lessThanOrEqualTo(userFade),
          reason: 'density=$dens',
        );
      }
    });

    test('时长钳在 [2s, 12s] 且不超过曲长的 1/3', () {
      final short = planAutomix(
        outgoing: _a(dens: 0.2), incoming: _a(),
        position: const Duration(seconds: 5),
        duration: const Duration(seconds: 30),
        userFade: const Duration(seconds: 12),
      );
      expect(short.fadeDuration, lessThanOrEqualTo(const Duration(seconds: 10)));
    });
  });

  group('planAutomix 拍点吸附', () {
    test('起淡点吸附到最近的拍点，偏移不超过半拍', () {
      final p = planAutomix(
        outgoing: _a(bpm: 120, first: 0.0), incoming: _a(),
        position: const Duration(seconds: 180),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      // 理想起点 192s；120BPM 拍长 0.5s，192 本身就在拍点上
      expect(p.fadeStartPosition, const Duration(seconds: 192));
    });

    test('吸附后的起点不会早于当前位置（否则立刻起淡）', () {
      final p = planAutomix(
        outgoing: _a(bpm: 120, first: 0.25), incoming: _a(),
        position: const Duration(seconds: 191),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(p.fadeStartPosition, greaterThanOrEqualTo(const Duration(seconds: 191)));
    });

    test('吸附失败（拍点全在将来/过去）时退回理想起点', () {
      final p = planAutomix(
        outgoing: _a(bpm: 120, first: 0.3), incoming: _a(),
        position: const Duration(seconds: 191),
        duration: const Duration(seconds: 200),
        userFade: userFade,
      );
      expect(
        p.fadeStartPosition.inMicroseconds,
        inInclusiveRange(
          const Duration(seconds: 191).inMicroseconds,
          const Duration(seconds: 194).inMicroseconds,
        ),
      );
    });
  });
}
