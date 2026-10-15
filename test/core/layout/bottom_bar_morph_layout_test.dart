import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/bottom_chrome_dimens.dart';
import 'package:md3music/modules/player/bottom_bar_morph_overlay.dart';
import 'package:md3music/modules/player/player_bar_progress_painter.dart';

/// 交叉过渡几何 [resolveMorphBarLayout] 的端点保真与插值断言（W5）。
///
/// 硬要求：`p == 0` 逐值等于常驻条端点、`p == 1` 逐值等于胶囊端点 —— 否则两端
/// 真身与浮层交棒时会"跳一下"。
void main() {
  const double w = 400.0;
  const double h = 869.0;
  // 常驻条：全宽、顶端 700（底端 750 → 下方 50 是底栏）。
  const Rect resident = Rect.fromLTWH(0, 700, w, 50);
  // 胶囊：左右各 16、底端到屏底（高 = discReservedBottom = 76）。
  final Rect capsule = Rect.fromLTWH(
    kMorphCapsuleSideInset,
    h - BottomChromeDimens.discReservedBottom,
    w - kMorphCapsuleSideInset * 2,
    BottomChromeDimens.discReservedBottom,
  );

  MorphBarLayout at(double p) => resolveMorphBarLayout(
    p: p,
    screenWidth: w,
    residentRect: resident,
    capsuleRect: capsule,
  );

  group('p = 0 逐值等于常驻条端点', () {
    final g = at(0);
    test('条体几何', () {
      expect(g.t, 0.0);
      expect(g.barLeft, 0.0);
      expect(g.barTop, resident.top);
      expect(g.barWidth, w);
      expect(g.barHeight, kMorphResidentBarHeight);
      expect(g.barRadius, 0.0);
    });
    test('封面几何', () {
      expect(g.coverLeft, kMorphResidentSideInset);
      expect(g.coverTop, kMorphResidentCoverTop);
      expect(g.coverTop, 4.0);
      expect(g.coverSize, kMorphResidentCoverSize);
      expect(g.coverSize, 44.0);
      expect(g.coverRadius, kMorphResidentCoverRadius);
      expect(g.coverRadius, 6.0);
    });
    test('内容行与进度几何', () {
      expect(g.rowLeft, kMorphResidentTextLeft);
      expect(g.rowRight, w - kMorphResidentRowRight);
      expect(g.progressHeight, kPlayerBarProgressLineStroke);
      expect(g.lyricOpacity, 1.0);
      expect(g.lyricWidthFactor, 1.0);
    });
  });

  group('p = 1 逐值等于胶囊端点', () {
    final g = at(1);
    test('条体几何', () {
      expect(g.t, 1.0);
      expect(g.barLeft, kMorphCapsuleSideInset);
      expect(g.barTop, capsule.top);
      expect(g.barWidth, w - kMorphCapsuleSideInset * 2);
      expect(g.barHeight, BottomChromeDimens.discDiameter);
      expect(g.barRadius, BottomChromeDimens.discDiameter / 2);
    });
    test('封面几何（正圆，锚在胶囊可见封面 58@(3,3)）', () {
      // 会诊 D2：旧实现 coverLeft 用了胶囊宿主左缘（0）、coverTop 恒 4、size 56，
      // 末帧与真身差 3px 横移 + 1px 纵移 + 2dp 大小 —— 交棒瞬间封面"跳一下"。
      expect(g.coverLeft, kMorphCapsuleCoverInset);
      expect(g.coverLeft, 3.0);
      expect(g.coverTop, kMorphCapsuleCoverInset);
      expect(g.coverTop, 3.0);
      expect(g.coverSize, kMorphCapsuleCoverSize);
      expect(g.coverSize, 58.0);
      expect(g.coverRadius, kMorphCapsuleCoverRadius);
      expect(g.coverRadius, g.coverSize / 2);
      expect(g.coverRadius, 29.0);
      // 位置 + 尺寸与胶囊真身可见封面完全重合（容器 64 内居中）。
      expect(g.coverLeft, (BottomChromeDimens.discDiameter - g.coverSize) / 2);
      expect(g.coverTop, (BottomChromeDimens.discDiameter - g.coverSize) / 2);
    });
    test('内容行与进度几何（内缘包边占满整条高）', () {
      expect(g.rowLeft, kMorphCapsuleTextLeft);
      expect(g.rowRight, (w - kMorphCapsuleSideInset * 2) - kMorphCapsuleRowRight);
      expect(g.progressHeight, BottomChromeDimens.discDiameter);
      expect(g.lyricOpacity, 0.0);
      expect(g.lyricWidthFactor, 0.0);
    });
  });

  test('越界进度钳到端点', () {
    expect(at(-1).t, 0.0);
    expect(at(2).t, 1.0);
  });

  test('中点线性插值', () {
    final g = at(0.5);
    expect(g.barHeight, closeTo((kMorphResidentBarHeight + BottomChromeDimens.discDiameter) / 2, 1e-9));
    expect(g.barRadius, closeTo(BottomChromeDimens.discDiameter / 4, 1e-9));
    expect(g.coverSize, closeTo((kMorphResidentCoverSize + kMorphCapsuleCoverSize) / 2, 1e-9));
    expect(g.coverLeft, closeTo(3.5, 1e-9));
    expect(g.coverTop, closeTo(3.5, 1e-9));
    expect(g.lyricOpacity, 0.5);
  });

  group('进度 stop 点在形变两端的连续性', () {
    test('弹板直线端（常驻条）恒为 1，端点逐值不变', () {
      expect(resolveStopIndicatorMorphOpacity(0.0), 1.0);
      // p→0 的最后一帧（控制器到端点前的残余进度量级）≈ 1，与常驻条端点等价。
      expect(
        resolveStopIndicatorMorphOpacity(0.002),
        closeTo(1.0 - 0.002 / kPlayerBarProgressStopMorphFade, 1e-9),
      );
      expect(resolveStopIndicatorMorphOpacity(0.002), greaterThan(0.95));
    });
    test('中段与包边端无 stop 点', () {
      expect(resolveStopIndicatorMorphOpacity(kPlayerBarProgressStopMorphFade), 0.0);
      expect(resolveStopIndicatorMorphOpacity(0.5), 0.0);
      expect(resolveStopIndicatorMorphOpacity(1.0), 0.0);
      expect(resolveStopIndicatorMorphOpacity(0.06), closeTo(0.5, 1e-9));
    });
    test('几何：形变端点处 stop 点应参与绘制（旧实现 isFlatLine 门把它整段砍掉）', () {
      final flat = resolveBarProgressGeometry(
        size: const Size(368.0, kPlayerBarProgressLineStroke),
        formT: 0.0,
        cornerRadius: 0.0,
      );
      expect(flat.isFlatLine, isTrue);
      // 浮层在 p≈0 的盒子高 ≈ 2（lerp(2, 64, p)），中心线与直线端一致。
      final nearlyFlat = resolveBarProgressGeometry(
        size: const Size(368.0, 2.062),
        formT: 0.001,
        cornerRadius: 0.0,
      );
      expect(nearlyFlat.isFlatLine, isFalse,
          reason: '形变帧必然过 !isFlatLine 分支：stop 点必须按透明度补回，否则端点跳变');
      final stop = resolveStopIndicator(
        size: const Size(368.0, 2.062),
        progress: 0.2,
        strokeWidth: nearlyFlat.strokeWidth,
        stopSize: kPlayerBarProgressLineStopSize,
      );
      expect(stop.dotSize, closeTo(2.0, 0.01));
      expect(stop.centerX, closeTo(367.0, 0.01));
    });
  });
}
