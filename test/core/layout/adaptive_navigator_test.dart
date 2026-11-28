import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/widgets/resizable_splitter.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';

class _WallpaperTheme extends ThemeProvider {
  bool enabled = false;
  @override
  bool get useBackgroundImage => enabled;
  void toggle() {
    enabled = !enabled;
    notifyListeners();
  }
}

void main() {
  testWidgets('壁纸开关首帧移除旧实色，不等待主题或 Material 颜色动画', (tester) async {
    final theme = _WallpaperTheme();
    addTearDown(theme.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>.value(
      value: theme,
      child: MaterialApp(
        // 模拟 AnimatedTheme 尚未推进、scaffold 仍为旧实色的首帧。
        theme: ThemeData(scaffoldBackgroundColor: Colors.white),
        home: const DetailEmptyState(),
      ),
    ));
    Material panel() => tester.widget<Material>(find.descendant(
      of: find.byType(DetailEmptyState), matching: find.byType(Material)).first);
    expect(panel().color, isNot(Colors.transparent));
    theme.toggle();
    await tester.pump();
    expect(panel().color, Colors.transparent);
    expect(panel().animationDuration, Duration.zero);
    theme.toggle();
    await tester.pump();
    expect(panel().color, isNot(Colors.transparent));
  });
  for (final responsive in [false, true]) {
    testWidgets('已有空态路由跟随壁纸开关，保留 Navigator responsive=$responsive', (tester) async {
      final previous = kWindowsTwoPaneEnabled.value;
      kWindowsTwoPaneEnabled.value = true;
      addTearDown(() => kWindowsTwoPaneEnabled.value = previous);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 900);
      addTearDown(tester.view.reset);
      final wallpaper = ValueNotifier(false);
      addTearDown(wallpaper.dispose);
      final navKey = GlobalKey<NavigatorState>();
      final page = DesktopTwoPane(responsive: responsive,
          detailKey: navKey, master: const SizedBox());
      await tester.pumpWidget(ValueListenableBuilder<bool>(
        valueListenable: wallpaper,
        builder: (context, enabled, child) => MaterialApp(
          theme: ThemeData(scaffoldBackgroundColor:
              enabled ? Colors.transparent : Colors.white),
          home: page,
        ),
      ));
      await tester.pumpAndSettle();
      final originalNav = navKey.currentState;
      Color? surface() => tester.widget<Material>(find.descendant(
        of: find.byType(DetailEmptyState), matching: find.byType(Material)).first).color;
      expect(surface(), isNot(Colors.transparent));
      wallpaper.value = true;
      await tester.pumpAndSettle();
      expect(surface(), Colors.transparent);
      expect(navKey.currentState, same(originalNav));
      wallpaper.value = false;
      await tester.pumpAndSettle();
      expect(surface(), isNot(Colors.transparent));
      expect(navKey.currentState, same(originalNav));
    });
  }
  group('DetailEmptyState', () {
    testWidgets('默认参数渲染桌面外壳原文案与图标（行为不变）', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: DetailEmptyState()));
      await tester.pumpAndSettle();

      expect(find.text('从左侧选择一项查看详情'), findsOneWidget);
      expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
    });

    testWidgets('自定义图标与文案（设置页空态复用）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DetailEmptyState(
            icon: Icons.tune,
            text: '从左侧选择分类进行配置',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('从左侧选择分类进行配置'), findsOneWidget);
      expect(find.byIcon(Icons.tune), findsOneWidget);
    });
  });

  testWidgets('Windows 自定义背景下空详情透明且不绘制分隔线', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // 上游 2026-10-24 起 Windows 双栏默认关闭（kWindowsTwoPaneEnabled=false）；
    // 本用例验证的是「双栏空详情在自定义背景下的透明度契约」，需显式开启。
    final bool previousTwoPane = kWindowsTwoPaneEnabled.value;
    kWindowsTwoPaneEnabled.value = true;
    addTearDown(() => kWindowsTwoPaneEnabled.value = previousTwoPane);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      home: DesktopTwoPane(responsive: true, master: const SizedBox()),
    ));
    await tester.pumpAndSettle();

    expect(tester.widget<Material>(find.descendant(
      of: find.byType(DetailEmptyState), matching: find.byType(Material)).first).color,
      Colors.transparent);
    expect(tester.widget<ResizableSplitter>(find.byType(ResizableSplitter)).color,
        Colors.transparent);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('壁纸模式（透明背景）下任意平台双栏都透明：详情面板与分隔线', (tester) async {
    // 契约变更（用户反馈）：原实现只认 Windows 平台，Android 平板开桌面布局 +
    // 壁纸时右侧仍是纯 surface 白板、两栏之间还露一条竖线，壁纸被切断。
    // 现在判据是主题信号 scaffoldBackgroundColor（壁纸模式置为透明），
    // 与平台无关，故 Android 也应透明。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // 双栏开关三端通用后，本用例需显式开启。
    final bool previousTwoPane = kWindowsTwoPaneEnabled.value;
    kWindowsTwoPaneEnabled.value = true;
    addTearDown(() => kWindowsTwoPaneEnabled.value = previousTwoPane);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      home: DesktopTwoPane(responsive: true, master: const SizedBox()),
    ));
    await tester.pumpAndSettle();

    expect(tester.widget<Material>(find.descendant(
      of: find.byType(DetailEmptyState), matching: find.byType(Material)).first).color,
      Colors.transparent);
    expect(tester.widget<ResizableSplitter>(find.byType(ResizableSplitter)).color,
        Colors.transparent);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('非壁纸模式（不透明背景）下 Android 分栏保持原有背景和分隔线', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final bool previousTwoPane = kWindowsTwoPaneEnabled.value;
    kWindowsTwoPaneEnabled.value = true;
    addTearDown(() => kWindowsTwoPaneEnabled.value = previousTwoPane);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: DesktopTwoPane(responsive: true, master: const SizedBox()),
    ));
    await tester.pumpAndSettle();

    final empty = tester.widget<DetailEmptyState>(find.byType(DetailEmptyState));
    expect(empty.color, isNull);
    expect(tester.widget<ResizableSplitter>(find.byType(ResizableSplitter)).color,
        isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
