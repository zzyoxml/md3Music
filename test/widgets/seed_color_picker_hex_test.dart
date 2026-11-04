import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/widgets/seed_color_picker.dart';

/// 色轮对话框的十六进制色号输入：色号 → 颜色、颜色 → 色号、非法提示、确定回退。
///
/// 对话框是私有的 `_CustomColorPickerDialog`，只能从「自定义颜色」槽（`Icons.colorize`）
/// 点进去，故所有用例先装载 [SeedColorPicker] 再开对话框。
void main() {
  /// 装载面板并打开自定义取色对话框。
  /// 被测代码来自 `package:material_ui`（自带 Theme/MaterialApp 实现），
  /// 测试侧必须用同一套，否则 `Theme.of` 取不到主题。
  Future<void> openDialog(
    WidgetTester tester, {
    required Color current,
    required ValueChanged<Color> onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeedColorPicker(currentColor: current, onSelected: onSelected),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.colorize));
    await tester.pumpAndSettle();
  }

  /// 色轮由 `_HueWheelPainter` 绘制，是对话框里唯一使用该 painter 的 CustomPaint；
  /// 它的尺寸由外层 SizedBox 固定为 200×200，`tester.tap` 默认打正中 = 圆心 → 饱和度 0。
  /// 注意：不能按「带 onTapDown 的 GestureDetector」找色轮——Slider / TextField 内部也各带一个，
  /// 会命中 3 个导致 tap 歧义；CustomPaint + 专属 painter 才是唯一稳定锚点。
  Finder wheelFinder() => find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter?.runtimeType.toString() == '_HueWheelPainter',
      );

  testWidgets('初始输入框显示当前色的规范色号', (tester) async {
    await openDialog(tester,
        current: AppTheme.defaultSeedColor, onSelected: (_) {});

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '#0061A4',
    );
  });

  testWidgets('输入色号后直接点确定即生效（无需先按键盘完成）', (tester) async {
    Color? picked;
    await openDialog(tester,
        current: AppTheme.defaultSeedColor, onSelected: (c) => picked = c);

    await tester.enterText(find.byType(TextField), '1e88e5');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(picked, const Color(0xFF1E88E5));
  });

  testWidgets('按键盘完成提交色号：输入框与预览条同步为规范色号', (tester) async {
    await openDialog(tester,
        current: AppTheme.defaultSeedColor, onSelected: (_) {});

    await tester.enterText(find.byType(TextField), '#ff0000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // 两处：输入框文本 + 预览条文字，均为大写带 # 的规范形式
    expect(find.text('#FF0000'), findsExactly(2));
  });

  testWidgets('点色轮中心改饱和度为 0，输入框随颜色同步', (tester) async {
    await openDialog(tester,
        current: const Color(0xFFFF0000), onSelected: (_) {});

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '#FF0000',
    );

    expect(wheelFinder(), findsOneWidget);
    await tester.tap(wheelFinder());
    await tester.pump();

    // 红 → 圆心（饱和度 0、亮度保持 1）= 白
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '#FFFFFF',
    );
  });

  testWidgets('非法色号只给内联提示，确定时回退色轮当前色', (tester) async {
    Color? picked;
    await openDialog(tester,
        current: const Color(0xFFFF0000), onSelected: (c) => picked = c);

    await tester.enterText(find.byType(TextField), 'zzzzzz');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('格式不对，示例：#1E88E5'), findsOneWidget);
    // 提示出现时不得改动当前颜色
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'zzzzzz',
    );

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(picked, const Color(0xFFFF0000));
  });

  testWidgets('取消按钮不产出颜色', (tester) async {
    Color? picked;
    await openDialog(tester,
        current: AppTheme.defaultSeedColor, onSelected: (c) => picked = c);

    await tester.enterText(find.byType(TextField), '#ff0000');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(picked, isNull);
  });
}
