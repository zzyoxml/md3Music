import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/page_layout.dart';

/// 分栏障碍判定的单测（issue #138 回归）。
///
/// 折叠屏**完全展开**时系统仍会上报那道折痕（fold + postureFlat），它并不分隔
/// 可用空间；曾经只按几何裸判的筛选会把它当竖直铰链，把整页内容挤到折痕一侧、
/// 另一侧近半屏留白。本文件把判据钉死在 Android `FoldingFeature.isSeparating()`
/// 语义上：hinge 恒分隔，fold 仅半开时分隔。
ui.DisplayFeature _f({
  ui.DisplayFeatureType type = ui.DisplayFeatureType.fold,
  ui.DisplayFeatureState state = ui.DisplayFeatureState.postureFlat,
  Rect bounds = const Rect.fromLTWH(395, 0, 0, 880),
}) => ui.DisplayFeature(bounds: bounds, type: type, state: state);

void main() {
  group('isSeparatingDisplayFeature（对齐 Android isSeparating）', () {
    test('fold + 完全展开（postureFlat）不分隔 —— issue #138 的错判点', () {
      expect(isSeparatingDisplayFeature(_f()), isFalse);
    });

    test('fold + 状态未知按不分隔处理（宁可漏分栏，不可挤半屏）', () {
      expect(
        isSeparatingDisplayFeature(
          _f(state: ui.DisplayFeatureState.unknown),
        ),
        isFalse,
      );
    });

    test('fold + 半开（postureHalfOpened）分隔', () {
      expect(
        isSeparatingDisplayFeature(
          _f(state: ui.DisplayFeatureState.postureHalfOpened),
        ),
        isTrue,
      );
    });

    test('hinge 恒分隔（双屏机物理铰链，含平展姿势）', () {
      expect(
        isSeparatingDisplayFeature(_f(type: ui.DisplayFeatureType.hinge)),
        isTrue,
      );
      expect(
        isSeparatingDisplayFeature(
          _f(
            type: ui.DisplayFeatureType.hinge,
            state: ui.DisplayFeatureState.postureHalfOpened,
          ),
        ),
        isTrue,
      );
    });

    test('cutout 不分隔（挖孔交给 SafeArea / padding）', () {
      expect(
        isSeparatingDisplayFeature(
          _f(
            type: ui.DisplayFeatureType.cutout,
            state: ui.DisplayFeatureState.unknown,
            bounds: const Rect.fromLTWH(395, 0, 24, 24),
          ),
        ),
        isFalse,
      );
    });
  });

  group('verticalPaneObstructions', () {
    const view = Size(790, 880);

    test('平展折痕（0 宽 / 40dp 宽）都不进障碍列表', () {
      expect(
        verticalPaneObstructions(features: [_f()], viewSize: view, leftInset: 0),
        isEmpty,
      );
      expect(
        verticalPaneObstructions(
          features: [_f(bounds: const Rect.fromLTWH(390, 0, 20, 880))],
          viewSize: view,
          leftInset: 0,
        ),
        isEmpty,
      );
    });

    test('半开折痕保留，并扣掉 rail / 左安全区的 leftInset', () {
      final half = _f(
        state: ui.DisplayFeatureState.postureHalfOpened,
        bounds: const Rect.fromLTWH(390, 0, 20, 880),
      );
      expect(
        verticalPaneObstructions(
          features: [half],
          viewSize: view,
          leftInset: 0,
        ),
        [const Rect.fromLTWH(390, 0, 20, 880)],
      );
      // rail 占掉 81dp：窗口坐标 → 面板局部坐标
      expect(
        verticalPaneObstructions(
          features: [half],
          viewSize: view,
          leftInset: 81,
        ),
        [const Rect.fromLTWH(309, 0, 20, 880)],
      );
    });

    test('物理铰链（40dp 宽、平展）保留 —— 双屏机语义不回退', () {
      final hinge = _f(
        type: ui.DisplayFeatureType.hinge,
        bounds: const Rect.fromLTWH(390, 0, 40, 880),
      );
      expect(
        verticalPaneObstructions(
          features: [hinge],
          viewSize: view,
          leftInset: 0,
        ),
        [const Rect.fromLTWH(390, 0, 40, 880)],
      );
    });

    test('0 宽铰链 + 平展：物理上不遮挡，跳过', () {
      final zeroWidthHinge = _f(
        type: ui.DisplayFeatureType.hinge,
        bounds: const Rect.fromLTWH(395, 0, 0, 880),
      );
      expect(
        verticalPaneObstructions(
          features: [zeroWidthHinge],
          viewSize: view,
          leftInset: 0,
        ),
        isEmpty,
      );
    });

    test('横屏（水平特性）不进障碍列表 —— 这也是"横屏正常"的原因', () {
      final horizontal = _f(
        state: ui.DisplayFeatureState.postureHalfOpened,
        bounds: const Rect.fromLTWH(0, 430, 880, 20),
      );
      expect(
        verticalPaneObstructions(
          features: [horizontal],
          viewSize: view,
          leftInset: 0,
        ),
        isEmpty,
      );
    });

    test('不到视口一半高的竖特性不进障碍列表', () {
      final shortFold = _f(
        state: ui.DisplayFeatureState.postureHalfOpened,
        bounds: const Rect.fromLTWH(390, 0, 20, 300),
      );
      expect(
        verticalPaneObstructions(
          features: [shortFold],
          viewSize: view,
          leftInset: 0,
        ),
        isEmpty,
      );
    });

    test('无特性 → 空列表（普通手机 / 平板 / 桌面不受影响）', () {
      expect(
        verticalPaneObstructions(
          features: const <ui.DisplayFeature>[],
          viewSize: view,
          leftInset: 0,
        ),
        isEmpty,
      );
    });
  });
}
