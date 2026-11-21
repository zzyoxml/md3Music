import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/fx/waves/distortion_wave_style.dart';

/// 波边缘 SDF 圆角的设备取值口径（Zen 波两端共用：Windows 取窗口 DWM 圆角，
/// 移动端取 displayCornerRadii）。纯函数数值断言。
void main() {
  group('maxCornerRadiusOf', () {
    test('null（未上报）→ 0，与方角同口径', () {
      expect(DistortionWaveStyle.maxCornerRadiusOf(null), 0.0);
    });

    test('方角屏 → 0', () {
      expect(DistortionWaveStyle.maxCornerRadiusOf(BorderRadius.zero), 0.0);
    });

    test('对称圆角 → 该半径', () {
      expect(DistortionWaveStyle.maxCornerRadiusOf(BorderRadius.circular(24)), 24);
    });

    test('四角非对称 → 取最大', () {
      final radii = BorderRadius.only(
        topLeft: Radius.circular(10),
        topRight: Radius.circular(20),
        bottomRight: Radius.circular(30),
        bottomLeft: Radius.circular(40),
      );
      expect(DistortionWaveStyle.maxCornerRadiusOf(radii), 40);
    });

    test('椭圆角 dx≠dy → 取较大者', () {
      final radii = BorderRadius.only(bottomRight: Radius.elliptical(30, 18));
      expect(DistortionWaveStyle.maxCornerRadiusOf(radii), 30);
    });
  });
}
