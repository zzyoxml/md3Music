import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/desktop_shell.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedPlayerProvider extends ChangeNotifier implements PlayerProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter && invocation.memberName == #currentSong) {
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows 全部还原后保活桌面侧栏回到默认宽度', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'desktop_sidebar_width': 330.0});
    final theme = ThemeProvider();
    await theme.windowsSettingsReady;
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ChangeNotifierProvider<PlayerProvider>.value(
            value: _UnusedPlayerProvider(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: DesktopShell(
            visibleTabs: const [],
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            pageBuilder: (_) => const SizedBox.shrink(),
            railDestinations: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.width == 330.0,
      ),
      findsOneWidget,
    );

    await SettingsRepository().resetAllSettingsToDefaults();
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.width == 240.0,
      ),
      findsOneWidget,
    );
  }, skip: !Platform.isWindows);
}
