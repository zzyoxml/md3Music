import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/md3_lyric_preferences.dart';

Future<void> _resetMd3Preferences() async {
  SharedPreferences.setMockInitialValues({});
  await Md3LyricPreferences.instance.reset();
}

Widget _buildLyricsView(List<LyricLine> lines) {
  final mainText = lines
      .map((line) {
        final seconds = (line.startTime ~/ 1000).toString().padLeft(2, '0');
        return '[00:$seconds.00]${line.text}';
      })
      .join('\n');
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 320,
        height: 520,
        child: LyricsView(
          lyrics: mainText,
          parsedLyrics: lines,
          position: Duration.zero,
          onSeek: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('MD3 翻译模式显示所有匹配译文', (tester) async {
    await _resetMd3Preferences();
    final prefs = Md3LyricPreferences.instance;
    await prefs.setShowAuxiliary(true);
    await prefs.setDisplayMode(Md3LyricDisplayMode.translation);
    const lines = [
      LyricLine(
        startTime: 0,
        duration: 4000,
        text: 'Hello',
        translation: '你好',
        roma: 'Ni hao',
      ),
      LyricLine(
        startTime: 5000,
        duration: 4000,
        text: 'World',
        translation: '世界',
        roma: 'Shi jie',
      ),
    ];

    await tester.pumpWidget(_buildLyricsView(lines));
    await tester.pump();

    expect(find.text('你好'), findsOneWidget);
    expect(find.text('世界'), findsOneWidget);
    expect(find.text('Ni hao'), findsNothing);
  });

  testWidgets('MD3 罗马音模式只显示罗马音，关闭副歌词后隐藏副行', (tester) async {
    await _resetMd3Preferences();
    final prefs = Md3LyricPreferences.instance;
    await prefs.setDisplayMode(Md3LyricDisplayMode.roma);

    const lines = [
      LyricLine(
        startTime: 0,
        duration: 4000,
        text: '你好',
        translation: 'Hello',
        roma: 'Ni hao',
      ),
    ];
    await tester.pumpWidget(_buildLyricsView(lines));
    await tester.pump();

    expect(find.text('Ni hao'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);

    await prefs.setShowAuxiliary(false);
    await tester.pump();
    expect(find.text('Ni hao'), findsNothing);
    expect(find.text('你好'), findsOneWidget);
  });

  testWidgets('首选模式无数据时自动显示另一种可用副歌词', (tester) async {
    await _resetMd3Preferences();
    final prefs = Md3LyricPreferences.instance;
    await prefs.setDisplayMode(Md3LyricDisplayMode.translation);

    const lines = [
      LyricLine(startTime: 0, duration: 4000, text: '你好', roma: 'Ni hao'),
    ];
    await tester.pumpWidget(_buildLyricsView(lines));
    await tester.pump();

    expect(find.text('Ni hao'), findsOneWidget);
  });

  testWidgets('长翻译完整换行且不设置截断', (tester) async {
    await _resetMd3Preferences();
    const longTranslation = '这是一段很长的翻译文本，用于验证 MD3 歌词副行会完整换行显示而不会被省略号截断。';
    const lines = [
      LyricLine(
        startTime: 0,
        duration: 4000,
        text: 'A short line',
        translation: longTranslation,
      ),
    ];

    await tester.pumpWidget(_buildLyricsView(lines));
    await tester.pump();

    final translation = tester.widget<Text>(find.text(longTranslation));
    expect(translation.maxLines, isNull);
    expect(translation.overflow, isNull);
    final container = find
        .ancestor(
          of: find.text(longTranslation),
          matching: find.byType(Container),
        )
        .first;
    expect(tester.getSize(container).height, greaterThan(80));
  });

  test('MD3 副歌词偏好独立持久化并可重置', () async {
    await _resetMd3Preferences();
    final prefs = Md3LyricPreferences.instance;
    await prefs.setShowAuxiliary(false);
    await prefs.setDisplayMode(Md3LyricDisplayMode.roma);

    final stored = await SharedPreferences.getInstance();
    expect(stored.getBool('md3_lyric_show_auxiliary'), isFalse);
    expect(stored.getString('md3_lyric_display_mode'), 'roma');
    expect(prefs.showAuxiliary, isFalse);
    expect(prefs.displayMode, Md3LyricDisplayMode.roma);

    await prefs.reset();
    expect(prefs.showAuxiliary, isTrue);
    expect(prefs.displayMode, Md3LyricDisplayMode.translation);
    expect(stored.getBool('md3_lyric_show_auxiliary'), isNull);
    expect(stored.getString('md3_lyric_display_mode'), isNull);
  });
}
