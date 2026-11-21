import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_aux_scope.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/md3_lyric_preferences.dart';

/// MD3 经典播放页的「副行显示范围」回归测试。
///
/// 钉住三条契约：
/// 1. 三种范围各自决定「哪些行显示副行」；
/// 2. **行高与副行显隐同源** —— 不显示副行的行不留空白，显示的行必须留够高度
///    （否则副行会压到下一行，或点击跳行命中错行）；
/// 3. 副行开关关闭时三种范围都不显示副行。
void main() {
  const lines = <LyricLine>[
    LyricLine(startTime: 0, duration: 2000, text: '第一句', translation: '译一'),
    LyricLine(startTime: 2000, duration: 2000, text: '第二句', translation: '译二'),
    LyricLine(startTime: 4000, duration: 2000, text: '第三句', translation: '译三'),
  ];

  String lrcOf(List<LyricLine> src) => src
      .map((l) {
        final seconds = (l.startTime ~/ 1000).toString().padLeft(2, '0');
        return '[00:$seconds.00]${l.text}';
      })
      .join('\n');

  Future<void> resetPrefs() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Md3LyricPreferences.instance.reset();
    await LyricPreferences.instance.reset();
  }

  Future<void> pumpAt(WidgetTester tester, int positionMs) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 520,
            child: LyricsView(
              lyrics: lrcOf(lines),
              parsedLyrics: lines,
              position: Duration(milliseconds: positionMs),
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 某一行行容器的高度（Container 直接承载 `height: _lineHeights[index]`）。
  double rowHeight(WidgetTester tester, String mainText) {
    final container = find
        .ancestor(of: find.text(mainText), matching: find.byType(Container))
        .first;
    return tester.getSize(container).height;
  }

  testWidgets('currentLine：只有当前行显示副行', (tester) async {
    await resetPrefs();
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    await pumpAt(tester, 0); // 当前行 = 第 0 行

    expect(find.text('译一'), findsOneWidget);
    expect(find.text('译二'), findsNothing);
    expect(find.text('译三'), findsNothing);

    // 切到第 1 行后，副行跟着移到第 1 行
    await pumpAt(tester, 2000);
    expect(find.text('译一'), findsNothing);
    expect(find.text('译二'), findsOneWidget);
    expect(find.text('译三'), findsNothing);
  });

  testWidgets('allLines：每行都显示副行', (tester) async {
    await resetPrefs();
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.allLines);
    await pumpAt(tester, 0);

    expect(find.text('译一'), findsOneWidget);
    expect(find.text('译二'), findsOneWidget);
    expect(find.text('译三'), findsOneWidget);
  });

  testWidgets('hidePlayed：已播行不显示，当前行与未播行显示', (tester) async {
    await resetPrefs();
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.hidePlayed);
    await pumpAt(tester, 2000); // 当前行 = 第 1 行

    expect(find.text('译一'), findsNothing, reason: '已播行不显示副行');
    expect(find.text('译二'), findsOneWidget);
    expect(find.text('译三'), findsOneWidget);
  });

  testWidgets('副行开关关闭时三种范围都不显示副行', (tester) async {
    await resetPrefs();
    await Md3LyricPreferences.instance.setShowAuxiliary(false);
    for (final scope in LyricAuxScope.values) {
      await LyricPreferences.instance.setAuxScope(scope);
      await pumpAt(tester, 0);
      expect(find.text('译一'), findsNothing, reason: 'scope=$scope');
      expect(find.text('译二'), findsNothing, reason: 'scope=$scope');
      expect(find.text('译三'), findsNothing, reason: 'scope=$scope');
    }
  });

  testWidgets('行高与副行显隐同源：不显示副行的行不留空白', (tester) async {
    await resetPrefs();
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.allLines);
    await pumpAt(tester, 0);
    final double withAux = rowHeight(tester, '第三句');

    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    await pumpAt(tester, 0);
    final double withoutAux = rowHeight(tester, '第三句');

    expect(
      withAux,
      greaterThan(withoutAux),
      reason: '显示副行的行必须比不显示的高出副行块',
    );
    // 差值应等于副行块高度（含 0.25em 间隙），量级上远小于一整行主歌词
    expect(withAux - withoutAux, greaterThan(4));
    expect(withAux - withoutAux, lessThan(withAux));
  });

  testWidgets('切换范围即时生效（无需重建 widget）', (tester) async {
    await resetPrefs();
    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    await pumpAt(tester, 0);
    expect(find.text('译二'), findsNothing);

    await LyricPreferences.instance.setAuxScope(LyricAuxScope.allLines);
    await tester.pump();
    expect(find.text('译二'), findsOneWidget);

    await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
    await tester.pump();
    expect(find.text('译二'), findsNothing);
  });
}
