import 'package:flutter/material.dart';

/// 全屏图片「甩回评论区小图」的几何与阈值（纯函数，便于单测）。
///
/// 坐标系约定：所有矩形都在**同一个页面坐标系**里（页面左上角为原点）。
/// 查看器把 `PageView` 作为 `Transform` 的子节点，页面原点与全屏原点重合，
/// 且 `Transform` 不传 `alignment`（默认 null = 绕子节点原点变换），
/// 因此这里的矩阵可以直接喂给 `Transform(transform: ...)`。
class CommentImageDismiss {
  const CommentImageDismiss._();

  /// 拖动距离达到该值即视为甩出（px）。
  static const double dismissDistance = 120;

  /// 甩出手势的最小速度（px/s）。
  static const double dismissVelocity = 700;

  /// 拖动时图片最多缩小的比例（拿起感）。
  static const double dragShrink = 0.06;

  /// 拖动归一化进度：0（未拖）→ 1（拖满一个 [dismissDistance]）。
  static double dragRatio(Offset drag) =>
      (drag.distance / dismissDistance).clamp(0.0, 1.0);

  /// 距离或速度任一达标即甩出（方向不限：上甩与下拉都能关闭）。
  static bool shouldDismiss({required Offset drag, required Velocity velocity}) {
    if (drag.distance >= dismissDistance) return true;
    return velocity.pixelsPerSecond.distance >= dismissVelocity;
  }

  /// 图片按 [aspect] 在 [viewport] 内的 contain 适配矩形。
  ///
  /// 与 `BoxFit.contain` 落位一致：图片是页面里 `Center` 的子节点，所以「图片在
  /// 页面中的矩形」可以纯算出来，不必等网络图解码完再去量 RenderBox。
  static Rect containRect(Rect viewport, double aspect) {
    final a = (aspect.isFinite && aspect > 0) ? aspect : 1.0;
    final vw = viewport.width;
    final vh = viewport.height;
    final viewportAspect = vw / vh;
    final w = a >= viewportAspect ? vw : vh * a;
    final h = a >= viewportAspect ? vw / a : vh;
    return Rect.fromLTWH(
      viewport.left + (vw - w) / 2,
      viewport.top + (vh - h) / 2,
      w,
      h,
    );
  }

  /// 构造把 [from] 矩形映射到 [to] 矩形的矩阵，供 `Transform(transform: ...)` 使用。
  ///
  /// 契约：**在页面坐标系里把 [from] 的四角精确送到 [to] 的四角**。
  /// 做法是仿射映射 `p → S·p + t`：对角缩放 `S` 由宽高比推出，平移量 `t` 由中心
  /// 对齐推出（`t = to.center − S·from.center`）。
  ///
  /// 注意两点：
  /// - 必须用 `translateByDouble` / `scaleByDouble`：vector_math 2.4 已把
  ///   `translate(x, y)` / `scale(s)` 标记为 deprecated（本仓
  ///   `lib/modules/player/player_cover_morph_layer.dart` 已按新 API 写）。
  /// - 末位 w 必须给 `1.0`：给 0 会把矩阵第 4 行清零、退化成非仿射，
  ///   `localToGlobal` 之类会直接返回 NaN / Infinity。
  static Matrix4 rectToRect({required Rect from, required Rect to}) {
    final sx = from.width == 0 ? 1.0 : to.width / from.width;
    final sy = from.height == 0 ? 1.0 : to.height / from.height;
    final dx = to.center.dx - from.center.dx * sx;
    final dy = to.center.dy - from.center.dy * sy;
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(sx, sy, 1, 1);
  }

  /// 拖动中的图片矩形：跟手平移 + 最多 [dragShrink] 的轻微缩小。
  static Rect draggedRect({required Rect full, required Offset drag}) {
    final k = 1 - dragShrink * dragRatio(drag);
    return Rect.fromCenter(
      center: full.center + drag,
      width: full.width * k,
      height: full.height * k,
    );
  }

  /// 没拿到来源小图时的兜底落点：以全屏图片中心为心缩到 30%。
  static Rect fallbackLanding(Rect full) => Rect.fromCenter(
        center: full.center,
        width: full.width * 0.3,
        height: full.height * 0.3,
      );
}
