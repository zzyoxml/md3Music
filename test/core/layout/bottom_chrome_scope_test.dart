import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/bottom_chrome_scope.dart';

void main() {
  group('BottomChromeScope', () {
    testWidgets('无 scope 祖先时按「最底部」处理（false）', (tester) async {
      late bool read;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              read = BottomChromeScope.hasBottomChromeOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(read, isFalse);
    });

    testWidgets('scope 声明 true 时读到 true', (tester) async {
      late bool read;
      await tester.pumpWidget(
        MaterialApp(
          home: BottomChromeScope(
            hasBottomChrome: true,
            child: Builder(
              builder: (context) {
                read = BottomChromeScope.hasBottomChromeOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(read, isTrue);
    });

    testWidgets('嵌套时取最近一层', (tester) async {
      late bool read;
      await tester.pumpWidget(
        MaterialApp(
          home: BottomChromeScope(
            hasBottomChrome: true,
            child: BottomChromeScope(
              hasBottomChrome: false,
              child: Builder(
                builder: (context) {
                  read = BottomChromeScope.hasBottomChromeOf(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      expect(read, isFalse);
    });

    test('updateShouldNotify 仅在取值变化时通知', () {
      const scope = BottomChromeScope(
        hasBottomChrome: true,
        child: SizedBox(),
      );
      expect(
        scope.updateShouldNotify(
          const BottomChromeScope(hasBottomChrome: true, child: SizedBox()),
        ),
        isFalse,
      );
      expect(
        scope.updateShouldNotify(
          const BottomChromeScope(hasBottomChrome: false, child: SizedBox()),
        ),
        isTrue,
      );
    });

    testWidgets('chromeCollapseOf：坞位在场时读到收起进度', (WidgetTester tester) async {
      late double read;
      await tester.pumpWidget(
        MaterialApp(
          home: BottomChromeScope(
            hasBottomChrome: true,
            bottomChromeCollapse: 0.25,
            child: Builder(
              builder: (context) {
                read = BottomChromeScope.chromeCollapseOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(read, closeTo(0.25, 0.001));
    });

    testWidgets('chromeCollapseOf：坞位不存在 / 无祖先时按 1（自身即屏幕最底部）', (WidgetTester tester) async {
      late double noScope;
      late double noChrome;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              noScope = BottomChromeScope.chromeCollapseOf(context);
              return BottomChromeScope(
                hasBottomChrome: false,
                bottomChromeCollapse: 0.25,
                child: Builder(
                  builder: (context) {
                    noChrome = BottomChromeScope.chromeCollapseOf(context);
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      );
      expect(noScope, 1.0);
      expect(noChrome, 1.0, reason: '坞位不存在时进度无意义，必须回到"最底部"口径');
    });

    test('updateShouldNotify 在收起进度变化时也通知', () {
      const scope = BottomChromeScope(
        hasBottomChrome: true,
        bottomChromeCollapse: 0.5,
        child: SizedBox(),
      );
      expect(
        scope.updateShouldNotify(
          const BottomChromeScope(
            hasBottomChrome: true,
            bottomChromeCollapse: 0.5,
            child: SizedBox(),
          ),
        ),
        isFalse,
      );
      expect(
        scope.updateShouldNotify(
          const BottomChromeScope(
            hasBottomChrome: true,
            bottomChromeCollapse: 0.75,
            child: SizedBox(),
          ),
        ),
        isTrue,
      );
    });
  });
}
