import 'package:flutter/material.dart';

import 'local_artwork_image.dart';

/// 智能封面图组件：根据 artworkUri 类型选择不同的加载策略。
///
/// 支持：
/// - **http(s)://** 在线封面：使用 [Image.network]
/// - **content://** MediaStore 封面：通过 fallbackFilePath 读内嵌封面
/// - **local://<filePath>** 本地文件：使用 [LocalArtworkCache] 懒加载
/// - **null** 或未知：显示占位符
class SmartArtworkImage extends StatefulWidget {
  final String? artworkUri;
  final String? fallbackFilePath;
  final double size;
  final double borderRadius;

  const SmartArtworkImage({
    super.key,
    this.artworkUri,
    this.fallbackFilePath,
    required this.size,
    this.borderRadius = 8,
  });

  @override
  State<SmartArtworkImage> createState() => _SmartArtworkImageState();
}

class _SmartArtworkImageState extends State<SmartArtworkImage> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final uri = widget.artworkUri;

    Widget child;
    if (uri == null) {
      // URI 为空时，尝试用 fallbackFilePath 读内嵌封面
      if (widget.fallbackFilePath != null) {
        child = LocalArtworkImage(
          filePath: widget.fallbackFilePath!,
          size: widget.size,
          borderRadius: widget.borderRadius,
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: child,
        );
      }
      child = _placeholder(colorScheme);
    } else if (uri.startsWith('local://')) {
      // local:// 占位符：从文件路径读取内嵌封面
      final filePath = uri.substring('local://'.length);
      child = LocalArtworkImage(
        filePath: filePath,
        size: widget.size,
        borderRadius: widget.borderRadius,
      );
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: child,
      );
    } else if (uri.startsWith('content://')) {
      // content:// URI 无法被 Image.network 加载（非 HTTP 协议），
      // 直接用 fallbackFilePath 走 LocalArtworkImage 懒加载内嵌封面
      if (widget.fallbackFilePath != null) {
        child = LocalArtworkImage(
          filePath: widget.fallbackFilePath!,
          size: widget.size,
          borderRadius: widget.borderRadius,
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: child,
        );
      }
      child = _placeholder(colorScheme);
    } else if (uri.startsWith('http://') ||
        uri.startsWith('https://')) {
      // http(s):// 在线封面用 Image.network
      final isFill = widget.size == double.infinity;
      child = Image.network(
        uri,
        width: isFill ? double.infinity : widget.size,
        height: isFill ? double.infinity : widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) {
          if (widget.fallbackFilePath != null) {
            return LocalArtworkImage(
              filePath: widget.fallbackFilePath!,
              size: widget.size,
              borderRadius: widget.borderRadius,
            );
          }
          return _placeholder(colorScheme);
        },
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: isFill ? double.infinity : widget.size,
            height: isFill ? double.infinity : widget.size,
            color: colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.hourglass_empty,
              size: isFill ? 40 : widget.size * 0.4,
              color: colorScheme.onSurfaceVariant,
            ),
          );
        },
      );
    } else if (uri.startsWith('file://')) {
      // file:// URI
      final isFill = widget.size == double.infinity;
      child = Image.network(
        uri,
        width: isFill ? double.infinity : widget.size,
        height: isFill ? double.infinity : widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(colorScheme),
      );
    } else {
      // 兜底：当作普通 URL 处理
      child = Image.network(
        uri,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(colorScheme),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: child,
    );
  }

  Widget _placeholder(ColorScheme colorScheme) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: Icon(
        Icons.music_note,
        size: widget.size * 0.4,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
