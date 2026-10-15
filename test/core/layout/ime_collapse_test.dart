import 'package:flutter/material.dart';
// 搜索页真正用的输入框是 material_ui 的 TextField（与 flutter 版同构、不同名解析），
// 焦点判据必须对它也成立，故单独带别名引一份。
import 'package:material_ui/material_ui.dart' as mu;
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/ime_collapse.dart';

/// 键盘（输入法）弹出期间把底部播放条整条沉底收没、不占空间；键盘收起后恢复。
///
/// 约定：
/// - 收起是**高度归零**（子树离开树），不是透明度淡出，否则列表底部白留一条空带；
/// - 收展几何与底部导航栏的收起同源（底边贴住、顶缘被裁），时长同
///   `kBottomChromeToggleDuration`；
/// - 挂载时键盘已经弹着（如二级页带键盘进场）不播动画，直接定到收没端点。
void main() {
  const Key barKey = Key('bar');
  const double barHeight = 50;

  Widget buildApp({double ime = 0, bool disableAnimations = false}) {
    return MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            viewInsets: EdgeInsets.only(bottom: ime),
          ),
          child: Scaffold(
            // 关掉 Scaffold 自己的键盘避让：本文件只观察 ImeCollapse 的高度变化，
            // 不与视口被抬高的效果叠加，读数才唯一。
            resizeToAvoidBottomInset: false,
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                ImeCollapse(
                  child: Container(
                    key: barKey,
                    height: barHeight,
                    color: Colors.blueGrey,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double height(WidgetTester tester) =>
      tester.getSize(find.byType(ImeCollapse)).height;

  /// 只把焦点给输入框、**不改 viewInsets** 的页面 —— 与本机真机形态一致
  /// （小米 / Android 17 / 讯飞 IME：键盘完全弹起时 `MediaQuery.viewInsets.bottom`
  /// 仍是 0），用来钉"焦点态才是主判据"这条结论。
  Widget buildFocusApp() {
    return MaterialApp(
      home: Scaffold(
        // 关掉 Scaffold 自己的键盘避让，只观察 ImeCollapse 的高度变化。
        resizeToAvoidBottomInset: false,
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: TextField(decoration: InputDecoration(labelText: '输入')),
            ),
            const Spacer(),
            const ImeCollapse(
              child: SizedBox(key: barKey, height: barHeight),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('输入框拿到焦点→整条收没；失焦→原样恢复', (tester) async {
    await tester.pumpWidget(buildFocusApp());
    await tester.pumpAndSettle();
    // 焦点还在 scope 上：不能因为"页面里有输入框"就误判为键盘弹出
    expect(height(tester), barHeight);

    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(height(tester), 0);
    expect(find.byKey(barKey), findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(height(tester), barHeight);
    expect(find.byKey(barKey), findsOneWidget);
  });

  testWidgets('输入框拿到焦点时，insets 为 0 也算键盘弹出（本机形态）', (tester) async {
    await tester.pumpWidget(buildFocusApp());
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    // 本用例全程没有改过 viewInsets：收起只能由焦点态触发
    expect(height(tester), 0);
    expect(kTextInputFocused.value, isTrue);
  });

  testWidgets('material_ui 的输入框（搜索页实际用的那个）同样能被认出', (tester) async {
    // 必须用 material_ui 自己的 MaterialApp/Material：mu.TextField 解析到的是
    // material_ui 同名的 MaterialLocalizations/Material，flutter 版 MaterialApp
    // 提供的那份对不上（表现为「No MaterialLocalizations found」）。
    await tester.pumpWidget(
      mu.MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: mu.Material(
            type: mu.MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
                    height: 64,
                    child: mu.TextField(),
                  ),
                ),
                const ImeCollapse(
                  child: SizedBox(key: barKey, height: barHeight),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(height(tester), barHeight);

    await tester.showKeyboard(find.byType(mu.TextField));
    await tester.pumpAndSettle();
    expect(
      height(tester),
      0,
      reason: '焦点节点挂在 Focus 上、EditableText 在其祖先链第 11 层，祖先探查必须命中',
    );
  });

  testWidgets('键盘弹出→整条收没（不占空间）；键盘收起→原样恢复', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(height(tester), barHeight);
    expect(find.byKey(barKey), findsOneWidget);

    await tester.pumpWidget(buildApp(ime: 300));
    await tester.pumpAndSettle();
    expect(height(tester), 0);
    expect(
      find.byKey(barKey),
      findsNothing,
      reason: '收没后子树应离开树，而不是留在树里透明占位',
    );

    await tester.pumpWidget(buildApp(ime: 0));
    await tester.pumpAndSettle();
    expect(height(tester), barHeight);
    expect(find.byKey(barKey), findsOneWidget);
  });

  testWidgets('收起过程是沉底收缩：底边不动、顶缘上移', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    final bottomBefore = tester.getRect(find.byKey(barKey)).bottom;

    await tester.pumpWidget(buildApp(ime: 300));
    // 动画中途一帧：高度已减小但尚未归零，子树仍在树里被裁切
    await tester.pump(const Duration(milliseconds: 120));
    final mid = height(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(barHeight));
    expect(tester.getRect(find.byKey(barKey)).bottom, bottomBefore);
  });

  testWidgets('键盘在收起动画走完之前就关闭：仍会回弹到原位', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(height(tester), barHeight);

    await tester.pumpWidget(buildApp(ime: 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(height(tester), lessThan(barHeight));

    // 键盘中途收起：本组件外层 build 之后不会再被动画回调触发（AnimatedBuilder
    // 只重建它自己那层），目标态必须在这一帧就判对并 reverse 回去。
    await tester.pumpWidget(buildApp(ime: 0));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(height(tester), barHeight);
    expect(find.byKey(barKey), findsOneWidget);
  });

  testWidgets('挂载时键盘已弹着：首帧直接收没，不播收起动画', (tester) async {
    await tester.pumpWidget(buildApp(ime: 300));
    expect(height(tester), 0);
    expect(find.byKey(barKey), findsNothing);
  });

  testWidgets('系统「减弱动态效果」：收展瞬时到位', (tester) async {
    await tester.pumpWidget(buildApp(disableAnimations: true));
    await tester.pumpWidget(buildApp(ime: 300, disableAnimations: true));
    // 单帧即到端点（非减弱档这里会停在中间值）
    await tester.pump();
    expect(height(tester), 0);

    await tester.pumpWidget(buildApp(disableAnimations: true));
    await tester.pump();
    expect(height(tester), barHeight);
  });
}
