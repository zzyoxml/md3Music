// 播放速度弹窗测试。
//
// 三条回归点：
// 1) 滑块下方不再逐档标注倍数（0.25x/1x/4x 那行已删）；
// 2) 居中大数字只有数字，没有 'x'；
// 3) 选档回调拿到的值来自 kPlaybackSpeeds。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import 'package:md3music/modules/player/speed_picker_sheet.dart';

void main() {
  Widget host({required double currentSpeed, required ValueChanged<double> onSelected}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showSpeedPickerDialog(
                context: context,
                currentSpeed: currentSpeed,
                onSelected: onSelected,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  group('formatPlaybackSpeed', () {
    test('去掉多余的 .0', () {
      expect(formatPlaybackSpeed(1.0), '1');
      expect(formatPlaybackSpeed(2.0), '2');
      expect(formatPlaybackSpeed(4.0), '4');
    });

    test('保留非整数位', () {
      expect(formatPlaybackSpeed(0.25), '0.25');
      expect(formatPlaybackSpeed(0.75), '0.75');
      expect(formatPlaybackSpeed(1.25), '1.25');
    });
  });

  testWidgets('弹窗标题在、没有逐档倍数行、大数字不带 x', (tester) async {
    await tester.pumpWidget(host(currentSpeed: 1.0, onSelected: (_) {}));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('播放速度'), findsOneWidget);
    // 居中大数字
    expect(find.text('1'), findsOneWidget);
    expect(find.text('1x'), findsNothing);
    // 逐档倍数行已删：只有 1x / 4x 这两个最容易残留的标签作为探针
    expect(find.text('1x'), findsNothing);
    expect(find.text('4x'), findsNothing);
    expect(find.text('0.25x'), findsNothing);
  });

  testWidgets('当前速度是非 1 档时大数字显示真实档位', (tester) async {
    await tester.pumpWidget(host(currentSpeed: 2.0, onSelected: (_) {}));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('拖动滑块按档位回调', (tester) async {
    final picked = <double>[];
    await tester.pumpWidget(host(currentSpeed: 1.0, onSelected: picked.add));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final slider = find.byType(M3ESlider);
    expect(slider, findsOneWidget);
    // 拖到最右 = 第 8 档 = 4.0
    await tester.drag(slider, const Offset(600, 0));
    await tester.pumpAndSettle();

    expect(picked, isNotEmpty);
    expect(picked.last, inInclusiveRange(0.25, 4.0));
    expect(kPlaybackSpeeds, contains(picked.last));
  });
}
