import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 顶层悬浮层必须与「设计像素锚点」同空间（Windows 标题栏回归）。
///
/// **背景**：`WindowsWindowFrame` 在 Windows 上先放一条 32dp 标题栏、再
/// `Expanded` 正文；而 App 级设计像素锚点（`DisplayScaleReference`）包住整个
/// 客户区。封面探针 / MiniPlayer / 底栏量到的矩形都含标题栏那 32dp，浮层若挂在
/// Frame 内部，就会把锚点坐标当正文局部坐标画 —— 飞行封面整段低 32dp、落位时
/// 向上跳，「下一首播放」跳水球与底栏形态交棒同理。
///
/// 这里用**源码结构断言**而不是 widget 测试：`MaterialApp.builder` 的根层依赖
/// 一整串 Provider / TV 分支 / 车机面板，构造成本高且脆弱；而本条的实质是
/// 「这几层不得出现在 WindowsWindowFrame 调用块里」，源码断言更直接。
/// 与 `desktop_shell_toolbar_removed_test.dart` 的选择同一理由。
void main() {
  final source = File('lib/app.dart').readAsStringSync();
  // 剔行注释：图层名在注释里也出现，避免注释文字冒充挂载点。
  final code = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  const layers = <String>[
    'DlnaCastingOverlay',
    'BottomBarMorphOverlay',
    'PlayerDragOverlay',
    'PlayerCoverMorphLayer',
    'PlaylistCoverFlightLayer',
    'PlayNextFlightLayer',
  ];

  /// 从 `(` 的下标出发找配对的 `)`，找不到返回 -1。
  int matchingParen(String text, int openIndex) {
    var depth = 0;
    for (var i = openIndex; i < text.length; i++) {
      final ch = text[i];
      if (ch == '(') depth++;
      if (ch == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  test('顶层悬浮层不得挂在 WindowsWindowFrame 之内', () {
    final start = code.indexOf('WindowsWindowFrame(');
    expect(start, greaterThan(-1), reason: '未找到 WindowsWindowFrame 挂载点');
    final openIndex = start + 'WindowsWindowFrame'.length;
    final end = matchingParen(code, openIndex);
    expect(end, greaterThan(openIndex));
    final frameBlock = code.substring(start, end + 1);

    for (final layer in layers) {
      expect(
        frameBlock.contains(layer),
        isFalse,
        reason: '$layer 必须与设计像素锚点同空间：'
            '挂在 WindowsWindowFrame 内部会被标题栏整体下移 32dp，'
            '封面飞行 / 跳水球 / 底栏交棒落位时向上跳。',
      );
      expect(
        code.indexOf('$layer('),
        greaterThan(end),
        reason: '$layer 应作为 WindowsWindowFrame 的同级浮层，出现在它之后',
      );
    }
  });

  test('顶层悬浮层组仍包在透明 Material 内（InkWell 需要 Material 祖先）', () {
    final start = code.indexOf('WindowsWindowFrame(');
    final end = matchingParen(code, start + 'WindowsWindowFrame'.length);
    final groupStart = code.indexOf('const Positioned.fill(', end);
    expect(groupStart, greaterThan(end), reason: '未找到浮层组的 Positioned.fill');

    final groupEnd = code.indexOf('PlayNextFlightLayer(', groupStart);
    expect(groupEnd, greaterThan(groupStart));
    // 末尾图层本身也要纳入断言窗口。
    final group = code.substring(
      groupStart,
      groupEnd + 'PlayNextFlightLayer('.length,
    );

    expect(
      group.contains('MaterialType.transparency'),
      isTrue,
      reason: '浮层不在 Scaffold 内，必须留一层透明 Material 兜底 '
          '（Material.of：InkWell tapDown 取不到祖先会崩）',
    );
    for (final layer in layers) {
      expect(group.contains('$layer('), isTrue, reason: '浮层组缺少 $layer');
    }
  });
}
