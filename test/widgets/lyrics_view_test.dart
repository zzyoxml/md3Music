import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/modules/player/lyrics_view.dart';
import '../../lib/widgets/md3_lyric_preferences.dart';
import 'package:md3music/core/utils/lyric_wrap_plan.dart';

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
    final longTextWidget = tester.widget<Text>(findLyricText(longText));
    expect(longTextWidget.maxLines, isNull, reason: '超长行不应被 maxLines 截断');
    expect(longTextWidget.overflow, isNull, reason: '超长行不应省略号截断');

    // 2) 超长行（换行 2 行以上）行高应高于短行，完整容纳
    final shortContainer = find
        .ancestor(of: find.text('短行'), matching: find.byType(Container))
        .first;
    final longContainer = find
        .ancestor(of: findLyricText(longText), matching: find.byType(Container))
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
        .ancestor(of: findLyricText(longText), matching: find.byType(Container))
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

  testWidgets('增强型 LRC 只显示歌词正文，不显示尖括号时间标签', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: LyricsView(
              lyrics: '[00:00.00]<00:00.00>第一<00:00.50>句<00:01.00>\n'
                  '[00:02.00]<0,500,0>第二<500,500,0>句',
              position: Duration.zero,
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('第一句'), findsOneWidget);
    expect(find.text('第二句'), findsOneWidget);
    expect(find.textContaining('<00:'), findsNothing);
    expect(find.textContaining('<0,'), findsNothing);
  });

  testWidgets('开启平衡：长行按计划硬断点，且比贪心更均匀', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Md3LyricPreferences.instance;
    await prefs.setLineBalance(true);
    const longText = '这是一段足够长的中文歌词用于测试平衡换行'; // 20 字
    const viewWidth = 300.0;
    final availableWidth = viewWidth - 48; // 与 LyricsView 内部一致（水平 padding 24*2）
    final style = TextStyle(
      fontSize: prefs.fontSize,
      height: _expectedWrapLineHeight(prefs),
      fontWeight: prefs.fontWeight,
      fontFamily: prefs.effectiveFontFamily,
    );
    final plan = LyricWrapPlanner.forText(
      longText,
      style,
      availableWidth,
      balanced: true,
    );
    // 实测打印：确认 Ahem 下 20 字 / 可用宽 252 的 DP 分组
    // ignore: avoid_print
    print('[MDWrap] rowTexts=${plan.rowTexts} widths=${plan.rowWidths} '
        'count=${plan.rowCount} fontSize=${prefs.fontSize}');
    // Ahem 22/字、可用宽 252 → 每行最多 11 字：贪心切成 11+9，平衡拉平成 10+10
    expect(plan.rowTexts, <String>['这是一段足够长的中文', '歌词用于测试平衡换行']);

    await tester.pumpWidget(
      _harness(
        SizedBox(
          width: viewWidth,
          height: 400,
          child: LyricsView(
            lyrics: '[00:00.000]$longText',
            position: Duration.zero,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final rendered = tester.widget<Text>(find.textContaining('词用于测试'));
    expect(rendered.data, plan.rowTexts.join('\n'));
  });

  testWidgets('关闭平衡：展示文本不含硬断点（与改造前一致）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Md3LyricPreferences.instance;
    await prefs.setLineBalance(false);
    addTearDown(() => prefs.setLineBalance(true));
    const longText = '这是一段足够长的中文歌词用于测试平衡换行';
    await tester.pumpWidget(
      _harness(
        SizedBox(
          width: 300,
          height: 400,
          child: LyricsView(
            lyrics: '[00:00.000]$longText',
            position: Duration.zero,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final rendered = tester.widget<Text>(find.textContaining(longText));
    expect(rendered.data, isNotNull);
    expect(rendered.data!.contains('\n'), isFalse, reason: '关闭态不得插入硬断点');
  });
}

/// 匹配内容（去掉平衡换行插入的硬断点 \n 后）与 [expected] 逐字相等的 Text。
///
/// 开启平衡后长行会把 DP 断点落成 `\n`，`find.text(原文)` 的精确匹配随之失效；
/// 本 finder 保留「完整内容都在、没被省略号截断」的原意，只容忍插入的换行符。
Finder findLyricText(String expected) => find.byWidgetPredicate(
  (Widget w) => w is Text && (w.data?.replaceAll('\n', '') ?? '') == expected,
);

/// 与 LyricsView._wrapLineHeight 同式的期望值：行间距 × 0.8，下限 1.4。
double _expectedWrapLineHeight(Md3LyricPreferences prefs) {
  final scaled = prefs.lineSpacing * 0.8;
  return scaled > 1.4 ? scaled : 1.4;
}

Widget _harness(Widget child) => MaterialApp(
  home: Scaffold(body: child),
);
