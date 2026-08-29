import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/services/local_artwork_cache.dart';

/// 播放器专用封面图组件，支持所有 artworkUri 类型。
///
/// 与 [SmartArtworkImage] 的区别：
/// - 针对播放器场景优化：支持 [fit]、[isFill]、无固定尺寸的流式布局
/// - 支持 `content://`（MediaStore albumart）通过 fallbackFilePath 读内嵌封面
/// - 支持 `local://<filePath>` 通过 [LocalArtworkCache] 懒加载内嵌封面
/// - 支持 `file://` URI
/// - 支持 `http(s)://` 通过 [CachedNetworkImage] 加载（带磁盘缓存）
/// - `content://` 加载失败时，尝试用 `fallbackFilePath` 读取内嵌封面
class PlayerArtworkImage extends StatefulWidget {
  /// 封面 URI，支持 http(s):// / content:// / local:// / file:// / null
  final String? artworkUri;

  /// 当 artworkUri 为 content:// 加载失败时的回退文件路径
  final String? fallbackFilePath;

  /// BoxFit，默认 [BoxFit.cover]
  final BoxFit fit;

  /// 是否填充父容器（不指定固定尺寸）
  final bool isFill;

  /// 占位符 icon 大小
  final double? iconSize;

  /// 背景色（加载中/无封面时）
  final Color? backgroundColor;

  /// icon 颜色
  final Color? iconColor;

  const PlayerArtworkImage({
    super.key,
    required this.artworkUri,
    this.fallbackFilePath,
    this.fit = BoxFit.cover,
    this.isFill = false,
    this.iconSize,
    this.backgroundColor,
    this.iconColor,
  });

  @override
  State<PlayerArtworkImage> createState() => _PlayerArtworkImageState();
}

class _PlayerArtworkImageState extends State<PlayerArtworkImage> {
  /// 内嵌封面字节（仅 local:// 和 fallback 时使用）
  Uint8List? _embeddedBytes;
  bool _embeddedLoaded = false;
  /// 版本计数器：防止旧异步加载完成后覆盖新 URI 的状态
  int _loadVersion = 0;
  /// 当前正在加载的文件路径，避免重复加载同一文件
  String? _loadingPath;

  @override
  void didUpdateWidget(PlayerArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // artworkUri 或 fallbackFilePath 变化时重置内嵌封面状态
    if (oldWidget.artworkUri != widget.artworkUri ||
        oldWidget.fallbackFilePath != widget.fallbackFilePath) {
      _embeddedBytes = null;
      _embeddedLoaded = false;
      _loadingPath = null;
    }
  }

  /// 从文件路径读取内嵌封面
  Future<void> _loadEmbedded(String filePath) async {
    // 避免重复加载同一文件
    if (_loadingPath == filePath && _embeddedLoaded) return;
    _loadingPath = filePath;
    final currentVersion = ++_loadVersion;
    final result = await LocalArtworkCache().getArtwork(filePath);
    // 仅当版本号匹配时才更新状态，丢弃过期的异步结果
    if (mounted && currentVersion == _loadVersion) {
      setState(() {
        _embeddedBytes = result;
        _embeddedLoaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uri = widget.artworkUri;
    final bg = widget.backgroundColor ?? cs.surfaceContainerHighest;
    final icon = widget.iconColor ?? cs.onSurfaceVariant;
    final iSize = widget.iconSize ?? 48;

    // 无 URI：尝试用 fallbackFilePath 读内嵌封面，否则显示占位符
    if (uri == null || uri.isEmpty) {
      if (widget.fallbackFilePath != null && !_embeddedLoaded) {
        _loadEmbedded(widget.fallbackFilePath!);
      }
      if (_embeddedBytes != null) {
        return Image.memory(
          _embeddedBytes!,
          width: widget.isFill ? double.infinity : null,
          height: widget.isFill ? double.infinity : null,
          fit: widget.fit,
        );
      }
      return _placeholder(bg, icon, iSize);
    }

    // local:// 前缀：从文件路径读取内嵌封面
    if (uri.startsWith('local://')) {
      final filePath = uri.substring('local://'.length);
      if (!_embeddedLoaded) {
        _loadEmbedded(filePath);
      }
      if (_embeddedBytes != null) {
        return Image.memory(
          _embeddedBytes!,
          width: widget.isFill ? double.infinity : null,
          height: widget.isFill ? double.infinity : null,
          fit: widget.fit,
        );
      }
      return _placeholder(bg, icon, iSize);
    }

    // file:// URI：直接读本地文件（云盘提取的内嵌封面等场景）
    if (uri.startsWith('file://')) {
      final file = File.fromUri(Uri.parse(uri));
      if (file.existsSync()) {
        return Image.file(
          file,
          width: widget.isFill ? double.infinity : null,
          height: widget.isFill ? double.infinity : null,
          fit: widget.fit,
          errorBuilder: (_, _, _) => _placeholder(bg, icon, iSize),
        );
      }
      // 文件不存在：尝试 fallbackFilePath 读内嵌封面，否则占位符
      if (widget.fallbackFilePath != null && !_embeddedLoaded) {
        _loadEmbedded(widget.fallbackFilePath!);
      }
      if (_embeddedBytes != null) {
        return Image.memory(_embeddedBytes!, fit: widget.fit);
      }
      return _placeholder(bg, icon, iSize);
    }

    // content:// URI：Image.network 无法加载（非 HTTP 协议），
    // 直接用 fallbackFilePath 走 LocalArtworkImage 懒加载内嵌封面
    if (uri.startsWith('content://')) {
      if (widget.fallbackFilePath != null) {
        if (!_embeddedLoaded) {
          _loadEmbedded(widget.fallbackFilePath!);
        }
        if (_embeddedBytes != null) {
          return Image.memory(
            _embeddedBytes!,
            width: widget.isFill ? double.infinity : null,
            height: widget.isFill ? double.infinity : null,
            fit: widget.fit,
          );
        }
        return _placeholder(bg, icon, iSize);
      }
      return _placeholder(bg, icon, iSize);
    }

    // http(s):// 在线封面：用 CachedNetworkImage（带磁盘缓存）
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: uri,
        width: widget.isFill ? double.infinity : null,
        height: widget.isFill ? double.infinity : null,
        fit: widget.fit,
        placeholder: (_, _) => _placeholder(bg, icon, iSize),
        errorWidget: (_, _, _) => _placeholder(bg, icon, iSize),
      );
    }

    // 兜底
    return _placeholder(bg, icon, iSize);
  }

  Widget _placeholder(Color bg, Color icon, double iconSize) {
    return Container(
      width: widget.isFill ? double.infinity : null,
      height: widget.isFill ? double.infinity : null,
      color: bg,
      child: Center(
        child: Icon(Icons.music_note, size: iconSize, color: icon),
      ),
    );
  }
}

/// 预加载封面到 CachedNetworkImage 的磁盘缓存。
///
/// 用于播放器切歌前预加载下一首封面，减少切换白屏。
/// 仅对 http(s):// 有效，本地封面无需预加载。
void preloadPlayerArtwork(String? url) {
  if (url == null || url.isEmpty) return;
  if (url.startsWith('http://') || url.startsWith('https://')) {
    CachedNetworkImageProvider(url).resolve(const ImageConfiguration());
  }
}
