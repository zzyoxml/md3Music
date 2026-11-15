import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android 偏好插件锁定兼容旧数据的非 JNI 版本', () {
    // 2.5.0 的 JNI 解码不支持旧原生偏好中的 Integer，会阻断首帧前的加载。
    // 不能只依赖 lock：公开导出不携带 lock，重新解析依赖也必须保持兼容。
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^  shared_preferences_android: 2\.4\.28\s*$', multiLine: true)
          .hasMatch(pubspec),
      isTrue,
    );
  });
}
