import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/comment_image_dismiss.dart';

/// 甩回小图的几何与阈值：全部是纯函数，逐条钉死数值与矩阵契约。
void main() {
  group('shouldDismiss', () {
    test('距离超过 dismissDistance 判定为甩出（任意方向）', () {
      expect(
        CommentImageDismiss.shouldDismiss(
          drag: const Offset(0, 130),
          velocity: Velocity.zero,
        ),
        isTrue,
      );
      expect(
        CommentImageDismiss.shouldDismiss(
          drag: const Offset(-130, 0),
          velocity: Velocity.zero,
        ),
        isTrue,
      );
    });

    test('速度超过 dismissVelocity 判定为甩出（距离可以很小）', () {
      expect(
        CommentImageDismiss.shouldDismiss(
          drag: const Offset(0, 12),
          velocity: const Velocity(pixelsPerSecond: Offset(0, -900)),
        ),
        isTrue,
      );
    });

    test('距离与速度都不足 → 不甩出（回弹）', () {
      expect(
        CommentImageDismiss.shouldDismiss(
          drag: const Offset(0, 40),
          velocity: Velocity.zero,
        ),
        isFalse,
      );
      expect(
        CommentImageDismiss.shouldDismiss(
          drag: const Offset(0, 100),
          velocity: const Velocity(pixelsPerSecond: Offset(0, 300)),
        ),
        isFalse,
      );
    });
  });

  group('dragRatio', () {
    test('未拖为 0，拖满一个阈值距离封顶为 1', () {
      expect(CommentImageDismiss.dragRatio(Offset.zero), 0);
      expect(
        CommentImageDismiss.dragRatio(const Offset(0, 60)),
        closeTo(0.5, 0.0001),
      );
      expect(CommentImageDismiss.dragRatio(const Offset(0, 600)), 1);
    });
  });

  group('containRect', () {
    const viewport = Rect.fromLTWH(0, 0, 400, 800);

    test('宽图：占满宽度，高度按比例居中', () {
      final r = CommentImageDismiss.containRect(viewport, 2.0);
      expect(r.width, 400);
      expect(r.height, 200);
      expect(r.top, 300);
    });

    test('高图：占满高度，宽度按比例居中', () {
      // 视口 400x800 的宽高比为 0.5；真正更高的图须 < 0.5，取 0.25
      // （200x800 的 contain 结果对应宽高比 0.25，非计划原稿误写的 0.5）。
      final r = CommentImageDismiss.containRect(viewport, 0.25);
      expect(r.width, 200);
      expect(r.height, 800);
      expect(r.left, 100);
    });

    test('宽高比与视口一致时铺满整个视口', () {
      expect(
        CommentImageDismiss.containRect(viewport, 400 / 800),
        viewport,
      );
    });

    test('宽高比非法（<=0 / NaN / 无限）回退 1.0，不崩不出 NaN', () {
      for (final bad in [0.0, -1.5, double.nan, double.infinity]) {
        final r = CommentImageDismiss.containRect(viewport, bad);
        expect(r.width, 400, reason: 'aspect=$bad');
        expect(r.height, 400, reason: 'aspect=$bad');
      }
    });
  });

  group('rectToRect', () {
    test('源=目标时是单位矩阵（p=1 的全屏态不产生任何位移）', () {
      const from = Rect.fromLTWH(0, 300, 400, 200);
      final m = CommentImageDismiss.rectToRect(from: from, to: from);
      expect(MatrixUtils.transformRect(m, from), from);
    });

    test('源矩形被精确映射到目标矩形（中心与尺寸都对齐）', () {
      const from = Rect.fromLTWH(0, 300, 400, 200);
      const to = Rect.fromLTWH(24, 640, 60, 45);
      final m = CommentImageDismiss.rectToRect(from: from, to: to);
      final mapped = MatrixUtils.transformRect(m, from);
      expect(mapped.left, closeTo(to.left, 0.001));
      expect(mapped.top, closeTo(to.top, 0.001));
      expect(mapped.width, closeTo(to.width, 0.001));
      expect(mapped.height, closeTo(to.height, 0.001));
    });

    test('源宽高为 0 时退化为纯平移，不产生除零/NaN', () {
      const from = Rect.fromLTWH(0, 0, 0, 0);
      const to = Rect.fromLTWH(10, 20, 0, 0);
      final m = CommentImageDismiss.rectToRect(from: from, to: to);
      final mapped = MatrixUtils.transformRect(m, from);
      expect(mapped.left, closeTo(10, 0.001));
      expect(mapped.top, closeTo(20, 0.001));
    });
  });

  group('draggedRect / fallbackLanding', () {
    const full = Rect.fromLTWH(0, 300, 400, 200);

    test('未拖动时就是全屏矩形本身', () {
      expect(CommentImageDismiss.draggedRect(full: full, drag: Offset.zero), full);
    });

    test('拖动时中心跟手位移，且最多缩小 dragShrink', () {
      // 拖满一个阈值距离（|(72,-96)| = 120）才会缩小到上限 dragShrink
      final r = CommentImageDismiss.draggedRect(
        full: full,
        drag: const Offset(72, -96),
      );
      expect(r.center.dx, closeTo(full.center.dx + 72, 0.001));
      expect(r.center.dy, closeTo(full.center.dy - 96, 0.001));
      expect(
        r.width,
        closeTo(full.width * (1 - CommentImageDismiss.dragShrink), 0.001),
      );
    });

    test('无来源小图时兜底落到中心 30%', () {
      final r = CommentImageDismiss.fallbackLanding(full);
      expect(r.center, full.center);
      expect(r.width, closeTo(full.width * 0.3, 0.001));
    });
  });
}
