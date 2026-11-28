/// 「歌词位置」在 AM 播放页的逐行对齐生效，以及与「男女对唱优化」的互斥。
///
/// 观测点是 AppleLyricsView 的逐行对齐真值源 _duetAlignments：文字层、
/// 模糊层、缩放锚点都读它，因此此处断言等价于断言三处渲染一致。
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

  // 带中文性别前缀：对唱关闭时只是普通歌词行；开启时由 DuetLayout 分左右中。
  final lines = <LyricLine>[
    LyricLine(startTime: 0, duration: 1000, text: '男：第一句'),
    LyricLine(startTime: 1000, duration: 1000, text: '女：第二句'),
    LyricLine(startTime: 2000, duration: 1000, text: '合：第三句'),
  ];

  dynamic state(WidgetTester tester) =>
      tester.state(find.byType(AppleLyricsView)) as dynamic;

  List<DuetAlignment> aligns(WidgetTester tester) =>
      (state(tester).duetAlignmentsForTest as List<DuetAlignment>).toList();

  Future<void> pumpView(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppleLyricsView(lines: lines, currentTimeMs: 0),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('默认置左：所有行沿用历史 defaultAlign', (tester) async {
    await pumpView(tester);
    expect(aligns(tester), List.filled(3, DuetAlignment.defaultAlign));
    await unmount(tester);
  });

  testWidgets('居中 / 置右：所有行统一按所选位置对齐', (tester) async {
    await pumpView(tester);
    for (final entry in <(LyricPosition, DuetAlignment)>[
      (LyricPosition.center, DuetAlignment.center),
      (LyricPosition.right, DuetAlignment.right),
      (LyricPosition.left, DuetAlignment.defaultAlign),
    ]) {
      await LyricPreferences.instance.setLyricPosition(entry.$1);
      await tester.pump();
      expect(
        aligns(tester),
        List.filled(3, entry.$2),
        reason: '位置 ${entry.$1.name} 应落在 ${entry.$2.name}',
      );
    }
    await unmount(tester);
  });

  testWidgets('对唱开启时逐行对齐接管，位置值保留且关闭后恢复', (tester) async {
    final prefs = LyricPreferences.instance;
    await prefs.setLyricPosition(LyricPosition.right);
    await pumpView(tester);
    expect(aligns(tester), List.filled(3, DuetAlignment.right));

    await prefs.setUseDuetLayout(true);
    await tester.pump();
    const duetAligns = <DuetAlignment>[
      DuetAlignment.left,
      DuetAlignment.right,
      DuetAlignment.center,
    ];
    expect(
      aligns(tester),
      duetAligns,
      reason: '对唱开启时全局位置必须让位于逐行性别对齐',
    );
    expect(
      prefs.lyricPosition,
      LyricPosition.right,
      reason: '互斥不改写用户已选的位置值',
    );

    // 对唱开启期间即便偏好被改写，渲染也不应跟随（effectiveLyricPosition 恒置左）。
    await prefs.setLyricPosition(LyricPosition.center);
    await tester.pump();
    expect(aligns(tester), duetAligns);

    await prefs.setUseDuetLayout(false);
    await tester.pump();
    expect(
      aligns(tester),
      List.filled(3, DuetAlignment.center),
      reason: '关闭对唱后恢复用户最后一次选择的位置',
    );
    await unmount(tester);
  });
}
