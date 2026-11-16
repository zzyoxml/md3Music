import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 桌面外壳顶部工具栏已被移除的回归断言。
///
/// **背景**：桌面布局顶部原本有一条独立色带（56px，`surface` + 下边框），
/// 内含浏览器式「后退 / 前进」箭头与一个全局搜索框。用户反馈：
///   1. 两个箭头多余；
///   2. 剩余的「搜索音乐、歌手、歌单」框与各 Tab 自身的搜索入口重复；
///   3. 这条色带本身又与内容区背景割裂。
/// 三者同源——整块工具栏都是冗余，故整条移除。
///
/// 这里用**源码断言**而非 widget 测试：`DesktopShell` 依赖一长串 Provider
/// （TabConfig / Theme / Device / Player …），构造成本高且脆弱；
/// 而本条的实质是「工具栏不得再被引用」，源码断言更直接、也更难被
/// 无意中改坏。
void main() {
  const shellPath = 'lib/core/layout/desktop_shell.dart';

  test('内容区不再挂载 _DesktopToolbar', () {
    final source = File(shellPath).readAsStringSync();
    // 类定义 `const _DesktopToolbar({` 有意保留（便于日后恢复），
    // 故这里只禁止**调用**：即 `_DesktopToolbar(` 出现在缩进代码里
    // 且不是以 const 开头的那一处。先剔除行注释。
    final code = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .map((line) => line.replaceAll('const _DesktopToolbar({', ''))
        .join('\n');

    expect(
      code.contains('_DesktopToolbar('),
      isFalse,
      reason: '桌面顶部工具栏已整块移除，'
          '_buildContentRegion 不应再挂载 _DesktopToolbar',
    );
  });

  test('内容区直接返回 Expanded（不再有 Column 包裹工具栏）', () {
    final source = File(shellPath).readAsStringSync();
    // 工具栏移除后 _buildContentRegion 应直接给出内容区，不再是
    // Column(children: [Toolbar, Expanded(...)]) 的两层结构。
    final start = source.indexOf('Widget _buildContentRegion(');
    expect(start, greaterThan(-1), reason: '未找到 _buildContentRegion');
    final body = source.substring(start, start + 1400);
    final code = body
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(
      code.contains('return Expanded('),
      isTrue,
      reason: '内容区应直接返回 Expanded 节点',
    );
  });

  test('工具栏前进 / 前进箭头未在任何生效代码中', () {
    final source = File(shellPath).readAsStringSync();
    final code = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('Icons.arrow_back'), isFalse);
    expect(code.contains('Icons.arrow_forward'), isFalse);
  });
}