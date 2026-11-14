// 桌面歌词设置面板在 **material_ui** 宿主下的构建回归测试。
//
// 钉死 docs/agents/troubleshooting.md §4.13：设置页宿主是 material_ui 的
// `Scaffold`，它给 body 包的是 material_ui **自家**的 `Material`（同名不同型）。
// 面板内若用 flutter/material 的 `InkWell` / `SwitchListTile`（按**类型**找祖先
// Material），就会抛 `No Material widget found`，再被全局 `_FallbackErrorWidget`
// 顶成「此处内容加载出错」——真机表现为「设置 → 歌词 → 设备歌词」整块变错误提示。
//
// 因此本测试的宿主**必须**是 material_ui 的 App/Scaffold，不能用 flutter/material
// 的 Scaffold 糊过去（那样永远测不出这个坑）。面板自身那层
// `Material(type: MaterialType.transparency)` 是修复本体，删掉它本用例应当变红。
import 'package:flutter/material.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/modules/settings/desktop_lyric_settings_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `DesktopLyricService` 是**进程级单例**，首次访问 `instance` 就在构造里启动
  // 一个 5s 周期的原生状态轮询 Timer（`_syncNativeSyncProbeInterval`）。面板
  // `State` 的字段初始化即取单例，所以每个用例都会碰它；不处理的话测试结束时
  // `!timersPending` 校验会判失败。
  //
  // 解法与 `desktop_lyric_alignment_test.dart` 同源：在 `fakeAsync` 的假时钟里
  // 先把单例建出来，Timer 落在那个 fake zone 上，不会泄漏到用例的真实 zone。
  setUpAll(() {
    fakeAsync((_) {
      DesktopLyricService.instance;
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// material_ui 的 `MaterialApp` + `Scaffold`：与真机设置页完全同构的宿主。
  ///
  /// `Scaffold` 一定解析到 material_ui 的那个 —— 本文件以 `mui` 前缀 import，
  /// 避免和 `fm`（flutter/material）混名。
  Future<void> pumpUnderMaterialUiHost(WidgetTester tester) async {
    // 视口放大：面板很长，四块分区都要能构建到（不影响判定点）。
    tester.view.physicalSize = const fm.Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      mui.MaterialApp(
        home: mui.Scaffold(
          body: mui.ListView(
            children: const <mui.Widget>[
              DesktopLyricSettingsPanel(),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// `DesktopLyricService` 单例在 `setUpAll` 里已建好（Timer 落在 fake zone），
  /// 这里无需再收尾。
  tearDown(() {
    // 面板卸载后服务自己会收敛；残留 Timer 已在 setUpAll 的 fake zone 里。
  });

  testWidgets('material_ui 宿主下面板不抛 No Material widget found',
      (WidgetTester tester) async {
    await pumpUnderMaterialUiHost(tester);

    // 有异常时框架会把它挂到 takeException()，且页面被 ErrorWidget 顶掉。
    expect(tester.takeException(), isNull);
    expect(find.byType(DesktopLyricSettingsPanel), findsOneWidget);
    // 面板真的构建出内容（不是被 ErrorWidget 顶成红块）
    expect(find.byType(fm.InkWell), findsWidgets);
  });

  testWidgets('material_ui 宿主下展开「自调颜色」不炸（隐藏分支也要有 Material）',
      (WidgetTester tester) async {
    await pumpUnderMaterialUiHost(tester);

    // 自调颜色默认收起；点开后才 build 那两条色相条 + 色板。
    final disclosure = find.text('自调颜色');
    expect(disclosure, findsWidgets);
    await tester.tap(disclosure.first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(DesktopLyricSettingsPanel), findsOneWidget);
  });

  testWidgets('锁定行（SwitchListTile）在 material_ui 宿主下可用',
      (WidgetTester tester) async {
    await pumpUnderMaterialUiHost(tester);

    // SwitchListTile 是 flutter/material 的 ink 组件，最容易踩本坑。
    expect(find.byType(fm.SwitchListTile), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板改动会回写 DesktopLyricService（宿主转发链路通）',
      (WidgetTester tester) async {
    await pumpUnderMaterialUiHost(tester);

    // `doubleLine` 默认 false（单行）；点「双行」才是有效变更。
    final before = DesktopLyricService.instance.doubleLine;
    expect(before, isFalse, reason: '默认应为单行，否则本用例的变更方向无效');
    await tester.tap(find.text('双行'));
    await tester.pumpAndSettle();
    expect(DesktopLyricService.instance.doubleLine, isTrue);
  });
}
