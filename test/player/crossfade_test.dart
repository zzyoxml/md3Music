import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_service_io.dart';

void main() {
  group('crossfadeGains', () {
    test('端点：起点全是旧歌，终点全是新歌', () {
      final start = crossfadeGains(0);
      expect(start.outGain, closeTo(1.0, 1e-9));
      expect(start.inGain, closeTo(0.0, 1e-9));

      final end = crossfadeGains(1);
      expect(end.outGain, closeTo(0.0, 1e-9));
      expect(end.inGain, closeTo(1.0, 1e-9));
    });

    test('中点两路等增益 ≈0.707（等功率，不是线性的 0.5）', () {
      final mid = crossfadeGains(0.5);
      expect(mid.outGain, closeTo(0.70710678, 1e-6));
      expect(mid.inGain, closeTo(0.70710678, 1e-6));
    });

    test('全程功率恒定：outGain² + inGain² == 1', () {
      for (var i = 0; i <= 20; i++) {
        final g = crossfadeGains(i / 20);
        expect(g.outGain * g.outGain + g.inGain * g.inGain, closeTo(1.0, 1e-9));
      }
    });

    test('越界的 t 被截断，不产生负增益或过冲', () {
      expect(crossfadeGains(-1).outGain, closeTo(1.0, 1e-9));
      expect(crossfadeGains(-1).inGain, closeTo(0.0, 1e-9));
      expect(crossfadeGains(2).outGain, closeTo(0.0, 1e-9));
      expect(crossfadeGains(2).inGain, closeTo(1.0, 1e-9));
    });

    test('交叉点两首响度相当——「当前歌曲」在此刻换歌才不违和', () {
      final g = crossfadeGains(kCrossfadeCrossoverProgress);
      expect(g.inGain, closeTo(g.outGain, 1e-9));
    });

    test('交叉点之前旧歌更响，之后新歌更响', () {
      final before = crossfadeGains(kCrossfadeCrossoverProgress - 0.2);
      expect(before.outGain, greaterThan(before.inGain));
      final after = crossfadeGains(kCrossfadeCrossoverProgress + 0.2);
      expect(after.inGain, greaterThan(after.outGain));
    });
  });

  group('decideCrossfadePhase', () {
    const fade = Duration(seconds: 6);
    const songLength = Duration(minutes: 4);

    CrossfadePhase phaseAt(
      Duration position, {
      Duration? duration = songLength,
      Duration crossfadeDuration = fade,
      bool enabled = true,
      bool prepared = false,
      bool fading = false,
    }) =>
        decideCrossfadePhase(
          position: position,
          duration: duration,
          crossfadeDuration: crossfadeDuration,
          enabled: enabled,
          prepared: prepared,
          fading: fading,
        );

    test('远离结尾时什么都不做', () {
      expect(phaseAt(Duration.zero), CrossfadePhase.idle);
      expect(phaseAt(const Duration(minutes: 2)), CrossfadePhase.idle);
    });

    test('进入"淡化时长 + 预加载提前量"窗口后开始预加载', () {
      // 剩余 9s = fade(6s) + lead(3s) 的边界
      expect(
        phaseAt(songLength - (fade + kCrossfadePrepareLead)),
        CrossfadePhase.prepare,
      );
      // 剩余 10s，还没进窗口
      expect(
        phaseAt(songLength -
            (fade + kCrossfadePrepareLead + const Duration(seconds: 1))),
        CrossfadePhase.idle,
      );
    });

    test('已预加载完成时，窗口内不重复预加载', () {
      expect(
        phaseAt(songLength - const Duration(seconds: 8), prepared: true),
        CrossfadePhase.idle,
      );
    });

    test('剩余时间进入淡化时长且已预加载 → 开始淡化', () {
      expect(
        phaseAt(songLength - fade, prepared: true),
        CrossfadePhase.start,
      );
      expect(
        phaseAt(songLength - const Duration(seconds: 2), prepared: true),
        CrossfadePhase.start,
      );
    });

    test('到点了但预加载没完成 → 补一次预加载，不直接起播', () {
      expect(phaseAt(songLength - fade), CrossfadePhase.prepare);
    });

    test('淡化已在进行中 → 不再触发', () {
      expect(
        phaseAt(songLength - const Duration(seconds: 2),
            prepared: true, fading: true),
        CrossfadePhase.idle,
      );
    });

    test('前置条件不满足（enabled=false）→ 全程 idle', () {
      expect(
        phaseAt(songLength - const Duration(seconds: 2),
            prepared: true, enabled: false),
        CrossfadePhase.idle,
      );
    });

    test('时长未知 / 为零 → idle（无法判断结尾在哪）', () {
      expect(phaseAt(const Duration(seconds: 1), duration: null),
          CrossfadePhase.idle);
      expect(phaseAt(Duration.zero, duration: Duration.zero),
          CrossfadePhase.idle);
    });

    test('淡化时长为零 → idle', () {
      expect(
        phaseAt(songLength - const Duration(seconds: 1),
            crossfadeDuration: Duration.zero),
        CrossfadePhase.idle,
      );
    });

    test('曲子太短（< 2×淡化 + 余量）→ 不叠加', () {
      // 6s 淡化需要至少 6*2+2 = 14s
      const short = Duration(seconds: 13);
      expect(phaseAt(const Duration(seconds: 8), duration: short),
          CrossfadePhase.idle);
      // 刚好够长
      const justEnough = Duration(seconds: 14);
      expect(
        phaseAt(justEnough - fade, duration: justEnough, prepared: true),
        CrossfadePhase.start,
      );
    });

    test('已越过结尾（兜底路径）→ idle，交给原有 completed 流程', () {
      expect(
        phaseAt(songLength, prepared: true),
        CrossfadePhase.idle,
      );
      expect(
        phaseAt(songLength + const Duration(seconds: 1), prepared: true),
        CrossfadePhase.idle,
      );
    });
  });
}
