import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  @override
  Future<String?> getExternalStoragePath() async => Directory.systemTemp.path;
}

class _SettingsTabHost extends StatefulWidget {
  const _SettingsTabHost();

  @override
  State<_SettingsTabHost> createState() => _SettingsTabHostState();
}

class _SettingsTabHostState extends State<_SettingsTabHost> {
  bool _settingsTabActive = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: () => setState(() => _settingsTabActive = !_settingsTabActive),
          child: const Text('切换标签页'),
        ),
        Expanded(
          child: TickerMode(
            enabled: _settingsTabActive,
            child: const SettingsPage(),
          ),
        ),
      ],
    );
  }
}

void main() {
  testWidgets('Windows 设置标签页隐藏时释放车机面板抑制，重新显示时恢复', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths();
    addTearDown(() => PathProviderPlatform.instance = previousPaths);

    final carMode = CarModeProvider();
    addTearDown(carMode.dispose);
    await carMode.setEnabled(true);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ],
        child: const MaterialApp(home: _SettingsTabHost()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(carMode.panelSuppressCount, 1);
    expect(carMode.panelVisible, isFalse);
    await tester.tap(find.text('切换标签页'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(carMode.panelSuppressCount, Platform.isWindows ? 0 : 1);
    expect(carMode.panelVisible, Platform.isWindows);

    await tester.tap(find.text('切换标签页'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(carMode.panelSuppressCount, 1);
    expect(carMode.panelVisible, isFalse);
  });
}
