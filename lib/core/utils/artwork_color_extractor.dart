import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../services/local_artwork_cache.dart';
import '../services/media_store_service.dart';

/// 从专辑封面提取单个主色调，供歌词「动态字体颜色」、全局「封面动态取色」等场景使用。
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

  /// 提取封面主色；url 为空或提取失败时返回 null。
  ///
  /// 支持三种封面来源：
  /// - **网络封面**（http/https）：走 [CachedNetworkImageProvider]，与 UI
  ///   封面共用磁盘缓存，避免动态取色开启时每次切歌重新下载封面。
  /// - **本地内嵌封面**（`local://<filePath>` / `content://`）：通过
  ///   [LocalArtworkCache] 在 Isolate 中懒加载音频文件内嵌封面。
  /// - **本地磁盘封面**（`file://<path>`）：直接读取封面文件字节。
  static Future<Color?> extract(String? url) async {
    if (url == null || url.isEmpty) return null;
    final cached = _cache[url];
    if (cached != null) return cached;
    final palette = await loadPalette(url);
    if (palette == null) return null;
    return _analyzePalette(palette, url);
  }

  /// 加载封面并生成 [PaletteGenerator]，供「封面动态取色」与「流光背景」共用。
  ///
  /// 支持三种封面来源：
  /// - **网络封面**（http/https）：走 [CachedNetworkImageProvider]，与 UI
  ///   封面共用磁盘缓存，避免动态取色开启时每次切歌重新下载封面。
  /// - **本地内嵌封面**（`local://<filePath>` / `content://`）：通过
  ///   [LocalArtworkCache] 在 Isolate 中懒加载音频文件内嵌封面。
  /// - **本地磁盘封面**（`file://<path>`）：直接读取封面文件字节。
  ///
  /// 本地封面统一经 [ResizeImage] 缩到 480 宽再解码：背景图/本地大图取色
  /// 时避免全尺寸解码的内存峰值（高清照片解码可达上百 MB，低内存设备会
  /// 闪退）；取色分析的是色彩分布，缩到 480 宽足够且结果几乎不变。
  /// 任一来源加载/解码失败都返回 null（内部已捕获异常）。
  static Future<PaletteGenerator?> loadPalette(String url) async {
    try {
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return PaletteGenerator.fromImageProvider(
          CachedNetworkImageProvider(url),
          maximumColorCount: 12,
        );
      }
      // 本地封面：统一「读字节 → ResizeImage(MemoryImage) → PaletteGenerator」
      final bytes = await _loadLocalBytes(url);
      if (bytes == null) return null;
      return PaletteGenerator.fromImageProvider(
        ResizeImage(MemoryImage(bytes), width: 480),
        maximumColorCount: 12,
      );
    } catch (_) {
      return null;
    }
  }

  /// 读取本地封面字节；无法解析 / 文件不存在 / 无内嵌封面时返回 null。
  static Future<Uint8List?> _loadLocalBytes(String url) async {
    if (url.startsWith('local://')) {
      // local://<filePath>：音频文件内嵌封面
      final path = url.substring('local://'.length);
      if (path.isEmpty) return null;
      return LocalArtworkCache().getArtwork(path);
    }
    if (url.startsWith('content://')) {
      // content://media/...（MediaStore albumArtUri）：先解析真实路径再读内嵌封面
      final path = await MediaStoreService.resolveLocalPath(url);
      if (path == null || path.isEmpty) return null;
      return LocalArtworkCache().getArtwork(path);
    }
    if (url.startsWith('file://')) {
      // file://<path>：磁盘封面文件直接读取
      final path = url.substring('file://'.length);
      if (path.isEmpty) return null;
      final file = File(path);
      if (!file.existsSync()) return null;
      return file.readAsBytes();
    }
    return null;
  }

  /// 对 [PaletteGenerator] 候选色做过滤 + 饱和度/明度归一化，
  /// 命中合格候选即写入缓存并返回；全部不合格返回 null。
  ///
  /// 网络与本地封面共用同一分析段，保证取色口径一致。
  static Color? _analyzePalette(PaletteGenerator palette, String url) {
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
    return null;
  }
}
