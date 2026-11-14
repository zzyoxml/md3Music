import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 找出源码里所有 TextField( 构造点（跳过注释行）。
/// 正则前置否定避免误伤 SelectableText( / EditableText( / TextFormField(。
final RegExp _textFieldSite = RegExp(r'(?<![A-Za-z_])TextField\(');

/// 从 '(' 起按括号配平找到构造调用的结束位置，返回该次调用的源码切片。
/// Flutter 的调用点普遍是多行书写，只看当前行会漏掉下一行的参数。
String? _callSlice(String source, int openParen) {
  int depth = 0;
  for (int i = openParen; i < source.length; i++) {
    final String ch = source[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) {
        return source.substring(openParen, i + 1);
      }
    }
  }
  return null; // 配平失败，交给断言报告
}

void main() {
  test('lib/ 下每个 TextField 调用点都必须接 buildAppTextContextMenu', () {
    final List<String> missing = <String>[];
    int total = 0;
    // 计划原稿写 `for (final File file in ...listSync())`，但 listSync 返回
    // List<FileSystemEntity>，Dart 类型检查直接编译失败；此处改为显式过滤 File。
    for (final FileSystemEntity entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      final File file = entity;
      if (file.path.endsWith('.g.dart')) continue;
      if (!file.path.endsWith('.dart')) continue;
      final List<String> lines = file.readAsLinesSync();
      for (int n = 0; n < lines.length; n++) {
        final String line = lines[n].trim();
        if (line.startsWith('//') || line.startsWith('///')) continue;
        final Match? m = _textFieldSite.firstMatch(lines[n]);
        if (m == null) continue;
        total++;
        final int openParen = lines[n].indexOf('(', m.start);
        final String? slice = _callSlice(
          lines.skip(n).join('\n'),
          openParen,
        );
        if (slice == null || !slice.contains('contextMenuBuilder')) {
          missing.add('${file.path}:$n');
        }
      }
    }
    expect(total, greaterThan(0), reason: '扫描不到 TextField(，先怀疑扫描逻辑');
    expect(missing, isEmpty, reason: '以下输入框未接 buildAppTextContextMenu：\n${missing.join("\n")}');
  });
}
