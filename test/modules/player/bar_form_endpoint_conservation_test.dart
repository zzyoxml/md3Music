import 'dart:ui' show Rect, Size, lerpDouble;

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/bottom_chrome_dimens.dart';
import 'package:md3music/modules/player/bottom_bar_morph_overlay.dart';
import 'package:md3music/modules/player/player_bar_progress_painter.dart';

/// 底栏形态交叉过渡的**端点守恒**与**包边锚点**纯函数回归。
///
/// 两条独立缺陷（2026-10-12 会诊 W2/W3）：
/// - 端点守恒：常驻条端高度必须取**实测** `residentRect.height`（含底部净空），
///   不能硬编码 50 —— 否则有无净空（横屏侧栏 / 二级页 / 无底栏）时端点矮 ~20dp，
///   交棒瞬间条底错位。
/// - 包边锚点：中心线由**进度盒中线**连续移到**条盒中心**，中段包边才不会被
///   封面盖住（旧写法恒取进度盒中线，t=0.5 时 y≈21.8 落到偏上处）。
void main() {
  const Size screen = Size(400, 869);
  // 常驻条含净空的真实矩形：内容 50 + 净空 20 = 70 高（横屏侧栏 / 二级页形态）。
  const Rect resident = Rect.fromLTWH(0, 779, 400, 70);
  final Rect capsule = resolveCapsuleBodyRect(
    screenSize: screen,
    safeBottom: 24,
    navBarHeight: 0,
    navVisibleAtSettle: false,
  );

  group('resolveMorphBarLayout 端点守恒', () {
    test('p=0 逐值等于常驻条实测矩形（左/顶/宽/高）', () {
      final layout = resolveMorphBarLayout(
        p: 0,
        screenWidth: screen.width,
        residentRect: resident,
        capsuleRect: capsule,
      );
      expect(layout.barLeft, resident.left);
      expect(layout.barTop, resident.top);
      expect(layout.barWidth, resident.width);
      // 关键：高度取实测（含净空），不是硬编码 50。
      expect(layout.barHeight, resident.height);
      expect(layout.barHeight, isNot(kMorphResidentBarHeight));
      expect(layout.barRadius, 0);
    });

    test('p=1 逐值等于胶囊端点几何', () {
      final layout = resolveMorphBarLayout(
        p: 1,
        screenWidth: screen.width,
        residentRect: resident,
        capsuleRect: capsule,
      );
      expect(layout.barLeft, capsule.left);
      expect(layout.barTop, capsule.top);
      expect(layout.barWidth, capsule.width);
      expect(layout.barHeight, BottomChromeDimens.discDiameter);
      expect(layout.barRadius, BottomChromeDimens.discDiameter / 2);
    });

    test('高度中段平滑插值、端点无台阶', () {
      final mid = resolveMorphBarLayout(
        p: 0.5,
        screenWidth: screen.width,
        residentRect: resident,
        capsuleRect: capsule,
      );
      expect(
        mid.barHeight,
        lerpDouble(resident.height, BottomChromeDimens.discDiameter, 0.5),
      );
    });
  });

  group('resolveBarProgressGeometry 包边锚点', () {
    // 浮层的进度盒从「贴顶 2dp」长到「整条高」，条盒高由 layout 单独给出。
    const double barHeight = 64;
    const double cornerRadius = 32;

    test('formT=0：中心线取进度盒中线（贴顶直线，与原子实现一致）', () {
      final geo = resolveBarProgressGeometry(
        size: const Size(400, kPlayerBarProgressLineStroke),
        formT: 0,
        cornerRadius: 0,
        progress: 0.5,
        barHeight: barHeight,
      );
      expect(geo.isFlatLine, isTrue);
      expect(geo.centerY, kPlayerBarProgressLineStroke / 2);
      expect(geo.bandTop, 0.0, reason: '描边带上边缘贴顶');
    });

    test('formT=1：中心线取条盒中心（与胶囊真身同一中心）', () {
      final geo = resolveBarProgressGeometry(
        size: const Size(400, barHeight),
        formT: 1,
        cornerRadius: cornerRadius,
        progress: 0.5,
        barHeight: barHeight,
      );
      expect(geo.isFlatLine, isFalse);
      // 端点在盒内缩 inset（1.5）→ 路径中心仍是条盒中心。
      expect(geo.centerY, barHeight / 2);
    });

    test('中段：中心线由进度盒中线向条盒中心过渡（不被封面盖住）', () {
      const double progressBoxH = 29.5; // ≈ t=0.5 时 layout.progressHeight
      final geo = resolveBarProgressGeometry(
        size: const Size(400, progressBoxH),
        formT: 0.5,
        cornerRadius: cornerRadius,
        progress: 0.5,
        barHeight: barHeight,
      );
      // 中心线垂直中心 = midY = lerp(进度盒中线, 条盒中心, t)（推导：
      // `centerTop = lerp(midY, inset, t)`、`centerBottom = lerp(midY, h − inset, t)`
      // ⇒ `(centerTop + centerBottom) / 2 = midY`）。这里断言**几何结果**而非中间量：
      // 它必须明显高于旧实现的进度盒中线，即整圈包边已朝条盒中心下移、不再被封面盖住。
      final boxMid = progressBoxH / 2; // 14.75（旧实现恒取它）
      final pathMid = (geo.centerTop + geo.centerBottom) / 2;
      expect(pathMid, greaterThan(boxMid + 3.0),
          reason: '中心线仍停在进度盒中线附近（旧实现的覆盖缺陷）');
      // 落在进度盒中线与条盒中心之间（朝着条盒中心走，但尚未到）。
      expect(pathMid, inExclusiveRange(boxMid, barHeight / 2));
    });

    test('锚点下移全程单调、t=1 落到条盒正中心', () {
      double pathMid(double formT) {
        final double h = lerpDouble(kPlayerBarProgressLineStroke, barHeight, formT)!;
        final geo = resolveBarProgressGeometry(
          size: Size(400, h),
          formT: formT,
          cornerRadius: lerpDouble(0, cornerRadius, formT)!,
          progress: 0.5,
          barHeight: barHeight,
        );
        return (geo.centerTop + geo.centerBottom) / 2;
      }

      var prev = pathMid(0);
      for (final double t in <double>[0.1, 0.3, 0.5, 0.7, 0.9, 1.0]) {
        final m = pathMid(t);
        expect(m, greaterThanOrEqualTo(prev - 1e-9), reason: 't=$t 锚点回退');
        prev = m;
      }
      // t=1：中心线在条盒中心（与胶囊真身同一中心）。
      expect(prev, closeTo(barHeight / 2, 1e-9));
    });

    test('barHeight<=0（常驻条真身 formT=0 调用点）退化为进度盒中线', () {
      final geo = resolveBarProgressGeometry(
        size: const Size(400, kPlayerBarProgressLineStroke),
        formT: 0,
        cornerRadius: 0,
        progress: 0.5,
        barHeight: 0,
      );
      expect(geo.centerY, kPlayerBarProgressLineStroke / 2);
    });

    test('进度分段不因锚点变化而反转/清空（跨 formT 扫描）', () {
      for (final double formT in <double>[0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0]) {
        final double h = lerpDouble(
          kPlayerBarProgressLineStroke,
          barHeight,
          formT,
        )!;
        final geo = resolveBarProgressGeometry(
          size: Size(400, h),
          formT: formT,
          cornerRadius: lerpDouble(0, cornerRadius, formT)!,
          progress: 0.4,
          barHeight: barHeight,
        );
        expect(geo.activeEnd, greaterThan(geo.activeStart),
            reason: 'formT=$formT active 段被清空');
        expect(geo.hasTrack, isTrue, reason: 'formT=$formT track 消失');
      }
    });
  });
}
