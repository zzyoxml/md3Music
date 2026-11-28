import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 着色器的 uniform 是一段**按声明顺序**填的裸 float 数组：Dart 侧 `setFloat(i++, …)`
/// 多写一个或少写一个，只有真机上才会抛 `RangeError`（主机没有 GPU，测试里跑不到这条
/// 分支），而它是每帧都抛 —— 屏幕上就是卡住不动。
///
/// 这里把 `shaders/*.frag` 的 uniform 声明加起来，跟 Dart 侧写的数量对齐。
void main() {
  /// 声明的 float 宽度；`sampler2D` 不算（它走 `setImageSampler`，单独编号）。
  int widthOf(String type) => switch (type) {
    'float' => 1,
    'vec2' => 2,
    'vec3' => 3,
    'vec4' => 4,
    'mat4' => 16,
    _ => throw ArgumentError('未知 uniform 类型 $type'),
  };

  int countFloats(String path) {
    final source = File(path).readAsStringSync();
    final uniforms = RegExp(r'uniform\s+(float|vec2|vec3|vec4|mat4)\s+\w+\s*;').allMatches(source);
    var total = 0;
    for (final match in uniforms) {
      total += widthOf(match.group(1)!);
    }
    return total;
  }

  test('lens 着色器：22 个 float（2 + 5×vec4），对应 _setLens', () {
    // _setLens 依次写：uSize(2)、uFront、uShape、uMotion、uLens、uBlur（各 vec4）。
    expect(countFloats('shaders/distortion_wave_lens.frag'), 22);
  });

  test('band 着色器：98 个 float，对应 _paintBand', () {
    // uSize(2) + uFront/uShape/uGlow/uKind/uRimA/uRimB/uRimC(7×4)
    // + uP0..uP7(8×4) + uAhead/uBehind(2×4) + uL0..uL6(7×4)。
    expect(countFloats('shaders/distortion_wave_band.frag'), 98);
  });

  test('共享的距离场被两个着色器引用', () {
    for (final name in ['distortion_wave_lens.frag', 'distortion_wave_band.frag']) {
      final source = File('shaders/$name').readAsStringSync();
      expect(
        source.contains('#include "distortion_wave_field.glsl"'),
        isTrue,
        reason: '$name 没有引用共享距离场：波前、模糊、颜色会各算一套',
      );
    }
    expect(File('shaders/distortion_wave_field.glsl').existsSync(), isTrue);
  });
}
