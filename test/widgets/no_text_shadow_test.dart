import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/core/widgets/no_text_shadow.dart';

const _shadows = [Shadow(blurRadius: 4, offset: Offset(0, 1))];

/// 全局带阴影的主题 + 带阴影的 [DefaultTextStyle]，模拟「背景图 + 文字阴影」态。
Widget _host({required ValueChanged<BuildContext> onInner}) {
  final base = ThemeData();
  return MaterialApp(
    theme: base.copyWith(
      textTheme: AppTheme.applyTextShadows(base.textTheme, _shadows),
      primaryTextTheme: AppTheme.applyTextShadows(base.primaryTextTheme, _shadows),
    ),
    home: Scaffold(
      body: DefaultTextStyle(
        style: const TextStyle(fontSize: 13, shadows: _shadows),
        child: NoTextShadow(
          child: Builder(
            builder: (context) {
              onInner(context);
              return const Text('实色卡片上的文字');
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('NoTextShadow', () {
    testWidgets('子树内主题文字层级与 DefaultTextStyle 都不带阴影', (tester) async {
      late BuildContext inner;
      await tester.pumpWidget(_host(onInner: (context) => inner = context));

      // 先确认外层确实带阴影，否则断言是空跑
      final outer = tester.element(find.byType(Scaffold));
      expect(Theme.of(outer).textTheme.titleSmall?.shadows, isNotEmpty);

      expect(Theme.of(inner).textTheme.titleSmall?.shadows, isEmpty);
      expect(Theme.of(inner).textTheme.bodySmall?.shadows, isEmpty);
      expect(Theme.of(inner).primaryTextTheme.bodyMedium?.shadows, isEmpty);
      expect(DefaultTextStyle.of(inner).style.shadows, isEmpty);
    });

    testWidgets('只去阴影，其余文字属性原样保留', (tester) async {
      late BuildContext inner;
      await tester.pumpWidget(_host(onInner: (context) => inner = context));

      expect(DefaultTextStyle.of(inner).style.fontSize, 13);
      final outer = tester.element(find.byType(Scaffold));
      expect(
        Theme.of(inner).textTheme.titleSmall?.copyWith(shadows: _shadows),
        Theme.of(outer).textTheme.titleSmall,
      );
    });
  });
}
