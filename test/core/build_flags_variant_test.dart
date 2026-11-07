// 构建变体旗标的编译期语义（lite 默认 / full 全功能）。
//
// 这三个常量都由 --dart-define 决定、被 AOT 当 const 树摇，因此**默认构建**（lite）
// 下 3D 封面与端侧分离必须整体为 false：APK 里既没有推理运行时，也没有相关 UI。
//
// 断言 full 语义时用：
//   flutter test --dart-define=MD3_FULL=true test/core/build_flags_variant_test.dart
// （apply 前的 dart-define 只在编译期生效，运行期无法覆盖，故用 skip 区分两组）。
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/services/depth_cover_feature.dart';

void main() {
  group('lite（默认构建，不带任何 define）', () {
    test('kTvBuild / kFullBuild 均为 false', () {
      expect(kTvBuild, isFalse, reason: '默认构建不是 TV 包');
      expect(kFullBuild, isFalse, reason: '默认构建是精简包');
    });

    test('端侧分离不编入', () {
      expect(
        kStemSeparationAvailable,
        isFalse,
        reason: 'lite 包不含分离：服务 init 直接返回 false，UI 整块树摇剔除',
      );
    });

    test('3D 封面不可用（两个 define 都没带）', () {
      expect(
        kDepthCoverAvailable,
        isFalse,
        reason: 'lite 包不含 onnxruntime 与深度模型，3D 设置组必须整块隐藏',
      );
      expect(kDepthDartFfi, isFalse, reason: 'FFI 后端是 kDepthCoverAvailable 的子集');
    });
  }, skip: kFullBuild || kTvBuild);

  group('full（--dart-define=MD3_FULL=true）', () {
    test('kFullBuild 为 true 且非 TV', () {
      expect(kFullBuild, isTrue);
      expect(kTvBuild, isFalse, reason: 'full 与 tv 是互斥的两档（tv 不带推理运行时）');
    });

    test('端侧分离与 3D 封面同时可用', () {
      expect(kStemSeparationAvailable, isTrue, reason: 'full 包 = 3D + 分离捆绑');
      expect(kDepthCoverAvailable, isTrue, reason: 'MD3_FULL 同时打开 3D');
    });

    test('Android 侧走 channel 后端（不是 Dart FFI）', () {
      expect(kDepthBackend, 'channel');
      expect(kDepthDartFfi, isFalse, reason: 'FFI 只在 Windows -With3D 生效');
    });
  }, skip: !kFullBuild);
}
