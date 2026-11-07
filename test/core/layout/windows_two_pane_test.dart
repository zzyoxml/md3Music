import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/page_layout.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/widgets/resizable_splitter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows 双栏默认关闭，显式开启后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    expect(await repo.getWindowsTwoPaneEnabled(), isFalse);
    await repo.setWindowsTwoPaneEnabled(true);
    expect(await repo.getWindowsTwoPaneEnabled(), isTrue);
  });

  group('resolvePaneGeometry.forceTwoPane（TV 恒双栏的纯函数契约）', () {
    test('force 绕过 1000dp 断点：960dp 也出双栏', () {
      final g = resolvePaneGeometry(
        width: 960,
        masterFraction: .34,
        twoPaneEnabled: false,
        forceTwoPane: true,
      );
      expect(g.twoPane, isTrue, reason: 'TV 构建不随分辨率/DPI 退化单栏');
      expect(g.masterWidth, greaterThanOrEqualTo(300));
      expect(g.detailWidth, greaterThanOrEqualTo(496 - 16));
    });

    test('force 不理会开关：twoPaneEnabled=false 仍双栏', () {
      final g = resolvePaneGeometry(
        width: 1280,
        masterFraction: .34,
        twoPaneEnabled: false,
        forceTwoPane: true,
      );
      expect(g.twoPane, isTrue);
    });

    test('不 force 时行为不变：960dp + 开关关 = 单栏（回归）', () {
      final g = resolvePaneGeometry(
        width: 960,
        masterFraction: .34,
        twoPaneEnabled: false,
      );
      expect(g.twoPane, isFalse);
      expect(g.masterWidth, 960, reason: '非 TV 构建零变化');
    });
  });

  for (final responsive in [false, true]) {
    testWidgets('Windows responsive=$responsive 默认等分且关闭可保留详情栈',
        (tester) async {
      kWindowsTwoPaneEnabled.value = true;
      addTearDown(() => kWindowsTwoPaneEnabled.value = true);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 900);
      addTearDown(tester.view.reset);
      final detailKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        home: DesktopTwoPane(
          responsive: responsive,
          detailKey: detailKey,
          master: const SizedBox.expand(key: Key('windows-master')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('windows-master'))).width, 792);
      expect(tester.getSize(find.byKey(const ValueKey('responsive-detail'))).width,
          792);

      detailKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Center(child: Text('保留的详情')),
      ));
      await tester.pumpAndSettle();
      final navigator = detailKey.currentState;
      kWindowsTwoPaneEnabled.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(ResizableSplitter), findsNothing);
      expect(find.text('保留的详情'), findsOneWidget);
      expect(detailKey.currentState, same(navigator));
      expect(tester.getSize(find.byKey(const ValueKey('responsive-detail'))).width,
          1600);
      detailKey.currentState!.pop();
      await tester.pumpAndSettle();
      final masterBounds = tester.widget<Positioned>(find.ancestor(
        of: find.byKey(const Key('windows-master')),
        matching: find.byType(Positioned),
      ).first);
      expect(masterBounds.width, 1600);
      expect(find.text('从左侧选择一项查看详情'), findsNothing);

      kWindowsTwoPaneEnabled.value = true;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('windows-master'))).width, 792);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('Android 宽屏默认双栏，关闭开关后退单栏', (tester) async {
    // 上游 2026-10-25 起双栏开关三端通用（kWindowsTwoPaneEnabled 直读）；
    // Android 默认 true（main.dart 播种），关闭后宽屏退单栏、详情栈保留。
    kWindowsTwoPaneEnabled.value = false;
    addTearDown(() => kWindowsTwoPaneEnabled.value = true);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    final detailKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      home: DesktopTwoPane(
        responsive: true,
        detailKey: detailKey,
        master: const SizedBox.expand(key: Key('android-master')),
      ),
    ));
    await tester.pumpAndSettle();
    // master 本体被 ContentWidth 居中限宽（maxContentWidth=840），
    // 整宽铺满的是详情面板几何（与 Windows 关闭用例同款判据）。
    expect(find.byType(ResizableSplitter), findsNothing,
        reason: '关闭双栏后分隔条消失');
    expect(
      tester.getSize(find.byKey(const ValueKey('responsive-detail'))).width,
      1600,
      reason: '关闭双栏后详情面板占满整宽',
    );

    kWindowsTwoPaneEnabled.value = true;
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('android-master'))).width,
      544,
      reason: '开启双栏后恢复 master 列 + 分隔条 + 详情列',
    );
    expect(find.byType(ResizableSplitter), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
