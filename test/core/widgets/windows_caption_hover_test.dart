import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/ui_density.dart';
import 'package:md3music/core/widgets/windows_window_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('md3music/window_tray');
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('悬停不越界且不改布局 dark=$dark scale=$scale', (tester) async {
        tester.view.physicalSize = const Size(900, 180);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => false);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        const capture = ValueKey('hover_capture');
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: RepaintBoundary(
              key: capture,
              child: DisplayScaleScope(
                scale: scale,
                child: const Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(color: Color(0xff427e88)),
                    ),
                    WindowsWindowFrame(child: SizedBox.expand()),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<List<int>> pixels() async => (await tester.runAsync(() async {
          final image =
              await (tester.renderObject(find.byKey(capture))
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final result = data!.buffer.asUint8List().toList();
          image.dispose();
          return result;
        }))!;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(300, 140));
        final bar = tester.getRect(
          find.byKey(const ValueKey('windows_title_bar')),
        );
        for (final action in ['minimize', 'toggleMaximize', 'closeWindow']) {
          await mouse.moveTo(const Offset(300, 140));
          await tester.pump(const Duration(milliseconds: 300));
          final button = find.byKey(ValueKey('windows_$action'));
          final rect = tester.getRect(button);
          final before = await pixels();
          await mouse.moveTo(rect.center);
          await tester.pump(const Duration(milliseconds: 300));
          final after = await pixels();
          expect(tester.getRect(button), rect);
          expect(
            tester.getRect(find.byKey(const ValueKey('windows_title_bar'))),
            bar,
          );
          var outside = 0;
          var inside = 0;
          for (var y = 0; y < bar.bottom.floor(); y++) {
            for (var x = 0; x < 900; x++) {
              final i = (y * 900 + x) * 4;
              if (before[i] == after[i] &&
                  before[i + 1] == after[i + 1] &&
                  before[i + 2] == after[i + 2]) {
                continue;
              }
              if (rect.inflate(1).contains(Offset(x + .5, y + .5))) {
                inside++;
              } else {
                outside++;
              }
            }
          }
          // 必须有轻微反馈，不能靠完全取消鼠标反馈来规避越界。
          expect(inside, greaterThan(0));
          final colors = Theme.of(tester.element(button)).colorScheme;
          final tone =
              (action == 'closeWindow' ? colors.error : colors.onSurface)
                  .toARGB32();
          final sampleX = (rect.left + 6 * scale).floor();
          final sampleY = (rect.top + 16 * scale).floor();
          final sample = (sampleY * 900 + sampleX) * 4;
          for (var channel = 0; channel < 3; channel++) {
            final shade = (tone >> (16 - 8 * channel)) & 255;
            final expected = (before[sample + channel] * .88 + shade * .12)
                .round();
            expect(after[sample + channel], closeTo(expected, 2));
          }
          debugPrint(
            'HOVER $action dark=$dark scale=$scale inside=$inside outside=$outside',
          );
          expect(outside, 0);
        }
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      }, skip: !Platform.isWindows);
    }
  }
}
