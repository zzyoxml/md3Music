import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/services/local_artwork_cache.dart';

/// 本地音乐封面图组件。
///
/// 通过 [LocalArtworkCache] 懒加载音频文件内嵌的封面图。
/// 首次显示时在 Isolate 中读取 metadata，后续从内存缓存获取。
class LocalArtworkImage extends StatefulWidget {
  final String filePath;
  final double size;
  final double borderRadius;

  const LocalArtworkImage({
    super.key,
    required this.filePath,
    required this.size,
    this.borderRadius = 8,
  });

  @override
  State<LocalArtworkImage> createState() => _LocalArtworkImageState();
}

class _LocalArtworkImageState extends State<LocalArtworkImage> {
  Uint8List? _bytes;
  bool _loaded = false;
  // 版本计数器：防止旧异步加载完成后覆盖新 filePath 的状态
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    _loadArtwork();
  }

  @override
  void didUpdateWidget(LocalArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // filePath 变化时（如搜索过滤导致列表项复用），重新加载封面
    if (oldWidget.filePath != widget.filePath) {
      _bytes = null;
      _loaded = false;
      _loadArtwork();
    }
  }

  Future<void> _loadArtwork() async {
    final currentVersion = ++_loadVersion;
    final result = await LocalArtworkCache().getArtwork(widget.filePath);
    // 仅当版本号匹配时才更新状态，丢弃过期的异步结果
    if (mounted && currentVersion == _loadVersion) {
      setState(() {
        _bytes = result;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFill = widget.size == double.infinity;

    if (_bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: Image.memory(
          _bytes!,
          width: isFill ? double.infinity : widget.size,
          height: isFill ? double.infinity : widget.size,
          fit: BoxFit.cover,
        ),
      );
    }

    // 加载中或无封面：显示占位符
    return Container(
      width: isFill ? double.infinity : widget.size,
      height: isFill ? double.infinity : widget.size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: Icon(
        _loaded ? Icons.music_note : Icons.hourglass_empty,
        size: isFill ? 40 : widget.size * 0.4,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 判断 artworkUri 是否为本地封面标识（`local://<filePath>`）。
bool isLocalArtwork(String? artworkUri) {
  return artworkUri != null && artworkUri.startsWith('local://');
}

/// 从 `local://<filePath>` 格式的 URI 中提取文件路径。
String? extractLocalPath(String artworkUri) {
  if (!artworkUri.startsWith('local://')) return null;
  return artworkUri.substring('local://'.length);
}
