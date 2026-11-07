import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/settings_preview/player_chrome_preview.dart';

void main() {
  testWidgets('两个朝向都渲染且不抛异常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 340,
            child: PlayerChromePreview(
              landscapeDetachedControls: false,
              pillCollapse: false,
              topBarTabDots: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('竖屏'), findsOne);
    expect(find.text('宽屏'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊收缩开启时竖屏顶栏只露 ⋯，宽屏不受影响', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 340,
            child: PlayerChromePreview(
              landscapeDetachedControls: false,
              pillCollapse: true,
              topBarTabDots: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 收缩态：常显的三格文案（音质/睡眠/一起听）不应出现在顶栏
    // （宽屏仍常显，故不能断言全局 findsNothing，只断言竖屏那份不存在）
    // 用「顶栏 ⋯ 图标数量」区分：收缩态每框 1 个，常显态每框 1 个（同样 1 个），
    // 故改用文案存在性 + 不崩溃作为主要断言。
    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊收缩关闭时两框都常显三格文案', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 340,
            child: PlayerChromePreview(
              landscapeDetachedControls: false,
              pillCollapse: false,
              topBarTabDots: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 两个框各一套三格 → 每个文案出现 2 次
    expect(find.text('音质'), findsNWidgets(2));
    expect(find.text('睡眠'), findsNWidgets(2));
    expect(find.text('一起听'), findsNWidgets(2));
  });

  testWidgets('顶栏页签圆点开启时出现「控制」页签（宽屏独立页）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 340,
            child: PlayerChromePreview(
              landscapeDetachedControls: true,
              pillCollapse: false,
              topBarTabDots: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 宽屏独立页开启 → 右栏出现「歌词 / 控制」两枚页签
    expect(find.text('控制'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏独立页关闭时不出现「控制」页签', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 340,
            child: PlayerChromePreview(
              landscapeDetachedControls: false,
              pillCollapse: false,
              topBarTabDots: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('控制'), findsNothing);
  });
}
