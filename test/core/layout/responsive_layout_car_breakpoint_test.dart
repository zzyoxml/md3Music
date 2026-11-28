import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 横屏车机侧边面板的两处回归：
/// 1. 主界面被压窄后不能从 rail 退化成 compact（底部 NavigationBar 会挡住内容）；
/// 2. MiniPlayer 隐藏后，rail 布局要自己让出底部系统 Taskbar 的 inset。
void main() {
  Widget scaffold({
    required bool useFullWidthForBreakpoint,
    double paddingBottom = 0,
    double viewPaddingBottom = 0,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        // Center 松开 tight 约束，让 SizedBox 真正把主界面压到 500dp 宽；
        // MediaQuery 仍是整屏 800dp，模拟车机侧边面板下的主界面。
        home: Center(
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: EdgeInsets.only(bottom: paddingBottom),
                viewPadding: EdgeInsets.only(bottom: viewPaddingBottom),
              ),
              child: SizedBox(
                width: 500,
                height: 600,
                child: ResponsiveScaffold(
                  destinations: const <NavigationDestination>[
                    NavigationDestination(
                      icon: Icon(Icons.home),
                      label: '首页',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.search),
                      label: '搜索',
                    ),
                  ],
                  railDestinations: const <NavigationRailDestination>[
                    NavigationRailDestination(
                      icon: Icon(Icons.home),
                      label: Text('首页'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.search),
                      label: Text('搜索'),
                    ),
                  ],
                  drawerDestinations: const <NavigationDrawerDestination>[
                    NavigationDrawerDestination(
                      icon: Icon(Icons.home),
                      label: Text('首页'),
                    ),
                    NavigationDrawerDestination(
                      icon: Icon(Icons.search),
                      label: Text('搜索'),
                    ),
                  ],
                  selectedIndex: 0,
                  onDestinationSelected: (_) {},
                  body: const SizedBox.expand(key: Key('rail-body')),
                  useFullWidthForBreakpoint: useFullWidthForBreakpoint,
                  reserveBottomInRail: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('未开启时仍按局部宽度判定为 compact，出现底部导航栏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(scaffold(useFullWidthForBreakpoint: false));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('车机侧边面板开启时按整屏宽度保持 rail，不出现底部导航栏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(scaffold(useFullWidthForBreakpoint: true));

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('车机 rail 按 viewPadding.bottom 让出系统 Taskbar 净空', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);

    // edge-to-edge 下 Taskbar 可能只记在 viewPadding：padding=10，viewPadding=40。
    await tester.pumpWidget(scaffold(
      useFullWidthForBreakpoint: true,
      paddingBottom: 10,
      viewPaddingBottom: 40,
    ));

    final body = tester.getRect(find.byKey(const Key('rail-body')));
    expect(body.bottom, closeTo(600 - 40, 0.5));
    expect(tester.takeException(), isNull);
  });
}
