import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';

void main() {
  group('DetailEmptyState', () {
    testWidgets('默认参数渲染桌面外壳原文案与图标（行为不变）', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: DetailEmptyState()));
      await tester.pumpAndSettle();

      expect(find.text('从左侧选择一项查看详情'), findsOneWidget);
      expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
    });

    testWidgets('自定义图标与文案（设置页空态复用）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DetailEmptyState(
            icon: Icons.tune,
            text: '从左侧选择分类进行配置',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('从左侧选择分类进行配置'), findsOneWidget);
      expect(find.byIcon(Icons.tune), findsOneWidget);
    });
  });
}
