import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows 3D 封面的「多层路径」契约（打开功能后整窗无响应的修复配套）。
///
/// Windows 不走 runtime fragment shader（见 `DepthCoverHost._useShaderPath` 的
/// 平台门控与 windows-desktop.md W5.7），**多层路径是桌面端主路径**。由此带出两条
/// 必须钉住的接线约束：
///
/// 1. `_generateLayers` 必须接 MI-GAN（`_neuralRefine`）：否则设置页「AI 背景修补」
///    在 Windows 上就是「看得见按不动」的死开关（仓内明确禁止该模式）。
/// 2. MI-GAN 必须在 `inpaintBackground` **之后**、`splitLayer` **之前**调用：
///    layer0 切的是修补后的背景（`inpaint.filled`），顺序错了等于白调。
///
/// 用源码结构断言而不是跑真实推理：`depth_worker.dart` 的生成函数依赖 ORT 会话，
/// 纯 Dart 测试环境无法构造；而这里的实质是「调用点在不在、顺序对不对」。
void main() {
  final source = File('lib/services/depth/depth_worker.dart').readAsStringSync();
  final code = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('_generateLayers 必须调用 _neuralRefine（否则 Windows 的 AI 修补开关无效）',
      () {
    final start = code.indexOf('DepthReply _generateLayers(');
    expect(start, greaterThan(-1), reason: '未找到 _generateLayers');
    // 取到下一个顶层函数边界（shutdown/_loadDepth/_generateDepth 之后）
    final end = code.indexOf('\nDepthReply ', start + 1);
    final body = end == -1 ? code.substring(start) : code.substring(start, end);
    expect(body.contains('_neuralRefine('), isTrue,
        reason: '多层路径必须接 MI-GAN：Windows 主路径就是多层，否则「AI 背景修补」'
            '开关在桌面端是死开关');
    expect(body.contains('_inpaintSession'), isTrue,
        reason: '会话按需懒加载：没开会话就跳过（不强行假设已加载）');
  });

  test('MI-GAN 调用点必须在 inpaintBackground 之后、splitLayer 之前', () {
    final start = code.indexOf('DepthReply _generateLayers(');
    final end = code.indexOf('\nDepthReply ', start + 1);
    final body = end == -1 ? code.substring(start) : code.substring(start, end);
    final inpaintIdx = body.indexOf('inpaintBackground(');
    final miganIdx = body.indexOf('_neuralRefine(');
    final splitIdx = body.indexOf('splitLayer(');
    expect(inpaintIdx, greaterThan(-1));
    expect(splitIdx, greaterThan(inpaintIdx),
        reason: 'splitLayer 必须在 inpaintBackground 之后（layer0 用修补后的背景）');
    expect(miganIdx, greaterThan(inpaintIdx),
        reason: 'MI-GAN 必须在 push-pull 之后（它是在修补结果上做细化）');
    expect(miganIdx, lessThan(splitIdx),
        reason: 'MI-GAN 必须在切割之前：layer0 要切细化后的背景');
  });

  test('深度推理不得走 OrtSession.fromFile（Windows 宽字符路径会失败）', () {
    expect(code.contains('fromFile('), isFalse,
        reason: 'ORT 的 Windows 版 CreateSession 走 ORTCHAR_T（wchar_t），而 Dart 侧 '
            'toNativeUtf8 是 UTF-8 字节 → 路径错位成「File doesn\'t exist」；'
            '必须用 fromBuffer（CreateSessionFromArray）');
    expect(code.contains('OrtSession.fromBuffer('), isTrue);
  });

  // ── 修补底板（「图片修补没生效」的修复）────────────────────────────────────
  //
  // 三条深度带铺满 0..1、合成后 = 原图完整；修补结果只进 layer0 的「背景带」，
  // 而主体（深度 ≈0.9）永远不在那一带里 → 不额外产出整幅修补底板，修补结果
  // 就**不会被任何一层绘制**，界面表现为「修补没生效」。
  test('_generateLayers 必须产出修补底板 bg_fill.png 并回填 bgFillPath', () {
    final start = code.indexOf('DepthReply _generateLayers(');
    final end = code.indexOf('\nDepthReply ', start + 1);
    final body = end == -1 ? code.substring(start) : code.substring(start, end);
    expect(body.contains("'bg_fill.png'"), isTrue,
        reason: '底板文件名必须与 DepthCoverCache._layerBackgroundName 一致');
    expect(body.contains('bgFillPath'), isTrue,
        reason: '必须回填 DepthReply.bgFillPath，宿主/缓存据此取底板');
    // 底板必须来自修补结果（inpaint.filled），不是原图
    final writeStart = body.indexOf('platePath =');
    final writeEnd = body.indexOf('final paths', writeStart);
    final writeStmt =
        writeEnd == -1 ? body.substring(writeStart) : body.substring(writeStart, writeEnd);
    expect(writeStmt.contains('inpaint.filled'), isTrue,
        reason: '底板必须写修补后的像素，否则等于又贴了一张原图');
  });
}
