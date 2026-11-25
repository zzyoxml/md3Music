/// 对唱纯标记行不占位的视图层回归：当前行索引、可见行表、点击跳转。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  final lines = <LyricLine>[
    const LyricLine(startTime: 0, duration: 1000, text: '男：第一句'),
    const LyricLine(startTime: 1000, duration: 500, text: '女：'),
    const LyricLine(startTime: 2000, duration: 1000, text: '女：第二句'),
    const LyricLine(startTime: 3000, duration: 500, text: '合唱：'),
    const LyricLine(startTime: 4000, duration: 1000, text: '一起唱'),
  ];

  dynamic state(WidgetTester tester) =>
      tester.state(find.byType(AppleLyricsView)) as dynamic;

  Future<dynamic> pumpAt(WidgetTester tester, int timeMs) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppleLyricsView(
            lines: lines,
            currentTimeMs: timeMs,
            isPlaying: true,
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    return state(tester);
  }

  testWidgets('纯标记行不进入可见行表，当前行也不停在标记行上', (tester) async {
    await LyricPreferences.instance.setUseDuetLayout(true);

    final s = await pumpAt(tester, 1500); // 落在「女：」标记行区间
    expect(
      (s.cleanedLinesForTest as List<LyricLine>).map((l) => l.text).toList(),
      ['第一句', '第二句', '一起唱'],
    );
    expect((s.duetAlignmentsForTest as List<DuetAlignment>).length, 3);
    expect(s.currentLineIndexForTest as int, 0,
        reason: '保持上一句可见行，不得空一行');

    await tester.pumpWidget(const SizedBox.shrink());
    final s2 = await pumpAt(tester, 3500); // 落在「合唱：」标记行区间
    expect(s2.currentLineIndexForTest as int, 1,
        reason: '仍不得停在标记行上');
  });

  testWidgets('点击可见第二行跳到真实 startTime，不跳到被移除的标记行', (tester) async {
    await LyricPreferences.instance.setUseDuetLayout(true);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int? seekTime;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: AppleLyricsView(
              lines: lines,
              currentTimeMs: 0,
              isPlaying: true,
              onSeek: (t) => seekTime = t,
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 可见第 1 行中心 y：lineHeight 76.8、posY 171.6 → 76.8+171.6+38.4≈287。
    await tester.tapAt(const Offset(400, 287));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(seekTime, 2000,
        reason: '可见第二行是原 lines[2]，不是原 lines[1] 的纯标记行');
  });
}
