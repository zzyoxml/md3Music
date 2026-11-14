/// [TvFocusFrameMotion] / 半径 / 时长曲线的纯 Dart 单测。
///
/// 这些判断放在普通构建同样编译的类里（见 `tv_focus_frame_animation.dart` 文件头），
/// 因此不需要 `--dart-define=MD3_TV=true` 就能钉住行为——这正是它独立成文件的理由。
///
/// 注意：**第一次** `update` 永远直接落位（没有历史目标可续，见 `update` 的
/// "首帧"分支）。因此所有滑行用例都先用起点矩形"播种"一次，再切到远距离目标。
library;

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/remote/tv_focus_frame_animation.dart';

/// 以 (left, top, right, bottom) 造矩形（屏幕坐标，左上原点）。
Rect rect(double l, double t, double r, double b) =>
    Rect.fromLTRB(l, t, r, b);

/// 播种起点矩形（首次 update 直接落位），返回该 motion。
TvFocusFrameMotion seeded(Rect start) {
  final m = TvFocusFrameMotion();
  m.update(target: start, focusSwitched: true);
  expect(m.isSettled, isTrue, reason: '首帧必须直接落位');
  return m;
}

/// 推进 [totalMs]，每帧 16ms。
void tickN(TvFocusFrameMotion m, int totalMs) {
  final frames = totalMs ~/ 16;
  for (var i = 0; i < frames; i++) {
    m.tick(const Duration(milliseconds: 16));
  }
}

