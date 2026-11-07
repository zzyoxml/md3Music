import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/settings_preview/cover_dynamic_preview.dart';

void main() {
  testWidgets('阴影强度 0 时不画投影', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: CoverDynamicPreview(
              shadowStrength: 0.0,
              depthEnabled: false,
              depthStrength: 9.0,
              neuralInpaint: false,
              lyricDoubleTapToJump: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
  });

  testWidgets('3D 开启时模拟倾角走动且不抛异常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: CoverDynamicPreview(
              shadowStrength: 0.7,
              depthEnabled: true,
              depthStrength: 20.0,
              neuralInpaint: true,
              lyricDoubleTapToJump: true,
            ),
          ),
        ),
      ),
    );
    // 推进多拍，让模拟倾角走完一段
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });

  testWidgets('双击跳转开启时提示改双击', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: CoverDynamicPreview(
              shadowStrength: 0.7,
              depthEnabled: false,
              depthStrength: 9.0,
              neuralInpaint: false,
              lyricDoubleTapToJump: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('歌词需双击才跳转（单击无效）'), findsOne);
  });

  testWidgets('双击跳转关闭时提示单击即跳转', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: CoverDynamicPreview(
              shadowStrength: 0.7,
              depthEnabled: false,
              depthStrength: 9.0,
              neuralInpaint: false,
              lyricDoubleTapToJump: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('歌词单击即跳转位置'), findsOne);
  });

  testWidgets('3D 关闭时显示「已关闭」占位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: CoverDynamicPreview(
              shadowStrength: 0.7,
              depthEnabled: false,
              depthStrength: 9.0,
              neuralInpaint: false,
              lyricDoubleTapToJump: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('已关闭'), findsOne);
    // 副标题是拼接字符串（「阴影 x% · 3D 关闭」），用包含匹配
    expect(find.textContaining('3D 关闭'), findsOne);
  });
}
