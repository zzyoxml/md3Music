import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/bottom_chrome_dimens.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
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

  group('收缩圆盘端点（collapse 参数）', () {
    // 圆盘端矩形：右停靠、64×64、底部净空与展开胶囊同口径。
    final Rect disc = resolveCapsuleBodyRect(
      screenSize: const Size(w, h),
      safeBottom: 0,
      collapse: 1.0,
      dockSide: SecondaryPlayerDockSide.right,
    );
  MorphBarLayout discAt(double p, {double collapse = 1.0, double angle = 0.0}) =>
      resolveMorphBarLayout(
        p: p,
        residentRect: resident,
        capsuleRect: disc,
        capsuleCollapse: collapse,
        capsuleDiscAngle: angle,
      );

    test('resolveCapsuleBodyRect：各停靠位的圆盘几何', () {
      expect(disc.width, BottomChromeDimens.discDiameter);
      expect(disc.height, BottomChromeDimens.discDiameter);
      expect(disc.right, w - kMorphCapsuleSideInset);
      final left = resolveCapsuleBodyRect(
        screenSize: const Size(w, h),
        safeBottom: 0,
        collapse: 1.0,
        dockSide: SecondaryPlayerDockSide.left,
      );
      expect(left.left, kMorphCapsuleSideInset);
      final center = resolveCapsuleBodyRect(
        screenSize: const Size(w, h),
        safeBottom: 0,
        collapse: 1.0,
        dockSide: SecondaryPlayerDockSide.center,
      );
      expect(center.left, closeTo((w - BottomChromeDimens.discDiameter) / 2, 1e-9));
      // collapse=0 时任何停靠位都与旧展开口径逐字节相等（回归保护；高 64 =
      // discDiameter，底部净空 12 已含在 top 里 —— 与上方 fixture 的高 76 口径
      // 不同，fixture 是「含净空的宿主量法」，此处按本体口径断言）。
      for (final side in SecondaryPlayerDockSide.values) {
        final expanded = resolveCapsuleBodyRect(
          screenSize: const Size(w, h),
          safeBottom: 0,
          dockSide: side,
        );
        expect(expanded, Rect.fromLTWH(kMorphCapsuleSideInset,
            h - 12.0 - BottomChromeDimens.discDiameter,
            w - kMorphCapsuleSideInset * 2, BottomChromeDimens.discDiameter));
      }
    });

    test('p=1 逐值等于圆盘端点（封面 56@inset4、行隐、角度对齐）', () {
      final g = discAt(1, angle: 1.25);
      expect(g.barWidth, BottomChromeDimens.discDiameter);
      expect(g.barRadius, BottomChromeDimens.discDiameter / 2);
      expect(g.coverSize, kMorphDiscCoverSize);
      expect(g.coverSize, 56.0);
      expect(g.coverLeft, kMorphDiscCoverInset);
      expect(g.coverLeft, 4.0);
      expect(g.coverTop, kMorphDiscCoverInset);
      expect(g.coverRadius, closeTo(28.0, 1e-9));
      expect(g.rowOpacity, 0.0);
      expect(g.coverRotation, 1.25);
      // p=0（常驻端）行可见、角度归零。
      final r = discAt(0, angle: 1.25);
      expect(r.rowOpacity, 1.0);
      expect(r.coverRotation, 0.0);
    });

    test('collapse=0 端点与既有胶囊端点逐字节相等（回归保护）', () {
      final g = resolveMorphBarLayout(
        p: 1,
        residentRect: resident,
        capsuleRect: capsule,
        capsuleCollapse: 0.0,
        capsuleDiscAngle: 0.7,
      );
      expect(g.coverSize, kMorphCapsuleCoverSize);
      expect(g.coverLeft, kMorphCapsuleCoverInset);
      expect(g.rowOpacity, 1.0);
      // 角度端点 = 调用方传值 × t：展开态调用方恒传 0，故既有展开交棒不旋转。
      expect(g.coverRotation, 0.7);
    });

    test('中间值（collapse=0.4）端点解析式断言', () {
      final rect04 = resolveCapsuleBodyRect(
        screenSize: const Size(w, h),
        safeBottom: 0,
        collapse: 0.4,
        dockSide: SecondaryPlayerDockSide.right,
      );
      final expectWidth = 368.0 + (64.0 - 368.0) * 0.4;
      expect(rect04.width, closeTo(expectWidth, 1e-9));
      expect(rect04.right, w - kMorphCapsuleSideInset);
      final g = discAt(1, collapse: 0.4);
      expect(g.coverSize, closeTo(58.0 + (56.0 - 58.0) * 0.4, 1e-9));
      expect(g.rowOpacity, closeTo(0.6, 1e-9));
    });
  });

  group('横屏 rail 布局端点（宽 800、rail 保留宽、无底栏净空）', () {
    const double lw = 800.0;
    const double lh = 400.0;
    // rail 保留宽 = 默认槽位 96 + 分隔线 1（与 responsive_layout 同源常量；
    // navigationRailReservedWidth 是实测回填的全局可变量，测试用常量档）。
    const double railReserve =
        kNavigationRailDefaultWidth + kNavigationRailDividerWidth;
    // 常驻条端点：body 区从 rail 右缘起、贴屏底（横屏没有底部导航栏）。
    final Rect railResident = Rect.fromLTWH(
      railReserve,
      lh - kMorphResidentBarHeight,
      lw - railReserve,
      kMorphResidentBarHeight,
    );
    // 胶囊端点：结算态无底栏（navVisibleAtSettle=false）、内容区让出 rail。
    final Rect railCapsule = resolveCapsuleBodyRect(
      screenSize: const Size(lw, lh),
      safeBottom: 0,
      navVisibleAtSettle: false,
      leadingReserve: railReserve,
    );

    MorphBarLayout railAt(double p) => resolveMorphBarLayout(
      p: p,
      residentRect: railResident,
      capsuleRect: railCapsule,
    );

    test('resolveCapsuleBodyRect：横屏 rail 口径（左缘右移、无底栏净空）', () {
      // center 停靠取**内容区**中心（不是屏幕中心）：左缘 = rail 保留宽 + 16。
      expect(railCapsule.left, railReserve + kMorphCapsuleSideInset);
      expect(
        railCapsule.width,
        lw - railReserve - kMorphCapsuleSideInset * 2,
      );
      expect(railCapsule.right, lw - kMorphCapsuleSideInset);
      // 结算态无底栏 → 底端只留 12dp 贴底距，不再抬高一个底栏槽位。
      expect(railCapsule.bottom, lh - 12.0);
    });

    test('p = 0 逐值等于常驻条端点（横屏 body 口径）', () {
      final g = railAt(0);
      expect(g.t, 0.0);
      expect(g.barLeft, railResident.left);
      expect(g.barLeft, railReserve);
      expect(g.barTop, railResident.top);
      expect(g.barWidth, railResident.width);
      expect(g.barWidth, lw - railReserve);
      expect(g.barHeight, kMorphResidentBarHeight);
      expect(g.barRadius, 0.0);
      // 内容行恒相对条体盒：左起笔不随条盒左缘漂移（旧式 − barLeft 会推出盒外）。
      expect(g.rowLeft, kMorphResidentTextLeft);
      expect(g.rowRight, railResident.width - kMorphResidentRowRight);
    });

    test('p = 1 逐值等于胶囊端点（横屏 rail 布局）', () {
      final g = railAt(1);
      expect(g.t, 1.0);
      expect(g.barLeft, railReserve + kMorphCapsuleSideInset);
      expect(g.barTop, lh - 12.0 - BottomChromeDimens.discDiameter);
      expect(g.barWidth, lw - railReserve - kMorphCapsuleSideInset * 2);
      expect(g.barHeight, BottomChromeDimens.discDiameter);
      expect(g.barRadius, BottomChromeDimens.discDiameter / 2);
      expect(g.coverLeft, kMorphCapsuleCoverInset);
      expect(g.coverSize, kMorphCapsuleCoverSize);
      expect(g.rowLeft, kMorphCapsuleTextLeft);
      expect(
        g.rowRight,
        (lw - railReserve - kMorphCapsuleSideInset * 2) -
            kMorphCapsuleRowRight,
      );
    });

    test('结算态底栏在场（竖屏口径）时胶囊抬升一个底栏槽位', () {
      const double navBar = 64.0;
      final withNav = resolveCapsuleBodyRect(
        screenSize: const Size(lw, lh),
        safeBottom: 0,
        navBarHeight: navBar,
        navVisibleAtSettle: true,
        leadingReserve: railReserve,
      );
      expect(withNav.bottom, lh - 12.0 - navBar);
    });

    test('收缩圆盘在横屏 rail 口径的轨道内停靠', () {
      final disc = resolveCapsuleBodyRect(
        screenSize: const Size(lw, lh),
        safeBottom: 0,
        collapse: 1.0,
        dockSide: SecondaryPlayerDockSide.right,
        leadingReserve: railReserve,
      );
      expect(disc.width, BottomChromeDimens.discDiameter);
      // 右停靠贴内容区右缘：rail 保留宽 + 右内缩 16 + 盘径 64。
      expect(disc.right, lw - kMorphCapsuleSideInset);
      final left = resolveCapsuleBodyRect(
        screenSize: const Size(lw, lh),
        safeBottom: 0,
        collapse: 1.0,
        dockSide: SecondaryPlayerDockSide.left,
        leadingReserve: railReserve,
      );
      expect(left.left, railReserve + kMorphCapsuleSideInset);
    });

    test('Pad 限宽轨道（maxTrackWidth）与真身 trackW 同式', () {
      const double cap = BottomChromeDimens.discTrackMaxWidth;
      final capped = resolveCapsuleBodyRect(
        screenSize: const Size(lw, lh),
        safeBottom: 0,
        leadingReserve: railReserve,
        maxTrackWidth: cap,
      );
      // 内容区 800−97=703、减两侧 16 → 671 > 400，轨道限到 400 并居中停靠：
      // 左缘 = rail 保留宽 + (内容区宽 − 轨道宽)/2。
      expect(capped.width, cap);
      expect(capped.left, railReserve + (lw - railReserve - cap) / 2);
      // 轨道未超限时与不限宽逐字节相等（回归保护）。
      final uncapped = resolveCapsuleBodyRect(
        screenSize: const Size(w, h),
        safeBottom: 0,
        maxTrackWidth: cap,
      );
      final plain = resolveCapsuleBodyRect(
        screenSize: const Size(w, h),
        safeBottom: 0,
      );
      expect(uncapped, plain);
    });
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