void main() {
  group('tvFocusFrameGlideFor（时长曲线）', () {
    test('随距离增长', () {
      final near = tvFocusFrameGlideFor(60);
      final mid = tvFocusFrameGlideFor(300);
      final far = tvFocusFrameGlideFor(900);
      expect(near.inMilliseconds, lessThan(mid.inMilliseconds));
      expect(mid.inMilliseconds, lessThan(far.inMilliseconds));
      // 具体档位：60px → 120 + 24 = 144ms；300px → 240ms；900px → 480 → 封顶 420ms。
      expect(near.inMilliseconds, 144);
      expect(mid.inMilliseconds, 240);
      expect(far.inMilliseconds, TvFocusFrameMotion.kMaxGlide.inMilliseconds);
    });

    test('夹在最短 / 最长之间', () {
      expect(
        tvFocusFrameGlideFor(0).inMilliseconds,
        TvFocusFrameMotion.kMinGlide.inMilliseconds,
      );
      expect(
        tvFocusFrameGlideFor(100000).inMilliseconds,
        TvFocusFrameMotion.kMaxGlide.inMilliseconds,
      );
      expect(
        tvFocusFrameGlideFor(-50).inMilliseconds,
        TvFocusFrameMotion.kMinGlide.inMilliseconds,
        reason: '负距离按 0 处理（夹到最短档）',
      );
    });

    test('reducedMotion 恒为 0', () {
      for (final d in <double>[0.0, 60, 300, 900]) {
        expect(
          tvFocusFrameGlideFor(d, reducedMotion: true),
          Duration.zero,
          reason: '减弱动态效果下不播过渡',
        );
      }
    });
  });

  group('tvFocusFrameRadiusFor（形变半径）', () {
    test('随短边单调增长', () {
      final r40 = tvFocusFrameRadiusFor(rect(0, 0, 40, 40));
      final r56 = tvFocusFrameRadiusFor(rect(0, 0, 56, 56));
      final r112 = tvFocusFrameRadiusFor(rect(0, 0, 112, 112));
      expect(r40, closeTo(8.8, 1e-9));
      expect(r56, closeTo(12.32, 1e-9));
      expect(r112, closeTo(24, 1e-9));
      expect(r40, lessThan(r56));
      expect(r56, lessThan(r112));
    });

    test('取短边而非长边', () {
      // 200×40：短边 40 → 8.8，不是长边的 44（即便不看也被封顶 24）。
      expect(tvFocusFrameRadiusFor(rect(0, 0, 200, 40)), closeTo(8.8, 1e-9));
      expect(tvFocusFrameRadiusFor(rect(0, 0, 40, 200)), closeTo(8.8, 1e-9));
    });

    test('夹取上下限', () {
      // 20×20：20*0.22 = 4.4 < 下限 6 → 取 6。
      expect(tvFocusFrameRadiusFor(rect(0, 0, 20, 20)), 6);
      // 400×400：400*0.22 = 88 > 上限 24 → 取 24。
      expect(tvFocusFrameRadiusFor(rect(0, 0, 400, 400)), 24);
    });

    test('空 / 非有限矩形返回下限', () {
      expect(tvFocusFrameRadiusFor(Rect.zero), TvFocusFrameMotion.kMinRadius);
      expect(
        tvFocusFrameRadiusFor(rect(0, 0, double.nan, 10)),
        TvFocusFrameMotion.kMinRadius,
      );
      expect(
        tvFocusFrameRadiusFor(rect(0, 0, 10, double.infinity)),
        TvFocusFrameMotion.kMinRadius,
      );
    });

    test('落位后的半径即目标形状的半径（各形态抽样）', () {
      for (final r in <Rect>[
        rect(0, 0, 20, 20), // 小图标钮
        rect(0, 0, 48, 48), // 方形卡片
        rect(0, 0, 240, 56), // 长条形列表行
        rect(0, 0, 400, 400), // 大封面
      ]) {
        final m = seeded(r);
        expect(m.pose!.radius, tvFocusFrameRadiusFor(r));
      }
    });
  });

  group('TvFocusFrameMotion：焦点切换 → 连贯滑行', () {
    test('首帧仍在起点，未瞬移', () {
      final m = seeded(rect(0, 0, 40, 40));
      final to = rect(0, 0, 40, 40).translate(300, 0);
      m.update(target: to, focusSwitched: true);
      expect(m.pose!.rect, rect(0, 0, 40, 40), reason: '滑行第一帧不得瞬移');
      expect(m.isSettled, isFalse);
    });

    test('过程中姿态严格夹在两端之间', () {
      final from = rect(0, 0, 40, 40);
      final to = from.translate(300, 0);
      final m = seeded(from);
      m.update(target: to, focusSwitched: true);
      tickN(m, 96); // 总时长 236ms
      final mid = m.pose!.rect;
      expect(mid.left, greaterThan(from.left));
      expect(mid.left, lessThan(to.left));
      expect(mid.right, greaterThanOrEqualTo(from.right));
      expect(mid.right, lessThanOrEqualTo(to.right));
      expect(mid.top, to.top);
      expect(mid.bottom, to.bottom);
    });

    test('时长用尽后精确落在目标上', () {
      final from = rect(0, 0, 40, 40);
      final to = from.translate(300, 0);
      final m = seeded(from);
      m.update(target: to, focusSwitched: true);
      tickN(m, 640); // >> 236ms
      expect(m.isSettled, isTrue);
      expect(m.pose, TvFocusFramePose(rect: to, radius: tvFocusFrameRadiusFor(to)));
    });

    test('形变：半径在滑行中连续插值（严格趋近目标半径）', () {
      final from = rect(0, 0, 200, 200); // 半径封顶 24
      final to = rect(400, 0, 440, 40); // 半径 8.8
      final m = seeded(from);
      m.update(target: to, focusSwitched: true);
      final radii = <double>[];
      for (var i = 0; i < 40 && !m.isSettled; i++) {
        m.tick(const Duration(milliseconds: 8));
        radii.add(m.pose!.radius);
      }
      expect(radii.length, greaterThan(4));
      // 首帧已离开起点半径（非端值）……
      expect(radii.first, lessThan(24));
      expect(radii.first, greaterThan(8.8));
      // ……之后严格单调递减，无跳变……
      for (var i = 1; i < radii.length; i++) {
        expect(radii[i], lessThan(radii[i - 1]));
      }
      // ……末端精确落在目标半径。
      expect(m.pose!.radius, 8.8);
    });

    test('目标几乎没动（亚像素）时直接落位，不空转', () {
      final m = seeded(rect(0, 0, 40, 40));
      final to = rect(0.2, 0, 40.2, 40);
      m.update(target: to, focusSwitched: true);
      expect(m.isSettled, isTrue, reason: '0.2px 的位移不值得 140ms 滑行');
      expect(m.pose!.rect, to);
    });

    test('滑行中再切焦点：保留时间轴（不重置），终点换成新目标', () {
      final from = rect(0, 0, 40, 40);
      final m = seeded(from);
      m.update(target: from.translate(300, 0), focusSwitched: true); // 236ms
      tickN(m, 96);
      // 再切到 600px 远的目标。**若时间轴被重置**，这里会按"从当前姿态到新目标"
      // 重算 256ms，160ms 走不完；**保留时间轴**时累计 96+160=256ms > 236ms，必已收敛。
      m.update(target: from.translate(600, 0), focusSwitched: true);
      tickN(m, 160);
      expect(m.isSettled, isTrue, reason: '时间轴必须延续，不得每步重置');
      expect(m.pose!.rect, from.translate(600, 0));
    });

    test('reducedMotion：滑行退化为立即落位', () {
      final m = seeded(rect(0, 0, 40, 40));
      m.reducedMotion = true;
      final to = rect(0, 0, 40, 40).translate(500, 300);
      m.update(target: to, focusSwitched: true);
      expect(m.isSettled, isTrue);
      expect(m.pose!.rect, to);
    });
  });

  group('TvFocusFrameMotion：内容在动 → 贴合', () {
    test('同焦点 + 目标位移 → 立即落位，不起滑行', () {
      final m = seeded(rect(0, 0, 40, 40));
      final scrolled = rect(0, 0, 40, 40).translate(40, 0);
      m.update(target: scrolled, focusSwitched: false);
      expect(m.isSettled, isTrue, reason: '内容自己在动时必须贴合');
      expect(m.pose!.rect, scrolled);
    });

    test('同焦点 + 大幅跳变（路由转场级）→ 直接落位', () {
      final m = seeded(rect(0, 0, 40, 40));
      final moved = rect(0, 0, 40, 40).translate(600, 400);
      m.update(target: moved, focusSwitched: false);
      expect(m.isSettled, isTrue);
      expect(m.pose!.rect, moved);
    });

    test('同焦点 + 快速 fling 连续贴合：红框不得落后于滚动中的元素', () {
      final m = seeded(rect(0, 0, 40, 40));
      var now = rect(0, 0, 40, 40);
      // 每帧 20px 的 fling，连续 30 帧（每帧微幅、但红框若起跑就会累积成拖影）。
      for (var i = 1; i <= 30; i++) {
        now = now.translate(20, 0);
        m.update(target: now, focusSwitched: false);
        m.tick(const Duration(milliseconds: 16));
      }
      expect(m.pose!.rect, now, reason: '红框必须始终与滚动中的元素重合');
    });

    test('同焦点 + 目标未变 → 幂等，零变化', () {
      final m = seeded(rect(0, 0, 40, 40));
      final settled = m.pose;
      for (var i = 0; i < 5; i++) {
        m.update(target: rect(0, 0, 40, 40), focusSwitched: false);
        m.tick(const Duration(milliseconds: 16));
      }
      expect(m.pose, settled);
      expect(m.isSettled, isTrue);
    });
  });

  group('TvFocusFrameMotion：滑行途中被滚动带走', () {
    test('保留时间轴，只更新终点（不被滚动打断重起）', () {
      final from = rect(0, 0, 40, 40);
      final m = seeded(from);
      m.update(target: from.translate(300, 0), focusSwitched: true);
      tickN(m, 96);
      final before = m.pose!.rect.center.dx;
      // 滚动把目标带走 10px（ensureVisible 的常见幅度），焦点并未切换。
      m.update(target: from.translate(310, 0), focusSwitched: false);
      tickN(m, 16);
      expect(m.pose!.rect.center.dx, greaterThan(before), reason: '仍应在推进');
      expect(m.isSettled, isFalse);
    });
  });

  group('TvFocusFrameMotion：复位与生命周期', () {
    test('目标消失（焦点落到 scope）→ 姿态复位', () {
      final m = seeded(rect(0, 0, 40, 40));
      m.update(target: null, focusSwitched: false);
      expect(m.pose, isNull);
    });

    test('非有限目标 → 复位', () {
      final m = seeded(rect(0, 0, 40, 40));
      m.update(target: rect(0, 0, double.nan, 40), focusSwitched: true);
      expect(m.pose, isNull);
    });

    test('滑行中目标消失 → 复位，已用时间一并清掉', () {
      final m = seeded(rect(0, 0, 40, 40));
      m.update(target: rect(0, 0, 40, 40).translate(300, 0), focusSwitched: true);
      tickN(m, 96);
      m.update(target: null, focusSwitched: false);
      expect(m.pose, isNull);
      expect(m.isSettled, isTrue);
    });

    test('复位后可再次正常起跑（无旧起点泄漏）', () {
      final m = seeded(rect(0, 0, 40, 40));
      m.update(target: null, focusSwitched: false);
      final to = rect(0, 0, 40, 40).translate(200, 0);
      m.update(target: to, focusSwitched: true);
      expect(
        m.pose,
        TvFocusFramePose(rect: to, radius: tvFocusFrameRadiusFor(to)),
        reason: '复位后无旧起点可续，应直接落位',
      );
    });

    test('首帧无历史目标 → 直接落位（不从屏幕外飞入）', () {
      final m = TvFocusFrameMotion();
      final to = rect(0, 0, 40, 40);
      m.update(target: to, focusSwitched: true);
      expect(m.isSettled, isTrue);
      expect(m.pose!.rect, to);
    });
  });
}
