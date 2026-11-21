import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/bottom_bar_morph_overlay.dart';
import 'package:md3music/modules/player/player_bar_progress_painter.dart';

/// W2：播放栏进度条「同一 painter 变形」的几何断言。
///
/// 这里只断言**几何推导的端点**（[resolveBarProgressGeometry] 与
/// [resolveStopIndicator] 的纯函数输出），不靠截图或 recording canvas —— 正是为此
/// 把几何从 painter 里抽成了纯函数。
void main() {
  const Color track = Color(0xFF102030);
  const Color active = Color(0xFFA0B0C0);

  PlayerBarProgressPainter painterWith({
    double progress = 0.5,
    double formT = 0.0,
    Color trackColor = track,
    Color activeColor = active,
    double cornerRadius = 0.0,
    double gapSize = 0.0,
    StrokeCap strokeCap = StrokeCap.round,
    double stopIndicatorSize = 0.0,
  }) =>
      PlayerBarProgressPainter(
        progress: progress,
        formT: formT,
        trackColor: trackColor,
        activeColor: activeColor,
        cornerRadius: cornerRadius,
        gapSize: gapSize,
        strokeCap: strokeCap,
        stopIndicatorSize: stopIndicatorSize,
      );

  group('formT == 0：贴顶、满宽、2dp 的顶置直线', () {
    // 常驻条进度盒恒为「满宽 × 直线描边宽（2dp）」，与旧
    // M3ELinearProgressIndicator(minHeight: 2) 同尺寸。
    const Size size = Size(200, kPlayerBarProgressLineStroke);
    final geo = resolveBarProgressGeometry(
      size: size,
      formT: 0.0,
      cornerRadius: 0.0,
    );

    test('描边 2、内缩 0、无圆角', () {
      expect(geo.strokeWidth, kPlayerBarProgressLineStroke);
      expect(geo.strokeWidth, 2.0);
      expect(geo.inset, 0.0);
      expect(geo.radius, 0.0);
    });

    test('退化成一条水平直线（上下直边重合）', () {
      expect(geo.isFlatLine, isTrue);
      // 中心线取盒中线（= M3ELinearProgressIndicator 的 yOffset = height/2）。
      expect(geo.centerY, closeTo(size.height / 2, 1e-9));
      expect(geo.centerTop, closeTo(geo.centerBottom, 1e-9));
    });

    test('贴顶：描边带上边缘落在 y = 0', () {
      expect(geo.bandTop, closeTo(0.0, 1e-9));
    });

    test('满宽：路径横跨整个盒子宽度，且无竖直厚度', () {
      expect(geo.centerLeft, 0.0);
      expect(geo.centerRight, size.width);
      final bounds = geo.toPath().getBounds();
      expect(bounds.left, closeTo(0.0, 1e-9));
      expect(bounds.right, closeTo(size.width, 1e-9));
      expect(bounds.height, closeTo(0.0, 1e-9));
      // 周长 == 宽度（两点线段）。
      expect(geo.toPath().computeMetrics().first.length, closeTo(200.0, 1e-6));
    });
  });

  group('formT == 0：M3E 直线进度的逐项复刻（间隙 / 端帽 / stop 点）', () {
    // 旧常驻条 = `M3ELinearProgressIndicator(value:, minHeight: 2,
    // backgroundColor: surfaceContainerHighest, color: primary)`，m3e_core 1.1.4 的
    // 默认 `strokeCap = StrokeCap.round`、`gapSize = 4`、`stopSize = 4`。
    const Size size = Size(200, kPlayerBarProgressLineStroke);
    const double gapSize = kPlayerBarProgressLineGap;
    final geo = resolveBarProgressGeometry(
      size: size,
      formT: 0.0,
      cornerRadius: 0.0,
      progress: 0.5,
      gapSize: gapSize,
    );

    test('端帽形状沿用 M3E 的 round；端帽外扩 / 夹取量 = 描边宽 / 2', () {
      expect(geo.strokeCap, StrokeCap.round);
      expect(geo.capOffset, closeTo(1.0, 1e-9));
      // 采样盒子仍是「描边 2、inset 0」的贴顶满宽直线 —— 夹取只挪画出来的线段。
      expect(geo.isFlatLine, isTrue);
      expect(geo.strokeWidth, 2.0);
      expect(geo.inset, 0.0);
      expect(geo.centerLeft, 0.0);
      expect(geo.centerRight, size.width);
    });

    test('各端点等于 M3E 夹取后的具体数值', () {
      // active：barStart / barEnd 都 clamp 到 [strokeCapOffset, width - strokeCapOffset]
      // （m3e_linear_progress_indicator.dart:244-252）。
      expect(geo.activeStart, closeTo(1.0, 1e-9)); // clamp(0, 1, 199)
      expect(geo.activeEnd, closeTo(100.0, 1e-9)); // clamp(0.5 × 200, 1, 199)
      // track：trackStart = progress + min(progress, adjustedGap / width)，其中
      // adjustedGap = gapSize + strokeHeight（:270-291）→ 100 + min(100, 4 + 2)。
      expect(geo.trackStart, closeTo(106.0, 1e-9));
      expect(geo.trackEnd, closeTo(199.0, 1e-9)); // clamp(200, 1, 199)
      expect(geo.hasTrack, isTrue);
    });

    test('保真判据：active 描边末端比 track 描边起端短 gapSize', () {
      // 均按圆端帽外扩后（active 末端 +1、track 起端 -1），差值必须恰为 gapSize；
      // 即 active 相对 track 缩短 4dp（plan §4.3）。
      expect(geo.trackPaintedStart - geo.activePaintedEnd, closeTo(4.0, 1e-9));
      expect(
        geo.trackPaintedStart - geo.activePaintedEnd,
        closeTo(gapSize, 1e-9),
      );
      // 反过来也成立：track 的中心线起点 = active 中心线末端 + gap + 两侧端帽。
      expect(
        geo.trackStart - geo.activeEnd,
        closeTo(gapSize + 2 * geo.capOffset, 1e-9),
      );
      // 圆端帽补回 capOffset → 描边左端起于盒左缘、右端止于盒右缘（M3E 夹取的目的）。
      expect(geo.activeStart - geo.capOffset, closeTo(0.0, 1e-9));
      expect(geo.trackEnd + geo.capOffset, closeTo(size.width, 1e-9));
    });

    test('progress 缺省（0）时分段仍是零进度解：track 铺满、active 只剩起点端帽', () {
      final zero = resolveBarProgressGeometry(
        size: size,
        formT: 0.0,
        cornerRadius: 0.0,
        gapSize: gapSize,
      );
      expect(zero.activeEnd, closeTo(zero.activeStart, 1e-9));
      // trackStart = 0 + min(0, 6) = 0 → 夹取后仍是 1；M3E 在零进度下轨道从 0 起。
      expect(zero.trackStart, closeTo(1.0, 1e-9));
      expect(zero.trackEnd, closeTo(199.0, 1e-9));
    });

    test('间隙随进度生长：active 太短时 track 从 active 末端的两倍处起（M3E 的 min()）', () {
      final tiny = resolveBarProgressGeometry(
        size: size,
        formT: 0.0,
        cornerRadius: 0.0,
        progress: 0.01,
        gapSize: gapSize,
      );
      // activeHead = 2 → trackHead = 2 + min(2, 4 + 2) = 4（:280-281）。
      expect(tiny.activeEnd, closeTo(2.0, 1e-9));
      expect(tiny.trackStart, closeTo(4.0, 1e-9));
    });

    test('进度逼近满格时 track 被让空（M3E 的 trackStartFraction > 1 跳过）', () {
      final near = resolveBarProgressGeometry(
        size: size,
        formT: 0.0,
        cornerRadius: 0.0,
        progress: 0.99,
        gapSize: gapSize,
      );
      // trackHead = 198 + min(198, 6) = 204 > 200 → 夹到末端，抽不出长度。
      expect(near.hasTrack, isFalse);
      expect(near.trackStart, closeTo(near.trackEnd, 1e-9));
    });

    test('stop 点：直径被描边宽钳到 2（与轨道圆端帽同心同径）', () {
      final stop = resolveStopIndicator(
        size: size,
        progress: 0.5,
        strokeWidth: geo.strokeWidth,
        stopSize: kPlayerBarProgressLineStopSize,
      );
      // utils:43-52 → dotSize = min(4, 2) = 2、dotOffset = 0、x = 200 - 2 = 198。
      expect(stop.dotSize, closeTo(2.0, 1e-9));
      expect(stop.centerX, closeTo(199.0, 1e-9));
      // 与轨道末端（含端帽）重合 → 只把轨道最右 2dp 重绘成进度色。
      expect(stop.centerX, closeTo(geo.trackEnd, 1e-9));
      expect(stop.dotSize / 2, closeTo(geo.capOffset, 1e-9));
    });

    test('stop 点在进度逼近末端时收缩并入 active（utils:55-58）', () {
      final near = resolveStopIndicator(
        size: size,
        progress: 0.995,
        strokeWidth: geo.strokeWidth,
        stopSize: kPlayerBarProgressLineStopSize,
      );
      // progressX = 199 + 1 = 200 ≥ x(198) → 直径收缩为 max(0, 2 - 2) = 0、圆心 200。
      expect(near.dotSize, 0.0);
      expect(near.centerX, closeTo(200.0, 1e-9));
    });

    test('stop 点为 0 时不解算（不画）', () {
      final none = resolveStopIndicator(
        size: size,
        progress: 0.5,
        strokeWidth: geo.strokeWidth,
        stopSize: 0.0,
      );
      expect(none.dotSize, 0.0);
    });
  });

  group('formT == 1：内缘包边的 stadium', () {
    const Size size = Size(300, 64); // 胶囊高 = BottomChromeDimens.discDiameter
    const double cornerRadius = 32.0; // = discDiameter / 2
    final geo = resolveBarProgressGeometry(
      size: size,
      formT: 1.0,
      cornerRadius: cornerRadius,
    );

    test('描边 3、内缩 1.5', () {
      expect(geo.strokeWidth, kPlayerBarProgressRimStroke);
      expect(geo.strokeWidth, 3.0);
      expect(geo.inset, kPlayerBarProgressRimInset);
      expect(geo.inset, 1.5);
    });

    test('上下/左右直边按 inset 内缩', () {
      expect(geo.centerTop, closeTo(1.5, 1e-9));
      expect(geo.centerBottom, closeTo(62.5, 1e-9));
      expect(geo.centerLeft, closeTo(1.5, 1e-9));
      expect(geo.centerRight, closeTo(298.5, 1e-9));
      expect(geo.isFlatLine, isFalse);
    });

    test('中心线半径 = cornerRadius - inset（标准胶囊下二者一致）', () {
      expect(geo.radius, closeTo(cornerRadius - geo.inset, 1e-9));
      expect(geo.radius, closeTo(30.5, 1e-9));
    });

    test('路径封闭为 stadium，包围盒贴合中心线，周长符合直线 + 两个半圆', () {
      final path = geo.toPath();
      final bounds = path.getBounds();
      expect(bounds.left, closeTo(geo.centerLeft, 1e-9));
      expect(bounds.top, closeTo(geo.centerTop, 1e-9));
      expect(bounds.right, closeTo(geo.centerRight, 1e-9));
      expect(bounds.bottom, closeTo(geo.centerBottom, 1e-9));

      final double straight = (geo.centerRight - geo.radius) -
          (geo.centerLeft + geo.radius);
      final double expected = 2 * straight + 2 * math.pi * geo.radius;
      // Skia 用 conic 逼近圆弧，弧长与理想圆周长有极小偏差（此处 0.05% 内）。
      expect(path.computeMetrics().first.length, closeTo(expected, 0.5));
    });

    test('间隙与端帽夹取都归零 → 与旧包边一致（active 前缀 + track 后段）', () {
      // 调用方即使照常传了直线态的端点值，胶囊侧也必须逐项归零，否则包边会出现
      // 一段缺口 / 闭合口错位（plan §4.3：formT=1 与 _SecondaryProgressPainter 一致）。
      final rim = resolveBarProgressGeometry(
        size: size,
        formT: 1.0,
        cornerRadius: cornerRadius,
        progress: 0.5,
        gapSize: kPlayerBarProgressLineGap,
        strokeCap: StrokeCap.round,
      );
      expect(rim.gapSize, 0.0);
      expect(rim.capOffset, 0.0);
      expect(rim.activeStart, 0.0);
      expect(rim.hasTrack, isTrue);

      final double length = rim.toPath().computeMetrics().first.length;
      // active = 前缀 p。
      expect(rim.activeEnd, closeTo(length * 0.5, 1e-9));
      // track 从 active 末端起、直到闭合点（= 旧实现的「整圈 + active 前缀」：
      // 两者像素等价 —— 后画的 active 会盖住自己那一段，间隙为 0 时接缝重合）。
      expect(rim.trackStart, closeTo(rim.activeEnd, 1e-9));
      expect(rim.trackEnd, closeTo(length, 1e-9));
    });
  });

  group('formT 单调插值', () {
    test('描边 2→3、半径 / 张开量随 formT 单调递增', () {
      const Size size = Size(300, 64);
      const List<double> samples = <double>[0.0, 0.25, 0.5, 0.75, 1.0];
      final List<BarProgressGeometry> geos = <BarProgressGeometry>[
        for (final double t in samples)
          resolveBarProgressGeometry(
            size: size,
            formT: t,
            // 与消费方同源：cornerRadius = lerp(0, discDiameter / 2)
            cornerRadius: 32.0 * t,
            progress: 0.5,
            gapSize: kPlayerBarProgressLineGap,
          ),
      ];
      // 端值精确等于线性插值。
      for (int i = 0; i < samples.length; i++) {
        final double t = samples[i];
        expect(geos[i].strokeWidth, closeTo(2.0 + (3.0 - 2.0) * t, 1e-9));
        expect(geos[i].inset, closeTo(1.5 * t, 1e-9));
        // 直线态专属量按 (1 - formT) 归零；端帽夹取量是「当前描边宽的一半」× 权重。
        expect(geos[i].gapSize, closeTo(4.0 * (1.0 - t), 1e-9));
        expect(
          geos[i].capOffset,
          closeTo(geos[i].strokeWidth / 2 * (1.0 - t), 1e-9),
        );
      }
      // 单调不减。
      for (int i = 1; i < geos.length; i++) {
        final BarProgressGeometry prev = geos[i - 1];
        final BarProgressGeometry cur = geos[i];
        expect(cur.strokeWidth, greaterThanOrEqualTo(prev.strokeWidth));
        expect(cur.radius, greaterThanOrEqualTo(prev.radius));
        expect(
          cur.centerBottom - cur.centerTop,
          greaterThanOrEqualTo(prev.centerBottom - prev.centerTop),
        );
      }
      // 直线态专属量单调不增。
      for (int i = 1; i < geos.length; i++) {
        expect(geos[i].gapSize, lessThanOrEqualTo(geos[i - 1].gapSize));
        expect(geos[i].capOffset, lessThanOrEqualTo(geos[i - 1].capOffset));
      }
    });

    test('formT 越界被钳制到 [0, 1]', () {
      const Size size = Size(300, 64);
      final low = resolveBarProgressGeometry(
        size: size,
        formT: -1.0,
        cornerRadius: 32.0,
      );
      final high = resolveBarProgressGeometry(
        size: size,
        formT: 2.0,
        cornerRadius: 32.0,
      );
      expect(low.strokeWidth, 2.0);
      expect(low.isFlatLine, isTrue);
      expect(high.strokeWidth, 3.0);
      expect(high.radius, closeTo(30.5, 1e-9));
    });
  });

  group('shouldRepaint 只比入参标量/颜色', () {
    test('全部入参相等 → false', () {
      expect(painterWith().shouldRepaint(painterWith()), isFalse);
    });

    test('任一入参变化 → true', () {
      final base = painterWith();
      expect(painterWith(progress: 0.9).shouldRepaint(base), isTrue);
      expect(painterWith(formT: 1.0).shouldRepaint(base), isTrue);
      expect(
        painterWith(trackColor: const Color(0xFF010203)).shouldRepaint(base),
        isTrue,
      );
      expect(
        painterWith(activeColor: const Color(0xFF040506)).shouldRepaint(base),
        isTrue,
      );
      expect(painterWith(cornerRadius: 32.0).shouldRepaint(base), isTrue);
      expect(
        painterWith(gapSize: kPlayerBarProgressLineGap).shouldRepaint(base),
        isTrue,
      );
      expect(
        painterWith(strokeCap: StrokeCap.butt).shouldRepaint(base),
        isTrue,
      );
      expect(
        painterWith(stopIndicatorSize: kPlayerBarProgressLineStopSize)
            .shouldRepaint(base),
        isTrue,
      );
    });
  });

  // ───────── 已播放段长度：两端真身口径 + formT 连续（交棒硬切回归） ─────────
  //
  // 用户报障：「进度条的已播放条有硬切 —— 切到常驻栏的最后一刻、以及切到悬浮栏的
  // 最开始，进度对不上」。本题只谈**已播放段的长度**（外观/端点几何前几轮已对齐），
  // 根因是**进度分母**两端口径不同：
  // - 常驻条（`mini_player.dart:908-924`，formT=0）= M3E determinate：
  //   `active = clamp(progress × size.width, capOffset, width − capOffset)`
  //   → 已播放长度 = `clamp(p·W, 1, W−1) − 1`（圆端帽每侧夹取 1dp）；
  // - 胶囊（`secondary_mini_player.dart:1664-1669`，formT=1）= `metric.length × p` 前缀
  //   → 已播放长度 = `p · L`（L = 闭合 stadium 中心线周长 ≈ 2W + 2πr − 4r ≈ 2W）。
  // 两端各自与自己的真身一致，但**同一条 painter 在 formT 刚离开 0 时**若直接拿
  // 「当前路径长度」当分母，分母会从 W 跳到 ≈2W（开放线段 → 闭合环），已播放段在
  // 交棒帧瞬时翻倍 —— 这就是硬切。
  group('已播放段长度：两端真身口径 + formT 连续', () {
    const double screenW = 400.0; // 手机竖屏（harness 同值）
    const double capsuleW = 368.0; // = 400 − kMorphCapsuleSideInset(16) × 2
    const double capsuleH = 64.0; // = BottomChromeDimens.discDiameter
    const double lineH = kPlayerBarProgressLineStroke; // 2

    /// 浮层在 formT 处的进度盒（与 `resolveMorphBarLayout` 同源，见
    /// `bottom_bar_morph_overlay.dart:295/341`）：宽 `lerp(400, 368, t)`、
    /// 高 `lerp(2, lerp(kMorphResidentBarHeight, discDiameter, t), t)`、圆角 `32t`。
    ({double w, double h, double r}) overlayBox(double t) => (
      w: screenW + (capsuleW - screenW) * t,
      h: lerpDouble(
        lineH,
        lerpDouble(kMorphResidentBarHeight, capsuleH, t)!,
        t,
      )!,
      r: (capsuleH / 2) * t,
    );

    /// 「已播放段」沿中心线的弧长（px）= `activeEnd − activeStart`。
    double played(
      double formT, {
      double progress = 0.5,
      double width = screenW,
      double height = lineH,
      double cornerRadius = 0.0,
    }) {
      final geo = resolveBarProgressGeometry(
        size: Size(width, height),
        formT: formT,
        cornerRadius: cornerRadius,
        progress: progress,
        gapSize: kPlayerBarProgressLineGap,
      );
      return geo.activeEnd - geo.activeStart;
    }

    /// 浮层在 formT 处的已播放段弧长（盒尺寸随形变，与消费方同源）。
    double overlayPlayed(double t, {double progress = 0.5}) {
      final box = overlayBox(t);
      return played(
        t,
        progress: progress,
        width: box.w,
        height: box.h,
        cornerRadius: box.r,
      );
    }

    /// **修复前**的读数（进度分母 = 当前路径长度），只作硬切对照：
    /// 复刻旧实现 `activeEnd = clamp(p · pathLength, capOffset, …)`。
    double brokenPlayed(double t, {double progress = 0.5}) {
      final box = overlayBox(t);
      final geo = resolveBarProgressGeometry(
        size: Size(box.w, box.h),
        formT: t,
        cornerRadius: box.r,
        progress: progress,
        gapSize: kPlayerBarProgressLineGap,
      );
      final double len = geo.toPath().computeMetrics().first.length;
      final double lo = geo.activeStart;
      final double hi = math.max(len - geo.capOffset, lo);
      return math.min(math.max(progress * len, lo), hi) - lo;
    }

    test('formT == 0：已播放长度 = clamp(p·W, 1, W−1) − 1（M3E 手工表达式）', () {
      const double cap = kPlayerBarProgressLineStroke / 2; // 圆端帽夹取 = 1dp
      double m3e(double p) => (p * screenW).clamp(cap, screenW - cap) - cap;

      for (final double p in const <double>[0.0, 0.01, 0.2, 0.5, 0.99, 1.0]) {
        expect(played(0.0, progress: p), closeTo(m3e(p), 1e-9), reason: 'p=$p');
      }
      // 具体数值（p = 0.5、W = 400）：0.5 × 400 = 200 → 夹取 [1, 399] 不变 →
      // 200 − 1 = **199.0**。
      expect(played(0.0), closeTo(199.0, 1e-9));
      // 直线端与盒高无关（贴顶直线，中心线恒取盒中线）。
      expect(played(0.0, height: capsuleH), closeTo(199.0, 1e-9));
    });

    test('formT == 1：已播放长度 = p · 中心线周长（含具体数值）', () {
      const Size size = Size(capsuleW, capsuleH);
      const double cornerRadius = capsuleH / 2;
      final geo = resolveBarProgressGeometry(
        size: size,
        formT: 1.0,
        cornerRadius: cornerRadius,
      );
      final double len = geo.toPath().computeMetrics().first.length;
      // 中心线半径 = cornerRadius − inset = 30.5；直边 = 368 − 3 − 61 = 304。
      expect(geo.radius, closeTo(30.5, 1e-9));
      expect(len, closeTo(2 * 304.0 + 2 * math.pi * 30.5, 0.5));
      expect(len, closeTo(799.637, 0.5));

      double rim(double p) => played(
        1.0,
        progress: p,
        width: capsuleW,
        height: capsuleH,
        cornerRadius: cornerRadius,
      );

      expect(rim(0.5), closeTo(len * 0.5, 1e-9));
      expect(rim(0.5), closeTo(399.819, 0.3)); // 具体数值（p = 0.5）
      expect(rim(0.2), closeTo(159.927, 0.3));
      // 两端之比 ≈ 2.0：同一 p 的已播放长度在两端差 ≈ 一个整条宽
      // （368 盒：399.819 − 183 = 216.8px；400 盒：399.819 − 199 = 200.8px）。
      expect(rim(0.5) / played(0.0, width: capsuleW, height: lineH),
          closeTo(2.185, 0.02));
    });

    test('交棒帧 p→0（切回常驻栏的最后一刻 / 切向悬浮栏的最开始）：连续，修复前硬切 ≈200px', () {
      final double resident = played(0.0); // 常驻条端点：199.0（p = 0.5、W = 400）
      // 对照（**修复前**读数，分母 = 当前路径长度）：formT 刚离开 0，分母 W → ≈2W，
      // 已播放段瞬时 +200px —— 一个整条宽，用户报的「硬切 / 进度对不上」。
      expect(brokenPlayed(0.0005) - resident, closeTo(200.0, 0.2));
      expect(brokenPlayed(0.02) - resident, closeTo(199.3, 0.5));
      expect(brokenPlayed(0.05) - resident, closeTo(198.4, 0.5));
      // 修复后：端点附近残差亚像素。K1 把权重换成更陡的 `Cubic(0.2, 0, 0, 1)`
      // 后，「残差 = (1 − s(t))·(L − W)·p」在同一 formT 上比 smoothstep 略大
      // —— 权重在形变早期就朝胶囊口径推进，这正是 K1 要的「早跟上」。实测
      // （p = 0.5）：0.0005 → −0.005px、0.001 → −0.013px、0.005 → −0.041px
      // （端点附近先被端帽夹取量压住为略负）、0.02 → +0.413px、0.05 → +4.97px。
      for (final double t in const <double>[0.0005, 0.001, 0.005]) {
        expect((overlayPlayed(t) - resident).abs(), lessThan(0.1),
            reason: 'formT=$t 交棒残差（修复前 ${(brokenPlayed(t) - resident).toStringAsFixed(1)}px）');
      }
      expect((overlayPlayed(0.02) - resident).abs(), lessThan(0.5)); // 实测 0.413
      // 真正交棒那一帧（可见形变已前置到精确端点，formT 恰为 0）残差恰为 0 ——
      // 形变完成后浮层停在该端点等真身落定（见 bottom_bar_form_flight_test 的
      // K1 用例：末帧 formT 精确 0 / 1 + 交棒差 ≈0px）。
      expect(overlayPlayed(0.0), resident);
    });

    test('交棒帧 p→1（切向悬浮栏的最后一刻）：残差单调收敛到胶囊真身口径', () {
      final double capsule = played(
        1.0,
        width: capsuleW,
        height: capsuleH,
        cornerRadius: capsuleH / 2,
      ); // 399.819
      // 实测残差表（px，p = 0.5）：0.96→2.62、0.97→1.80、0.98→1.09、0.99→0.49、
      // 0.999→0.04。t ≤ 0.97 那一段的主导项不是本次修的量，而是**盒体自身尚未收敛**
      // （W(t)/H(t) 仍在插值途中，break 前同帧残留 1.63px），故断言窗口取 ≥0.98。
      final List<double> ts = <double>[0.98, 0.99, 0.995, 0.999];
      double prev = double.infinity;
      for (final double t in ts) {
        final double v = overlayPlayed(t);
        expect(v, lessThan(capsule), reason: 'formT=$t 不得超过胶囊端点');
        final double res = capsule - v;
        expect(res, lessThan(2.0), reason: 'formT=$t 交棒残差 ${res.toStringAsFixed(2)}px');
        expect(res, lessThanOrEqualTo(prev), reason: 'formT=$t 残差必须单调收敛');
        prev = res;
      }
      expect(capsule - overlayPlayed(0.999), lessThan(0.1)); // 实测 0.04
      // 权重（K1：从 smoothstep 换成更陡的强 ease-out `Cubic(0.2, 0, 0, 1)`，
      // 端点保真不变）：端点精确 0 / 1、单调、两端导数趋零（「交棒前一帧残差
      // 亚像素」的前提不变），中段显著更早推进。
      expect(resolveProgressSpanWeight(0.0), 0.0);
      expect(resolveProgressSpanWeight(1.0), 1.0);
      expect(resolveProgressSpanWeight(0.5), closeTo(0.877380371, 1e-6));
      expect(1.0 - resolveProgressSpanWeight(0.02), greaterThan(0.99),
          reason: '端点附近权重必须贴住 0/1（线性权重此处只到 0.98，交棒帧会残留 ≈3px）');
      expect(resolveProgressSpanWeight(0.98), greaterThan(0.99));
      // 「更早跟上」的判据（K1）：同 formT 下新权重 ≥ smoothstep 且单调不减
      // —— 全区间支配（浮点求解误差 ≤1e-6，见 Cubic 的 1e-5 误差界）。
      double smoothstep(double t) => t * t * (3.0 - 2.0 * t);
      var prevW = -1.0;
      for (var i = 0; i <= 1000; i++) {
        final double t = i / 1000;
        final double w = resolveProgressSpanWeight(t);
        expect(w, greaterThanOrEqualTo(prevW), reason: 'formT=$t 权重回退');
        expect(w, greaterThanOrEqualTo(smoothstep(t) - 1e-6),
            reason: 'formT=$t：新权重不得低于 smoothstep（「更早跟上」的反面）');
        prevW = w;
      }
      // 早期优势：s(0.25) = 0.61 vs smoothstep 0.16、s(0.5) = 0.88 vs 0.5。
      expect(resolveProgressSpanWeight(0.25), greaterThan(smoothstep(0.25) + 0.4));
      expect(resolveProgressSpanWeight(0.5), greaterThan(smoothstep(0.5) + 0.3));
    });

    test('沿 formT 扫 500 步（p = 0.5）：已播放长度单调不减、相邻步差 ≤2.4px', () {
      const int steps = 500;
      double prev = overlayPlayed(0.0);
      double maxStep = 0.0;
      double maxStepAt = 0.0;
      double minStep = 0.0; // 最负的一步（端点附近夹取量先于分母增长，允许 ≤0.1px）
      for (var i = 1; i <= steps; i++) {
        final double t = i / steps;
        final double cur = overlayPlayed(t);
        final double step = cur - prev;
        if (step > maxStep) {
          maxStep = step;
          maxStepAt = t;
        }
        if (step < minStep) minStep = step;
        prev = cur;
      }
      debugPrint(
        '[已播放段] 常驻端=${overlayPlayed(0.0).toStringAsFixed(3)}px '
        '胶囊端=${overlayPlayed(1.0).toStringAsFixed(3)}px '
        '最大相邻步差=${maxStep.toStringAsFixed(3)}px@formT=${maxStepAt.toStringAsFixed(3)} '
        '最大回退=${minStep.toStringAsFixed(3)}px',
      );
      expect(minStep, greaterThanOrEqualTo(-0.1),
          reason: '中段出现回退 ${minStep.toStringAsFixed(3)}px');
      // 上界随权重变陡按比例放大（K1：max|s'| 由 smoothstep 的 1.5 升到
      // Cubic(0.2,0,0,1) 的 ≈4；实测 2.234px@formT=0.166，步长 1/500）。
      // 判据仍是「无跳变」：硬切是 200px 量级，2.4px 只是连续曲线的正常斜率。
      expect(maxStep, lessThanOrEqualTo(2.4),
          reason: '中段相邻步差 ${maxStep.toStringAsFixed(3)}px（formT=$maxStepAt）');
      // 步差随进度线性缩小（同一扫描下 p = 0.2 应为 p = 0.5 的 ≈0.4 倍）。
      double sweepMax(double progress) {
        double p2 = overlayPlayed(0.0, progress: progress);
        double m = 0.0;
        for (var i = 1; i <= steps; i++) {
          final double cur = overlayPlayed(i / steps, progress: progress);
          if (cur - p2 > m) m = cur - p2;
          p2 = cur;
        }
        return m;
      }

      expect(sweepMax(0.2), lessThan(1.0));
      expect(sweepMax(0.2) / sweepMax(0.5), closeTo(0.4, 0.05));
      // 端点仍是两端真身口径（本次修复没有为了连续而挪端点）。
      expect(overlayPlayed(0.0), closeTo(199.0, 1e-9));
      expect(overlayPlayed(1.0), closeTo(399.819, 0.3));
    });
  });
}
