import 'dart:ui' as ui;

/// 副行（翻译 / 罗马音）文字的**清晰预栅格化图**。
///
/// 用途：副行的「日历翻转」动效会给画布施加带透视分量的矩阵。Skia 对含透视
/// 的矩阵会放弃字形图集、退回字形**路径**逐帧渲染（中文副行每行数十个复杂
/// 字形），逐帧透视画文字是切行掉帧的直接来源。改为「预栅格化一次 + 透视
/// 画图像」后，透视变换落在纹理四边形的 GPU 投影上，代价可忽略。
///
/// 约定：
/// - 图内文字烘焙为**不透明白色**，主题色与淡入淡出 alpha 在合成期用
///   [ui.BlendMode.srcIn] 着色（因此进度 / 透明度动画不会触发重烘焙）；
/// - [width] / [height] 为**逻辑尺寸**，与 `TextPainter.width/height` 同口径，
///   图像像素尺寸 = 逻辑尺寸 × 烘焙倍率；
/// - 生命周期由持有者管理（换歌 / 几何变化 / dispose 时 `image.dispose()`）。
class AuxTextImage {
  const AuxTextImage({
    required this.image,
    required this.width,
    required this.height,
    this.pad = 0,
  });

  final ui.Image image;

  /// 逻辑宽度（与副行 TextPainter 布局宽度一致，用于对齐与翻转锚点）。
  final double width;

  /// 逻辑高度（与副行 TextPainter 布局高度一致，用于翻转锚点）。
  final double height;

  /// 柔边外扩（逻辑 px，默认 0 = 未开启柔边）。
  ///
  /// 柔边图的像素尺寸含四周 [pad]；[width] / [height] 仍是**文字**逻辑尺寸，
  /// 绘制侧需向左上偏移 [pad] 并把目标矩形放大 `2*pad`，字形落点才与文字路径一致。
  final double pad;

  void dispose() => image.dispose();
}
