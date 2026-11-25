import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/render_engine_info.dart';

void main() {
  test('构建期 define 是渲染引擎的桌面兜底真相源', () {
    // 测试环境无 Android 原生通道；结果必须等于编译期 MD3_RENDER_ENGINE。
    // 当前测试 runner 未传该 define → 默认 impeller（Flutter 桌面默认）。
    expect(kRenderEngineDefine, isA<String>());
    expect(['skia', 'impeller'], contains(kRenderEngineDefine));
    expect(
      currentRenderEngineSync,
      kRenderEngineDefine == 'skia' ? 'skia' : 'impeller',
    );
  });

  test('currentRenderEngine 在非 Android 环境返回构建期 define', () async {
    final engine = await currentRenderEngine();
    expect(['skia', 'impeller'], contains(engine));
    expect(
      engine,
      kRenderEngineDefine == 'skia' ? 'skia' : 'impeller',
      reason: 'Windows/测试环境不读原生通道，必须如实反映构建期 define',
    );
  });
}