import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/md3_lyric_preferences.dart';
import 'package:md3music/modules/player/lyrics_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MD3 与 AM 歌词颜色分别持久化和重置，互不覆盖', () async {
    SharedPreferences.setMockInitialValues({});
    final md3 = Md3LyricPreferences.instance;
    final am = LyricPreferences.instance;
    await md3.reset();
    await am.reset();
    expect(md3.customTextColor, isNull);
    expect(am.customTextColor, isNull);

    const md3Color = Color(0xFF123456);
    const amColor = Color(0xFFABCDEF);
    await md3.setCustomTextColor(md3Color);
    await am.setCustomTextColor(amColor);
    final stored = await SharedPreferences.getInstance();
    expect(stored.getInt('md3_lyric_custom_text_color'), md3Color.toARGB32());
    expect(stored.getInt('lyric_custom_text_color'), amColor.toARGB32());
    expect(md3.customTextColor, md3Color);
    expect(am.customTextColor, amColor);

    await md3.setCustomTextColor(null);
    expect(md3.customTextColor, isNull);
    expect(am.customTextColor, amColor);
    await am.reset();
    expect(am.customTextColor, isNull);
    expect(stored.containsKey('lyric_custom_text_color'), isFalse);
  });

  testWidgets('MD3 歌词使用专属颜色，不使用界面文字颜色', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Md3LyricPreferences.instance;
    await prefs.reset();
    const lyricColor = Color(0xFF123456);
    await prefs.setCustomTextColor(lyricColor);
    addTearDown(prefs.reset);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.from(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF876543))
            .copyWith(onSurface: const Color(0xFFABCDEF)),
      ),
      home: Scaffold(
        body: SizedBox(
          height: 280,
          child: LyricsView(
            lyrics: '[00:00.00]第一行\n[00:05.00]第二行',
            position: Duration.zero,
            onSeek: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    final style = tester.widget<AnimatedDefaultTextStyle>(
      find.ancestor(
        of: find.text('第一行'),
        matching: find.byType(AnimatedDefaultTextStyle),
      ).first,
    );
    expect(style.style.color, lyricColor.withValues(alpha: 0.7));
  });
}
