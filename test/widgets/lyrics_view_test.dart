import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/modules/player/lyrics_view.dart';
import '../../lib/widgets/md3_lyric_preferences.dart';

/// MD3 歌词视图行高自适应 + 完整显示测试。
///
/// Bug1: 英文长歌词换行成两行时容器仍是单行高 → 只显示半截。
/// Bug2: 英文原词+翻译超长行被 maxLines:2 + ellipsis 截成 "..." 显示不完整。
/// Bug3: lineSpacing 最低可调到 0.8，行距留白 fontSize*(lineSpacing-1.2) 为负，
///       容器矮于文本块 → 英文长行字形被裁切。修复后行高下限取 1.4。
/// 修复：TextPainter 完整测量换行行数，行高自适应；去掉截断完整显示。
void main() {
  // 英文 + 中文翻译拼接的超长行（KRC 剥离标签后原词+翻译连成一行）
  const longText =
      'This is a deliberately very long English lyric line that keeps '
      'going with many words and characters 这是一段非常长的中文翻译歌词'
      '也被拼接在同一行里继续显示直到完全展示完整内容';

  testWidgets('超长歌词行完整换行显示（无截断），行高高于短行', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: LyricsView(
              lyrics: '[00:00.00]短行\n[00:05.00]$longText\n[00:10.00]最后一行',
              position: Duration.zero,
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 1) 超长行对应的 Text 不应设置 maxLines/ellipsis 截断
    final longTextWidget = tester.widget<Text>(find.text(longText));
    expect(longTextWidget.maxLines, isNull, reason: '超长行不应被 maxLines 截断');
    expect(longTextWidget.overflow, isNull, reason: '超长行不应省略号截断');

    // 2) 超长行（换行 2 行以上）行高应高于短行，完整容纳
    final shortContainer = find
        .ancestor(of: find.text('短行'), matching: find.byType(Container))
        .first;
    final longContainer = find
        .ancestor(of: find.text(longText), matching: find.byType(Container))
        .first;

    final shortHeight = tester.getSize(shortContainer).height;
    final longHeight = tester.getSize(longContainer).height;

    expect(
      longHeight,
      greaterThan(shortHeight),
      reason: '超长行换行后行高应自适应增高（短行=$shortHeight, 长行=$longHeight）',
    );
  });

  testWidgets('行距 0.8 时长行行高不得矮于两行文本（负留白 bug 回归）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Md3LyricPreferences.instance;
    await prefs.setLineSpacing(0.8); // 最低行距，触发原实现负留白

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: LyricsView(
              lyrics: '[00:00.00]$longText\n[00:10.00]短行',
              position: Duration.zero,
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 长行换行 2+ 行，容器高度不得低于 2 行文本高（fontSize * 1.4 * 2）。
    // 原实现 spacingExtra = fontSize*(lineSpacing-1.2) 在 0.8 时为负，
    // 容器矮于文本块导致英文 descenders 被裁切。
    final longContainer = find
        .ancestor(of: find.text(longText), matching: find.byType(Container))
        .first;
    final longHeight = tester.getSize(longContainer).height;
    final minTwoLines = prefs.fontSize * 1.4 * 2;
    expect(
      longHeight,
      greaterThanOrEqualTo(minTwoLines),
      reason: '行距 0.8 时长行行高 $longHeight 不应低于两行文本高 $minTwoLines'
          '（负留白会把容器缩矮裁切英文）',
    );
  });
}
