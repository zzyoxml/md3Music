import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/core/widgets/windows_window_frame.dart';

void main() {
  testWidgets('Windows播放页沉浸隐藏标题栏且不留空白，退出后恢复', (tester) async {
    const channel = MethodChannel('md3music/window_tray');
    PlayerPanelSignal.expansion.value = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() {
      PlayerPanelSignal.expansion.value = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => WindowsWindowFrame(child: child!),
        home: const SizedBox.expand(key: ValueKey('immersive_body')),
      ),
    );
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('immersive_body'));
    final element = tester.element(body);
    final normal = tester.getRect(body);
    expect(normal.top, 32);
    expect(find.byKey(const ValueKey('windows_title_bar')), findsOneWidget);
    for (final progress in [.2, 1.0, .4]) {
      PlayerPanelSignal.expansion.value = progress;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('windows_title_bar')), findsNothing);
      expect(find.byKey(const ValueKey('windows_closeWindow')), findsNothing);
      expect(tester.getRect(body).top, 0);
      expect(tester.getRect(body).bottom, normal.bottom);
      expect(tester.element(body), same(element));
      expect(tester.takeException(), isNull);
      debugPrint('PLAYER progress=$progress titlebar=hidden bodyTop=0');
    }
    PlayerPanelSignal.expansion.value = 0;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('windows_title_bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('windows_minimize')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('windows_toggleMaximize')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('windows_closeWindow')), findsOneWidget);
    expect(tester.getRect(body), normal);
    expect(tester.element(body), same(element));
    expect(tester.takeException(), isNull);
    debugPrint('PLAYER progress=0 titlebar=restored bodyTop=32');
  }, skip: !Platform.isWindows);
}
