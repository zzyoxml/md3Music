import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../core/services/local_artwork_cache.dart';
import '../core/utils/local_media_path.dart';
import '../providers/song_match_provider.dart';

/// 本地音乐封面图组件。
///
/// 通过 [LocalArtworkCache] 懒加载音频文件内嵌的封面图。
/// 首次显示时在 Isolate 中读取 metadata，后续从内存缓存获取。
///
/// 内嵌封面缺失时，若该本地歌曲已匹配在线歌曲（SongMatchProvider），
/// 自动改用在线封面兜底（优先级：内嵌封面 > 在线封面 > 占位符）。
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

    // 这首歌自己的匹配记录：单曲偏好「使用在线封面」优先于内嵌封面
    //
    // 键必须与库内 `Song.id`（`local_<扫描期裸路径>`）同口径：filePath 可能在
    // 播放解析后被回写成 `file://`+percent 编码形态，直接拼会查不到记录，
    // 表现为「匹配/偏好都对，列表封面却不换在线图」。
    final normalizedPath =
        normalizeLocalMediaPath(widget.filePath) ?? widget.filePath;
    final matchInfo = matchedInfoForLocal(context, 'local_$normalizedPath');
    final matchedUri = (matchInfo != null && matchInfo.isMatched)
        ? matchInfo.artworkUri
        : null;
    final hasMatchedUri = matchedUri != null && matchedUri.isNotEmpty;
    final preferOnlineCover = matchInfo != null &&
        matchInfo.isMatched &&
        matchInfo.preferOnlineCover &&
        hasMatchedUri;

    // 单曲偏好开启：直接渲染在线封面（在线失败时由 _onlineCover 回落内嵌）
    if (preferOnlineCover) {
      return _onlineCover(context, matchedUri, colorScheme);
    }

    if (_bytes != null) {
      // 缩略图解码：内嵌封面可能远大于显示尺寸（列表项仅 ~52px），
      // cacheWidth 参与 ImageCache key，同尺寸共享同一份解码结果。
      final decodeWidth = isFill
          ? null
          : (widget.size * MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(32, 480);
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: Image.memory(
          _bytes!,
          width: isFill ? double.infinity : widget.size,
          height: isFill ? double.infinity : widget.size,
          fit: BoxFit.cover,
          cacheWidth: decodeWidth,
        ),
      );
    }

    // 内嵌封面提取完成但为空：该歌曲已匹配在线歌曲时用在线封面兜底
    // （matchedInfoForLocal 订阅匹配状态，匹配确认后本组件自动重建）
    if (_loaded && _bytes == null && hasMatchedUri) {
      return _onlineCover(context, matchedUri, colorScheme);
    }

    // 加载中或无封面：显示占位符
    return _placeholder(colorScheme, loading: !_loaded);
  }

  /// 在线封面（匹配结果）：加载失败时回落内嵌封面（有则显示），再退占位符。
  Widget _onlineCover(
    BuildContext context,
    String uri,
    ColorScheme colorScheme,
  ) {
    final isFill = widget.size == double.infinity;
    final decodeWidth = isFill
        ? null
        : (widget.size * MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(32, 480);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Image.network(
        uri,
        width: isFill ? double.infinity : widget.size,
        height: isFill ? double.infinity : widget.size,
        fit: BoxFit.cover,
        cacheWidth: decodeWidth,
        // tv: 与 SmartArtworkImage 的网络封面同款 fadeIn（200ms 淡入，
        // 命中内存缓存不淡入），避免占位符到图片硬切突跳。
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: child,
          );
        },
        errorBuilder: (_, _, _) {
          if (_bytes != null) {
            return Image.memory(
              _bytes!,
              width: isFill ? double.infinity : widget.size,
              height: isFill ? double.infinity : widget.size,
              fit: BoxFit.cover,
              cacheWidth: decodeWidth,
            );
          }
          return _placeholder(colorScheme);
        },
      ),
    );
  }

  Widget _placeholder(ColorScheme colorScheme, {bool loading = false}) {
    final isFill = widget.size == double.infinity;
    return Container(
      width: isFill ? double.infinity : widget.size,
      height: isFill ? double.infinity : widget.size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: Icon(
        loading ? Icons.hourglass_empty : Icons.music_note,
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
