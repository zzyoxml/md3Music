import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/core/widgets/app_background.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('嵌套路由静止后不重复叠加壁纸', (tester) async {
    SharedPreferences.setMockInitialValues({'use_background_image': true});
    final provider = ThemeProvider(initialUseBackgroundImage: true);
    final innerNavigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.lightThemeFromSeed(AppTheme.defaultSeedColor),
          builder: (context, child) => Stack(
            fit: StackFit.expand,
            children: [const AppBackground(), child!],
          ),
          home: Navigator(
            key: innerNavigator,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Center(child: Text('内部页面')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 全局、主页路由、内部路由各有一个节点；后两者静止后均不绘制。
    expect(find.byType(AppBackground), findsNWidgets(3));
    final routeBackgrounds = tester.widgetList<Opacity>(
      find.ancestor(
        of: find.byType(AppBackground),
        matching: find.byType(Opacity),
      ),
    );
    expect(routeBackgrounds.length, 2);
    expect(routeBackgrounds.every((opacity) => opacity.opacity == 0), isTrue);

    innerNavigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Center(child: Text('下一页')),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final duringTransition = tester.widgetList<Opacity>(
      find.ancestor(
        of: find.byType(AppBackground),
        matching: find.byType(Opacity),
      ),
    );
    expect(duringTransition.any((opacity) => opacity.opacity == 1), isTrue);
    await tester.pumpAndSettle();
    final afterTransition = tester.widgetList<Opacity>(
      find.ancestor(
        of: find.byType(AppBackground),
        matching: find.byType(Opacity),
      ),
    );
    expect(afterTransition.every((opacity) => opacity.opacity == 0), isTrue);
  });
}
