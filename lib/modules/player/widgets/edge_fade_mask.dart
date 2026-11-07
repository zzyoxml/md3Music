import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 计算渐隐带宽度（logical px）：按容器宽取 [fadeRatio] 比例后，
/// 钳制在 [minFade]–[maxFade]。导出纯函数便于单元测试钳制边界。
double edgeFadeWidth(
  double width, {
  double minFade = 24.0,
  double maxFade = 36.0,
  double fadeRatio = 0.06,
}) {
  return (width * fadeRatio).clamp(minFade, maxFade);
}

/// 左右边缘透明度渐隐遮罩（ShaderMask + BlendMode.dstIn）。
///
/// 用途：AM 样式全屏播放器（横屏 / Pad 宽屏）右栏内容区（PlayerTabPager），
/// 让播放列表、歌词等内容在滚动到左右边缘时逐渐淡出，而不是被生硬裁切。
///
/// 设计口径（与确认过的方案一致）：
/// - 透明度渐隐（fade），不是高斯模糊；遮罩**常驻**，不监听 PageController
///   偏移（内容贴边时才被压暗到 0，其余位置全显）。
/// - 渐变颜色用白色：[BlendMode.dstIn] 只取 shader 的 alpha 通道，颜色本身
///   无意义，不算硬编码颜色。
/// - 渐隐带宽度按容器宽度取小比例（6%），钳制在 24–36 logical px 之间：
///   窄栏不会把内容全部遮掉，超宽屏也不会出现一条宽得突兀的雾带。
///
/// shader 缓存：shaderCallback 每次 build/重绘都会被调，线性渐变只依赖
/// bounds 尺寸，故按尺寸缓存 ui.Gradient（参照 apple_lyrics_view 的
/// 上下渐隐与 marquee_text 的做法）。尺寸变化时重建并丢弃旧实例。
/// 注意：本组件必须拿到**有界**约束 —— 若放进无界（无限宽）环境，
/// ShaderMask 会拿到无限 rect，shader 画不出内容（marquee_text 注释里的坑）。
class EdgeFadeMask extends StatefulWidget {
  const EdgeFadeMask({
    super.key,
    required this.child,
    this.enabled = true,
    this.minFade = 24.0,
    this.maxFade = 36.0,
    this.fadeRatio = 0.06,
  });

  final Widget child;

  /// 关闭时原样返回 [child]（零 widget 开销，等价于不包遮罩）。
  /// 「横屏播放页边缘渐隐」设置项关掉后走这一分支。
  final bool enabled;

  /// 渐隐带宽度下限（logical px）。
  final double minFade;

  /// 渐隐带宽度上限（logical px）。
  final double maxFade;

  /// 渐隐带宽度占容器宽度的比例（先按比例取值，再钳到 [minFade]–[maxFade]）。
  final double fadeRatio;

  @override
  State<EdgeFadeMask> createState() => _EdgeFadeMaskState();
}

class _EdgeFadeMaskState extends State<EdgeFadeMask> {
  // 上次构建的 shader 与其对应的宽度：宽度不变直接复用，避免每次重绘都
  // 重新分配 LinearGradient + createShader。
  ui.Shader? _shader;
  double? _shaderWidth;

  ui.Shader _shaderFor(Rect bounds) {
    final w = bounds.width;
    if (_shader != null && w == _shaderWidth) {
      return _shader!;
    }
    _shader?.dispose();
    // 渐隐带宽度：按容器宽取比例后钳制；容器异常窄时渐隐带最多各占一半，
    // 两带在中线相接，不会越界。
    final ratio =
        (edgeFadeWidth(
          w,
          minFade: widget.minFade,
          maxFade: widget.maxFade,
          fadeRatio: widget.fadeRatio,
        ) / w)
            .clamp(0.0, 0.5);
    _shader = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const [
        Colors.transparent,
        Colors.white,
        Colors.white,
        Colors.transparent,
      ],
      stops: [0.0, ratio, 1.0 - ratio, 1.0],
    ).createShader(bounds);
    _shaderWidth = w;
    return _shader!;
  }

  @override
  void dispose() {
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return ShaderMask(
      shaderCallback: _shaderFor,
      blendMode: BlendMode.dstIn,
      child: widget.child,
    );
  }
}
