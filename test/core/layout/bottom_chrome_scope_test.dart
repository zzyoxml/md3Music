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
  });
}
