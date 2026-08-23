import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/widgets/sliding_segmented_control.dart';

const _segments = [
  SlidingSegment(label: '红心', icon: Icons.favorite),
  SlidingSegment(label: '探索', icon: Icons.explore),
  SlidingSegment(label: '小众', icon: Icons.diamond),
];

Widget _host({
  required int selectedIndex,
  required ValueChanged<int> onSelected,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: SlidingSegmentedControl(
            segments: _segments,
            selectedIndex: selectedIndex,
            onSelected: onSelected,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('SlidingSegmentedControl', () {
    testWidgets('三段的文字与图标都在，布局不溢出', (tester) async {
      await tester.pumpWidget(_host(selectedIndex: 0, onSelected: (_) {}));

      for (final segment in _segments) {
        expect(find.text(segment.label), findsOneWidget);
        expect(find.byIcon(segment.icon!), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('点未选中段回调它的索引', (tester) async {
      final selected = <int>[];
      await tester.pumpWidget(
        _host(selectedIndex: 0, onSelected: selected.add),
      );

      await tester.tap(find.text('小众'));
      await tester.pumpAndSettle();

      expect(selected, [2]);
    });

    testWidgets('点当前段不回调', (tester) async {
      final selected = <int>[];
      await tester.pumpWidget(
        _host(selectedIndex: 1, onSelected: selected.add),
      );

      await tester.tap(find.text('探索'));
      await tester.pumpAndSettle();

      expect(selected, isEmpty);
    });

    testWidgets('指示器停在选中段的中心', (tester) async {
      // 三段等分时中心落在 Alignment.x = -1 / 0 / 1
      await tester.pumpWidget(_host(selectedIndex: 0, onSelected: (_) {}));
      expect(_thumbAlignment(tester), const Alignment(-1, 0));

      await tester.pumpWidget(_host(selectedIndex: 2, onSelected: (_) {}));
      await tester.pumpAndSettle();
      expect(_thumbAlignment(tester), const Alignment(1, 0));
    });
    testWidgets('实色轨道上的标签不跟随全局文字阴影', (tester) async {
      final base = ThemeData();
      const shadows = [Shadow(blurRadius: 4, offset: Offset(0, 1))];
      await tester.pumpWidget(
        _host(
          selectedIndex: 0,
          onSelected: (_) {},
          theme: base.copyWith(
            textTheme: AppTheme.applyTextShadows(base.textTheme, shadows),
          ),
        ),
      );

      final label = tester.element(find.text('红心'));
      // 主题里确实有阴影，控件自己把它去掉了
      expect(Theme.of(label).textTheme.labelLarge?.shadows, isNotEmpty);
      expect(DefaultTextStyle.of(label).style.shadows, isEmpty);
    });
  });
}

Alignment _thumbAlignment(WidgetTester tester) =>
    tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).alignment
        as Alignment;
