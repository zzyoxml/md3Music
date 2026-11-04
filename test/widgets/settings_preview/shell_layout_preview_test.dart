import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/widgets/settings_preview/shell_layout_preview.dart';

/// 两种播放条外观的 key（与实现处同名常量对应）。
const Key _capsule = Key('settingsPreview.capsule');
const Key _persistentBar = Key('settingsPreview.persistentBar');

int _countByKey(WidgetTester tester, Key key) =>
    tester.widgetList(find.byKey(key)).length;

void main() {
  setUp(() {
    // 每个用例从干净的 notifier 开始（全局单例会被别的用例污染）
    kDesktopModeEnabled.value = false;
    kSecondaryPlayerEnabled.value = false;
    kSecondaryPlayerOnPrimaryPages.value = true;
    kSecondaryPlayerProgressEnabled.value = true;
    kHideNavBarOnSecondaryPages.value = true;
    kWindowsTwoPaneEnabled.value = true;
  });

  testWidgets('Windows 双栏开关在原布局预览区域动画切换', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 1,
              hideNavBarOnSecondary: true,
              showWindowsTwoPanePreview: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('双栏已开启 · 左右各占 50%'), findsOneWidget);
    expect(find.byKey(const Key('settingsPreview.windowsTwoPane.left')), findsOneWidget);
    expect(find.byKey(const Key('settingsPreview.windowsTwoPane.right')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('settingsPreview.windowsTwoPane.left'))).width,
      tester.getSize(find.byKey(const Key('settingsPreview.windowsTwoPane.right'))).width,
    );

    kWindowsTwoPaneEnabled.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(
      tester.getSize(find.byKey(const Key('settingsPreview.windowsTwoPane.right'))).width,
      greaterThan(0),
      reason: '切换过程中详情栏应有宽度动画',
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('双栏已关闭 · 当前页面单栏显示'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('settingsPreview.windowsTwoPane.right'))).width,
      0,
    );
    expect(
      tester.getSize(find.byKey(const Key('settingsPreview.windowsTwoPane.left'))).width,
      greaterThan(400),
      reason: '单栏时一级页面扩展填满预览区',
    );

    kWindowsTwoPaneEnabled.value = true;
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('双栏已开启 · 左右各占 50%'), findsOneWidget);
    expect(find.byKey(const Key('settingsPreview.windowsTwoPane.right')), findsOneWidget);
  });

  testWidgets('悬浮播放器开启时渲染胶囊形态', (tester) async {
    kSecondaryPlayerEnabled.value = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 1,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 悬浮形态：常驻条不渲染（常驻条是 height 22 的容器，这里以文案兜底）
    expect(find.text('一级页面'), findsOne);
  });

  testWidgets('桌面布局开启时渲染侧栏形态', (tester) async {
    kDesktopModeEnabled.value = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 1,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('侧栏布局'), findsOne);
  });

  testWidgets('底栏标签模式 2（始终不显示）时不渲染标签文字', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 2,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('首页'), findsNothing);
    expect(find.text('搜索'), findsNothing);
  });

  testWidgets('底栏标签模式 0（始终显示）时渲染全部标签', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 0,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('首页'), findsWidgets);
    expect(find.text('搜索'), findsWidgets);
    expect(find.text('音乐库'), findsWidgets);
  });

  testWidgets('二级页面隐藏底栏时右框不渲染底栏', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 0,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 右框标签应写「底栏已收起」
    expect(find.text('二级页面（底栏已收起）'), findsOne);
  });

  testWidgets('总开关开、一级开关关时：二级悬浮，一级常驻', (tester) async {
    // 真机反馈的正确行为：打开迷你悬浮播放器 → 二级页就是悬浮；
    // 再打开「一级页面使用悬浮底栏」→ 一二级才都是悬浮。
    // 所以「总开关开 + 一级开关关」时一二级形态必须不同。
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = false;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 1,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('一级页面'), findsOne);
    // 两框各一条播放条 → 1 胶囊（二级）+ 1 常驻条（一级）
    expect(_countByKey(tester, _capsule), 1, reason: '二级页应悬浮');
    expect(_countByKey(tester, _persistentBar), 1,
        reason: '一级页应退回常驻条');
  });

  testWidgets('两个开关都开时：一二级都是悬浮', (tester) async {
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerOnPrimaryPages.value = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 1,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(_countByKey(tester, _capsule), 2, reason: '一二级都应悬浮');
    expect(_countByKey(tester, _persistentBar), 0);
  });

  testWidgets('总开关关闭时只有常驻条', (tester) async {
    kSecondaryPlayerEnabled.value = false;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 1,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_countByKey(tester, _persistentBar), greaterThan(0));
    expect(_countByKey(tester, _capsule), 0,
        reason: '总开关关闭时不应有悬浮胶囊');
  });

  testWidgets('进度环开关关闭时不渲染描边胶囊', (tester) async {
    kSecondaryPlayerEnabled.value = true;
    kSecondaryPlayerProgressEnabled.value = false;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ShellLayoutPreview(
              navLabelMode: 1,
              hideNavBarOnSecondary: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
