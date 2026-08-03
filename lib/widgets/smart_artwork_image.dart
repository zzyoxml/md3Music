import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'local_artwork_image.dart';
import '../services/stream_cache_manager.dart';

/// 智能封面图组件：根据 artworkUri 类型选择不同的加载策略。
///
/// 支持：
/// - **http(s)://** 在线封面：使用 [Image.network]，加载失败时回查 StreamCache 兜底
/// - **content://** MediaStore 封面：通过 fallbackFilePath 读内嵌封面
/// - **local://<filePath>** 本地文件：使用 [LocalArtworkCache] 懒加载
/// - **null** 或未知：显示占位符
class SmartArtworkImage extends StatefulWidget {
  final String? artworkUri;
  final String? fallbackFilePath;
  final double size;
  final double borderRadius;

  /// 歌曲 ID，用于在线封面加载失败时从 StreamCache 兜底。
  /// 在线播放场景建议传入；本地音乐场景可不传。
  final String? songId;

  const SmartArtworkImage({
    super.key,
    this.artworkUri,
    this.fallbackFilePath,
    required this.size,
    this.borderRadius = 8,
    this.songId,
  });

  @override
  State<SmartArtworkImage> createState() => _SmartArtworkImageState();
}

class _SmartArtworkImageState extends State<SmartArtworkImage> {
  // 断网/加载失败时从 StreamCache 兜底读到的封面字节
  Uint8List? _cachedArtworkBytes;
  bool _hasTriedCacheFallback = false;

  @override
  void initState() {
    super.initState();
    // 预检缓存：如果是 http 封面且有 songId，先查 StreamCache。
    // 命中则直接用 Image.memory，跳过 Image.network 网络请求，
    // 避免断网时大量并发 SocketException 闪现。
    _prefetchCachedArtwork();
  }

  @override
  void didUpdateWidget(covariant SmartArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // songId 变化时重新预查缓存（列表项复用场景）
    if (widget.songId != oldWidget.songId) {
      _cachedArtworkBytes = null;
      _hasTriedCacheFallback = false;
      _prefetchCachedArtwork();
    }
  }

  Future<void> _prefetchCachedArtwork() async {
    if (widget.songId == null || widget.songId!.isEmpty) return;
    final uri = widget.artworkUri;
    // artworkUri 为 null（云盘歌曲封面内嵌、无 URL）或 http(s) 封面时，
    // 尝试从 StreamCache 读取已缓存封面（云盘歌曲播放时提取的内嵌封面）。
    // 其余类型（local:// / content:// 等）走各自的本地加载逻辑，不查缓存。
    if (uri != null && !uri.startsWith('http://') && !uri.startsWith('https://')) {
      return;
    }
    try {
      final bytes =
          await StreamCacheManager.instance.getCachedArtwork(widget.songId!);
      if (bytes != null && mounted) {
        setState(() {
          _cachedArtworkBytes = bytes;
        });
      }
    } catch (_) {
      // 预查失败静默处理，后续走 Image.network 正常流程
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final uri = widget.artworkUri;

    Widget child;
    if (uri == null) {
      // 云盘歌曲封面内嵌、无 URL：优先显示 StreamCache 已缓存封面
      // （播放/缓存过歌曲后，SmartArtworkImage 预查缓存拿到了字节）
      if (_cachedArtworkBytes != null) {
        child = Image.memory(
          _cachedArtworkBytes!,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
        );
      } else if (widget.fallbackFilePath != null) {
        // URI 为空时，尝试用 fallbackFilePath 读内嵌封面
        child = LocalArtworkImage(
          filePath: widget.fallbackFilePath!,
          size: widget.size,
          borderRadius: widget.borderRadius,
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: child,
        );
      } else {
        child = _placeholder(colorScheme);
      }
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
      // 如果已经从缓存兜底拿到了字节，直接用 Image.memory 显示
      if (_cachedArtworkBytes != null) {
        child = Image.memory(
          _cachedArtworkBytes!,
          width: isFill ? double.infinity : widget.size,
          height: isFill ? double.infinity : widget.size,
          fit: BoxFit.cover,
        );
      } else {
        child = Image.network(
          uri,
          width: isFill ? double.infinity : widget.size,
          height: isFill ? double.infinity : widget.size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) {
            // 在线加载失败：先尝试 StreamCache 兜底，再退到 fallbackFilePath / 占位符
            if (!_hasTriedCacheFallback) {
              _hasTriedCacheFallback = true;
              _loadArtworkFromStreamCache();
            }
            if (_cachedArtworkBytes != null) {
              return Image.memory(
                _cachedArtworkBytes!,
                width: isFill ? double.infinity : widget.size,
                height: isFill ? double.infinity : widget.size,
                fit: BoxFit.cover,
              );
            }
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
      }
    } else if (uri.startsWith('file://')) {
      // file:// 本地文件（云盘提取的内嵌封面等）
      final isFill = widget.size == double.infinity;
      final file = File.fromUri(Uri.parse(uri));
      if (file.existsSync()) {
        child = Image.file(
          file,
          width: isFill ? double.infinity : widget.size,
          height: isFill ? double.infinity : widget.size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(colorScheme),
        );
      } else {
        child = _placeholder(colorScheme);
      }
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

  /// 断网或在线加载失败时，从 StreamCache 兜底读取封面字节。
  /// 读取成功后触发重建，用 Image.memory 显示。
  Future<void> _loadArtworkFromStreamCache() async {
    if (widget.songId == null || widget.songId!.isEmpty) return;
    try {
      final bytes =
          await StreamCacheManager.instance.getCachedArtwork(widget.songId!);
      if (bytes != null && mounted) {
        setState(() {
          _cachedArtworkBytes = bytes;
        });
      }
    } catch (_) {
      // 兜底失败静默处理
    }
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
