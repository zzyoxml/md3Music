import 'package:cached_network_image/cached_network_image.dart';
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

  /// 已提取结果缓存（url → 主色）。
  ///
  /// 同一封面在播放器往返、反复切歌时会重复进入，避免每次重新
  /// 解码 + PaletteGenerator 分析；仅缓存成功结果（失败不缓存，
  /// 避免临时网络问题导致该封面之后永远不提取）。
  static final Map<String, Color> _cache = {};

  /// 提取封面主色；url 为空、非网络图片或提取失败时返回 null。
  static Future<Color?> extract(String? url) async {
    if (url == null || url.isEmpty) return null;
    // 本地封面（content:// / file:// / local://）不参与提取
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return null;
    }
    final cached = _cache[url];
    if (cached != null) return cached;
    try {
      // 用 CachedNetworkImageProvider 而非 NetworkImage：
      // UI 封面走 CachedNetworkImage 的磁盘缓存，两者共用 cacheManager，
      // 提取可命中 UI 已下载的封面，避免动态颜色开启时每次进播放器 /
      // 切歌都重新网络下载封面（与 UI 封面下载并发导致卡顿）。
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
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
          final color = hsl
              .withSaturation(hsl.saturation.clamp(0.55, 0.9).toDouble())
              .withLightness(hsl.lightness.clamp(0.6, 0.85).toDouble())
              .toColor();
          _cache[url] = color;
          return color;
        }
      }
    } catch (_) {}
    return null;
  }
}
