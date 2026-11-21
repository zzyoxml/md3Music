import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/widgets/windows_window_frame.dart';

void main() {
  testWidgets('标题栏在 MaterialApp.builder 外置于 Navigator 时悬停三键无异常', (
    tester,
  ) async {
    const channel = MethodChannel('md3music/window_tray');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => WindowsWindowFrame(child: child!),
        home: const SizedBox.expand(),
      ),
    );
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(100, 100));
    for (final action in ['minimize', 'toggleMaximize', 'closeWindow']) {
      final button = find.byKey(ValueKey('windows_$action'));
      final rect = tester.getRect(button);
      await mouse.moveTo(rect.center);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(button), rect);
      await mouse.moveTo(const Offset(100, 100));
      await tester.pumpAndSettle();
    }
    await mouse.removePointer();
  }, skip: !Platform.isWindows);
}
