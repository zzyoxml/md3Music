import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/fx/waves/distortion_wave_style.dart';
import 'package:md3music/core/fx/waves/wave_front.dart';

/// 波前几何是纯函数，跑在主机上就能校对；着色器本身要真机才看得出好坏，
/// 但"波会不会走到一半被路由收掉""半径会不会回缩"这类错在这里就能挡住。
void main() {
  const screen = Size(412, 915);

  final presets = <String, DistortionWaveStyle>{
    'vertical': DistortionWaveStyle.vertical,
    'horizontal': DistortionWaveStyle.horizontal,
    'center': DistortionWaveStyle.center,
    'screenCenter': DistortionWaveStyle.screenCenter,
  };

  group('时长', () {
    for (final entry in presets.entries) {
      test('${entry.key}：不短于 anticipation + travel', () {
        final style = entry.value;
        expect(
          style.duration,
          greaterThanOrEqualTo(style.anticipation + style.travel),
          reason: '否则路由会在波前走到一半时就把这条路由收掉，屏幕上只剩半张新页',
        );
      });
    }

    test('screenCenter：整屏版本约 2.4s，收回按 returnSpeed 折算', () {
      final style = DistortionWaveStyle.screenCenter;
      expect(style.duration, closeTo(2.4, 0.05));
      expect(style.duration / style.returnSpeed, closeTo(1.66, 0.05));
    });
  });

  group('波前', () {
    test('一个环从图标扩散：没有脊线，源的半径内不形变', () {
      final source = Rect.fromLTWH(360, 24, 44, 44);
      final front = WaveFront(
        progress: 0.5,
        source: source,
        size: screen,
        style: DistortionWaveStyle.screenCenter,
      );
      expect(front.ring, isTrue);
      expect(front.spine, 0);
      expect(front.squash, 1, reason: '环不该压扁');
      expect(front.hold, 22, reason: '源自己的半径不参与形变');
    });

    test('发射前不画着一面，发射后才算 launched', () {
      final style = DistortionWaveStyle.screenCenter;
      final before = WaveFront(
        progress: 0.02,
        source: Rect.fromCenter(center: screen.center(Offset.zero), width: 44, height: 44),
        size: screen,
        style: style,
      );
      final after = WaveFront(
        progress: 0.5,
        source: Rect.fromCenter(center: screen.center(Offset.zero), width: 44, height: 44),
        size: screen,
        style: style,
      );
      expect(before.launched, isFalse);
      expect(before.energy, 0);
      expect(after.launched, isTrue);
      expect(after.energy, greaterThan(0));
    });

    test('发射后半径只增不减（否则内容会往回缩一下）', () {
      final style = DistortionWaveStyle.screenCenter;
      final source = Rect.fromLTWH(360, 24, 44, 44);
      var last = 0.0;
      for (var p = 0.2; p <= 1.0001; p += 0.02) {
        final front = WaveFront(progress: p, source: source, size: screen, style: style);
        expect(front.radius, greaterThanOrEqualTo(last - 0.001), reason: 'p=$p 处半径回缩了');
        last = front.radius;
      }
    });

    test('走完时波前已经扫过整屏，中途没有', () {
      final style = DistortionWaveStyle.screenCenter;
      final source = Rect.fromLTWH(360, 24, 44, 44);
      WaveFront at(double p) => WaveFront(progress: p, source: source, size: screen, style: style);
      // 缓动是快出慢收：行程走过三成时波前就扫完屏了（约 1.1s，新页这时就能点），
      // 剩下的时间是边缘色和细线在自己淡。
      expect(at(0.3).hasCleared, isFalse);
      expect(at(0.9).hasCleared, isTrue, reason: '没扫过就永远不交触摸，新页会一直点不动');
    });

    test('缓动两端落在 0 和 1', () {
      const easing = DistortionWaveEasing(0.22, 1, 0.36, 1);
      expect(easing.transform(0), 0);
      expect(easing.transform(1), 1);
      // 单调
      var last = 0.0;
      for (var t = 0.0; t <= 1.0; t += 0.05) {
        final v = easing.transform(t);
        expect(v, greaterThanOrEqualTo(last - 1e-9));
        last = v;
      }
    });
  });

  group('小点', () {
    test('出发前都在源附近，不跑到屏幕外乱飞', () {
      final style = DistortionWaveStyle.screenCenter;
      final source = Rect.fromLTWH(360, 24, 44, 44);
      final front = WaveFront(progress: 0.1, source: source, size: screen, style: style);
      for (var i = 0; i < style.particleCount; i++) {
        final p = WaveParticle(i, style).point(front, source);
        expect(p.dx.isFinite && p.dy.isFinite, isTrue);
        expect(p.dx, inInclusiveRange(-200, screen.width + 200));
        expect(p.dy, inInclusiveRange(-200, screen.height + 200));
      }
    });
  });
}
