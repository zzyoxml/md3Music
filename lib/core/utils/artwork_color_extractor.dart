import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// 从专辑封面提取单个主色调，供歌词「动态字体颜色」等场景使用。
///
/// 提取思路复用 [FlowingBackground]（动态流光背景）的部分逻辑：
/// - 用 [PaletteGenerator] 从封面图片提取候选色（按像素占比降序）
/// - 过滤近黑 / 近白 / 低饱和的候选，避免稀释色彩层次
/// - 对饱和度做温和归一化（0.55~0.9），低饱和封面避免灰扑扑、过高避免刺眼
///
/// 与流光背景不同的是只取一个主色（占比最高的合格候选），
/// 歌词动态色仅需单一颜色即可完成混色。
class ArtworkColorExtractor {
  ArtworkColorExtractor._();

  /// 提取封面主色；url 为空、非网络图片或提取失败时返回 null。
  static Future<Color?> extract(String? url) async {
    if (url == null || url.isEmpty) return null;
    // 本地封面（content:// / file:// / local://）不参与提取
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return null;
    }
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(url),
        maximumColorCount: 12,
      );
      // palette.colors 按像素占比降序，取第一个合格的候选作为主色
      for (final c in palette.colors) {
        final hsl = HSLColor.fromColor(c);
        if (hsl.saturation >= 0.15 &&
            hsl.lightness > 0.1 &&
            hsl.lightness < 0.92) {
          // 饱和度温和归一化（0.55~0.9），低饱和封面避免灰扑扑、过高避免刺眼
          // 明度归一化到亮区间（0.6~0.85）：歌词文字在深色背景上需要足够亮，
          // 与流光背景（背景需要深色层次）不同，这里不允许取到过暗的提取色
          return hsl
              .withSaturation(hsl.saturation.clamp(0.55, 0.9).toDouble())
              .withLightness(hsl.lightness.clamp(0.6, 0.85).toDouble())
              .toColor();
        }
      }
    } catch (_) {}
    return null;
  }
}
