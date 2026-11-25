import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';

/// 折叠屏展开（竖屏）下双栏几何的 widget 回归（issue #138）。
///
/// 复刻线上场景：窗口 ~790dp 宽（竖屏折叠屏展开）、折痕在窗口正中、姿势为
/// **完全展开**。修复前折痕被当成竖直障碍 → master/detail 一起被塞到折痕一侧，
/// master 只剩半屏、另一侧近半屏留白；修复后平展折痕不参与分栏 → master 满宽。
ui.DisplayFeature _fold(
  ui.DisplayFeatureState state, {
  Rect bounds = const Rect.fromLTWH(390, 0, 20, 880),
}) =>
    ui.DisplayFeature(
      bounds: bounds,
      type: ui.DisplayFeatureType.fold,
      state: state,
    );

Future<void> _pumpPane(
  WidgetTester tester,
  List<ui.DisplayFeature> features,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(790, 880);
  tester.view.displayFeatures = features;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const MaterialApp(
      home: DesktopTwoPane(
        responsive: true,
        master: SizedBox.expand(key: Key('fold-master')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _masterRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('fold-master')));

void main() {
  // 双栏开关三端通用后显式开启：本组用例断言的是双栏几何对折痕的避让。
  setUp(() {
    kWindowsTwoPaneEnabled.value = true;
  });
  tearDown(() => kWindowsTwoPaneEnabled.value = false);

  testWidgets('竖屏展开（fold + postureFlat）：内容满宽，不再被折痕挤到一侧', (tester) async {
    await _pumpPane(tester, [_fold(ui.DisplayFeatureState.postureFlat)]);
    final master = _masterRect(tester);
    expect(master.left, 0);
    expect(master.width, 790, reason: '平展折痕不分隔可用空间，master 必须占满面板');
    expect(tester.takeException(), isNull);
  });

  testWidgets('平展折痕 0 宽（只标折痕线）同样不挤', (tester) async {
    await _pumpPane(tester, [
      _fold(
        ui.DisplayFeatureState.postureFlat,
        bounds: const Rect.fromLTWH(395, 0, 0, 880),
      ),
    ]);
    expect(_masterRect(tester).width, 790);
  });

  testWidgets('半开（fold + postureHalfOpened）仍按折痕收拢到一侧', (tester) async {
    await _pumpPane(tester, [_fold(ui.DisplayFeatureState.postureHalfOpened)]);
    final master = _masterRect(tester);
    // 折痕 390..410、面板 790：右侧剩 380 < 折痕左缘 390 → 落在左半
    expect(master.left, 0);
    expect(master.width, 390);
  });

  testWidgets('物理铰链（hinge + postureFlat，40dp）仍避让 —— 双屏机语义不回退', (tester) async {
    await _pumpPane(tester, [
      ui.DisplayFeature(
        bounds: const Rect.fromLTWH(390, 0, 40, 880),
        type: ui.DisplayFeatureType.hinge,
        state: ui.DisplayFeatureState.postureFlat,
      ),
    ]);
    expect(_masterRect(tester).width, 390);
  });

  testWidgets('无 displayFeatures 的 790dp 基线：满宽（改动不引入额外偏移）', (tester) async {
    await _pumpPane(tester, const <ui.DisplayFeature>[]);
    final master = _masterRect(tester);
    expect(master.left, 0);
    expect(master.width, 790);
  });
}
