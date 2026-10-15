import 'package:material_ui/material_ui.dart';

import 'ui_density.dart';

/// 锚点（设计像素）→ 根（窗口像素）的实测线性比例；无锚点或退化时 1.0。
///
/// 锚点到根之间只有 [DisplayScaleScope] 的 `FittedBox` 等比缩放（本项目
/// 无旋转/斜切祖先），取单位 x 位移的变换差即可，无需矩阵求逆。
double _displayScaleFactor(BuildContext context) {
  final anchor = DisplayScaleReference.anchorOf(context);
  if (anchor is! RenderBox) return 1.0;
  final toRoot = anchor.getTransformTo(null);
  final origin = MatrixUtils.transformPoint(toRoot, Offset.zero);
  final unitX = MatrixUtils.transformPoint(toRoot, const Offset(1, 0));
  final ratio = (unitX - origin).dx;
  return ratio.abs() < 1e-6 ? 1.0 : ratio;
}

/// 把**窗口（RenderView 根）坐标**的点换算到「显示大小」设计像素空间。
///
/// `Listener.onPointerDown/Move` 的 `e.position` 是根空间；而
/// `MediaQuery.sizeOf`、`_miniTopY`、路由 `Transform.translate` 的位移都在
/// [DisplayScaleScope] 的设计像素空间。混用会让拖拽进度偏 s 倍起步。
/// 不在 [DisplayScaleScope] 内（或 1.0 档）时原样返回，行为与修复前一致。
Offset toDisplaySpace(BuildContext context, Offset windowPosition) =>
    windowPosition / _displayScaleFactor(context);

/// 同 [toDisplaySpace]，但用于**位移/速度增量**（不含平移语义，数值同比例）。
Offset toDisplaySpaceDelta(BuildContext context, Offset windowDelta) =>
    windowDelta / _displayScaleFactor(context);
