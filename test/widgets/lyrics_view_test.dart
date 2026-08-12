import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/modules/player/lyrics_view.dart';

/// MD3 歌词视图行高自适应 + 完整显示测试。
///
/// Bug1: 英文长歌词换行成两行时容器仍是单行高 → 只显示半截。
/// Bug2: 英文原词+翻译超长行被 maxLines:2 + ellipsis 截成 "..." 显示不完整。
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
}
