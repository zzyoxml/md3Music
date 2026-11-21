import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

import '../core/services/local_artwork_cache.dart';
import '../core/utils/local_media_path.dart';
import '../providers/song_match_provider.dart';

/// 播放器专用封面图组件，支持所有 artworkUri 类型。
///
/// 与 [SmartArtworkImage] 的区别：
/// - 针对播放器场景优化：支持 [fit]、[isFill]、无固定尺寸的流式布局
/// - 支持 `content://`（MediaStore albumart）通过 fallbackFilePath 读内嵌封面
/// - 支持 `local://<filePath>` 通过 [LocalArtworkCache] 懒加载内嵌封面
/// - 支持 `file://` URI
/// - 支持 `http(s)://` 通过 [CachedNetworkImage] 加载（带磁盘缓存）
/// - `content://` 加载失败时，尝试用 `fallbackFilePath` 读取内嵌封面
/// - 本地音频（`local://` 与 `content://`）统一走 [normalizeLocalMediaPath] 归一
///   后再读内嵌封面，并共用同一套「单曲偏好在线封面」解析
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

  /// MD3Music fork v37：在线封面失败自愈重试（有界——同 URI 至多一次）。
  /// kugou 图床偶现抖动/超时时 CachedNetworkImage 一次失败即定格占位，
  /// 岛/锁屏走原生链没受影响，唯独 App 内一错到底。重试用换 Key 强制
  /// 重新 resolve（failed 请求不污染缓存），二连败维持占位至切歌。
  ///
  /// v40（第六轮审查 P0）：守卫从 widget.artworkUri 改为 [_requestedUri]——
  /// local:// + 在线匹配分支实际请求的是 http 匹配 URL，与 widget.artworkUri
  /// 恒不等导致重试永不触发；另把 Future.delayed 换成可取消的 Timer。
  static const int _maxHttpAttempts = 2;
  static const Duration _httpRetryDelay = Duration(milliseconds: 1600);
  String? _attemptUri;
  int _attempt = 0;
  bool _retryScheduled = false;
  Timer? _retryTimer;
  String? _requestedUri;

  void _noteUriChanged() {
    if (widget.artworkUri != _attemptUri) {
      _attemptUri = widget.artworkUri;
      _attempt = 0;
      _retryScheduled = false;
      _requestedUri = null;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  void _scheduleHttpRetry(String uri) {
    if (_retryScheduled || _attempt >= _maxHttpAttempts - 1) return;
    _retryScheduled = true;
    _retryTimer = Timer(_httpRetryDelay, () {
      _retryScheduled = false;
      if (!mounted || _requestedUri != uri) return;
      if (_attempt >= _maxHttpAttempts - 1) return;
      setState(() => _attempt++);
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    super.dispose();
  }

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
    _noteUriChanged();
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

  /// 归一化后的字符串是否真是本地文件形态（`content://` 等仍无法用 `dart:io` 读）。
  static bool _isReadableLocalPath(String path) =>
      !path.startsWith('content://') &&
      !path.startsWith('http://') &&
      !path.startsWith('https://');

  /// 本地音频封面：[内嵌封面 > 在线匹配封面 > 占位符]。
  ///
  /// [filePath] 必须是**归一化后的裸磁盘路径**（见 [normalizeLocalMediaPath]）——
  /// 匹配记录的键 `'local_<扫描期路径>'` 与库内 `Song.id` 同口径，播放期回写的
  /// `file://` 形态直接拼会查不到记录（「使用在线封面」开关对本地歌也因此失效）。
  Widget _buildForLocalAudio(
    BuildContext context,
    String filePath,
    int decodeWidth,
    Color bg,
    Color icon,
    double iSize,
  ) {
    // 这首歌自己的匹配记录：单曲偏好「使用在线封面」+ 兜底 URL
    // （matchedInfoForLocal 订阅匹配状态，匹配确认/偏好切换后自动重建）
    final matchInfo = matchedInfoForLocal(context, 'local_$filePath');
    final matchedUri = (matchInfo != null && matchInfo.isMatched)
        ? matchInfo.artworkUri
        : null;
    final hasMatchedUri = matchedUri != null && matchedUri.isNotEmpty;
    final preferOnlineCover = matchInfo != null &&
        matchInfo.isMatched &&
        matchInfo.preferOnlineCover &&
        hasMatchedUri;
    if (!_embeddedLoaded) {
      _loadEmbedded(filePath);
    }
    // 偏好开启时跳过内嵌显示（内嵌仍提取，供在线失败时回落）
    if (!preferOnlineCover && _embeddedBytes != null) {
      return Image.memory(
        _embeddedBytes!,
        width: widget.isFill ? double.infinity : null,
        height: widget.isFill ? double.infinity : null,
        fit: widget.fit,
        cacheWidth: decodeWidth,
      );
    }
    // 内嵌封面缺失或偏好在线：用匹配到的在线封面
    if (hasMatchedUri) {
      _requestedUri = matchedUri;
      return CachedNetworkImage(
        key: ValueKey('matched:$matchedUri#${_attempt}'),
        imageUrl: matchedUri,
        width: widget.isFill ? double.infinity : null,
        height: widget.isFill ? double.infinity : null,
        fit: widget.fit,
        memCacheWidth: decodeWidth,
        placeholder: (_, _) => _placeholder(bg, icon, iSize),
        errorWidget: (_, _, _) {
          // 在线封面加载失败：核对一次（同 URI 至多一次重试），再失败回落内嵌
          _scheduleHttpRetry(matchedUri);
          if (_embeddedBytes != null) {
            return Image.memory(
              _embeddedBytes!,
              width: widget.isFill ? double.infinity : null,
              height: widget.isFill ? double.infinity : null,
              fit: widget.fit,
              cacheWidth: decodeWidth,
            );
          }
          return _placeholder(bg, icon, iSize);
        },
      );
    }
    return _placeholder(bg, icon, iSize);
  }

  /// 解码档位（物理像素宽）。
  ///
  /// 量化到固定档位而非用精确显示宽度：同一张封面常被同屏的多个
  /// [PlayerArtworkImage] 以不同尺寸渲染（如方形封面与全屏模糊底），精确宽度
  /// 会让它们落到不同的 `ResizeImage` cache key 上，同一封面被重复取数、重复
  /// 解码（本仓有回归测试钉住「同一封面只应有一条图片取数路径」）。相邻尺寸
  /// 归入同档后共用同一份解码结果，又不会明显过解。
  static const List<int> _decodeTiers = <int>[128, 256, 384, 512, 768, 1024, 1440];

  static int _decodeTierFor(double physicalWidth) {
    for (final int tier in _decodeTiers) {
      if (physicalWidth <= tier) return tier;
    }
    return _decodeTiers.last;
  }

  /// 按显示尺寸解码：同一个组件既当几十像素的列表缩略图、又当全屏模糊底，
  /// 而封面源图常是 400×400 甚至更大——全尺寸解码会把内存带宽、切歌解码耗时
  /// 与全屏高斯模糊每帧的采样成本一起放大。
  ///
  /// 目标宽度 = 显示宽（逻辑像素）× devicePixelRatio。`cacheWidth` /
  /// `memCacheWidth` 底层都是 [ResizeImage]，默认 `allowUpscaling = false`：
  /// 源图小于目标时保持原尺寸，不会放大解码，故上限取宽松值也不会浪费
  /// （对齐 [SmartArtworkImage] 与 `AppBackground` 的既有做法）。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double dpr = MediaQuery.devicePixelRatioOf(context);
        // 无界约束（如 Row 里的裸子项）退回屏幕宽度：宁可按大解，
        // 也不能按 0 解（ResizeImage 的目标为 0 会解出空图）。
        final double logicalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return _buildArtwork(context, _decodeTierFor(logicalWidth * dpr));
      },
    );
  }

  Widget _buildArtwork(BuildContext context, int decodeWidth) {
    // 在线封面自愈重试：URI 变化经此统一重置（didUpdateWidget 之外兜底）
    _noteUriChanged();
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
          cacheWidth: decodeWidth,
        );
      }
      return _placeholder(bg, icon, iSize);
    }

    // 本地音频：`local://<path>`（库内标识）或 `content://`（MediaStore albumart
    // 封面 URI，只能靠 fallbackFilePath 里的音频文件读内嵌封面）。
    //
    // 两条分支共用 [_buildForLocalAudio]：此前 `content://` 分支既不归一
    // `filePath`（播放解析会把 localPath 回写成 `file://`，`File()` 读不到 →
    // 播放页恒为占位符，而列表因用曲库对象所以正常），也不查匹配偏好
    // （「使用在线封面」开关对这类歌完全无效）。两处行为分叉正是本 bug 的两个面。
    if (uri.startsWith('local://') || uri.startsWith('content://')) {
      final rawPath = uri.startsWith('local://')
          ? uri.substring('local://'.length)
          : widget.fallbackFilePath;
      final filePath = normalizeLocalMediaPath(rawPath);
      if (filePath == null || !_isReadableLocalPath(filePath)) {
        // `content://` 且没有可用的音频文件路径（如扫描期 resolveLocalPath 就失败）：
        // 无内嵌封面可读，也没有在线封面可退——保持占位符。
        return _placeholder(bg, icon, iSize);
      }
      return _buildForLocalAudio(
        context,
        filePath,
        decodeWidth,
        bg,
        icon,
        iSize,
      );
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
          cacheWidth: decodeWidth,
          errorBuilder: (_, _, _) => _placeholder(bg, icon, iSize),
        );
      }
      // 文件不存在：尝试 fallbackFilePath 读内嵌封面，否则占位符
      if (widget.fallbackFilePath != null && !_embeddedLoaded) {
        _loadEmbedded(widget.fallbackFilePath!);
      }
      if (_embeddedBytes != null) {
        return Image.memory(_embeddedBytes!,
            fit: widget.fit, cacheWidth: decodeWidth);
      }
      return _placeholder(bg, icon, iSize);
    }

    // content:// URI：已在上面的「本地音频」分支与 local:// 合并处理
    // （靠 fallbackFilePath 读内嵌封面 + 匹配偏好），此处不再单独分支。

    // http(s):// 在线封面：用 CachedNetworkImage（带磁盘缓存）
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      _requestedUri = uri;
      return CachedNetworkImage(
        // v37：自愈重试——失败换 Key 重新 resolve（网络失败不入缓存）
        key: ValueKey('net:$uri#${_attempt}'),
        imageUrl: uri,
        width: widget.isFill ? double.infinity : null,
        height: widget.isFill ? double.infinity : null,
        fit: widget.fit,
        memCacheWidth: decodeWidth,
        placeholder: (_, _) => _placeholder(bg, icon, iSize),
        errorWidget: (_, _, _) {
          _scheduleHttpRetry(uri);
          return _placeholder(bg, icon, iSize);
        },
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
    preloadArtworkImage(CachedNetworkImageProvider(url));
  }
}

/// 预热封面时始终监听ImageStream，网络/解码失败属于可回退的封面错误，
/// 不应作为未处理的Flutter异步错误上抛。
@visibleForTesting
void preloadArtworkImage(ImageProvider<Object> provider) {
  try {
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    void removeListener() => stream.removeListener(listener);
    listener = ImageStreamListener(
      (_, _) => removeListener(),
      onError: (_, _) => removeListener(),
    );
    stream.addListener(listener);
  } catch (_) {
    // resolve失败与ImageStream失败同样不影响当前播放器或占位图。
  }
}

/// ── 飞行封面的 GPU 纹理预热（真机定案的「笔 A」）───────────────────────────
///
/// **要治的是什么**：mini→full 封面形变的最坏帧里，GPU 位有 12~18ms 花在
/// 「大图第一次进 display list 时上传纹理」。第三、四轮拿阴影高斯模糊做过离屏预热并
/// 实测**无效**（`worst` 的 GPU 位原地不动），从而排除了「首次编译着色器」这一半——
/// 剩下的唯一可能就是上传本身。
///
/// **为什么必须真的画一次**：上传按 `ui.Image` 对象发生。`precacheImage` 与
/// [preloadPlayerArtwork] 都只把**解码结果**放进缓存，纹理要等第一次被栅格化引用时才
/// 创建——而那正好落在转场里的那一帧。
///
/// **缓存键必须与飞行层逐位相同**，否则只是白解第二份大图：飞行层是
/// [PlayerArtworkImage] 在 settled 宽度的盒子里渲染，宽度先经 [_decodeTierFor] 量化成
/// 档位，再交给 `CachedNetworkImage(memCacheWidth: tier)`；而 octo_image 内部把这个参数
/// 落成 `ResizeImage.resizeIfNeeded(memCacheWidth, memCacheHeight, provider)`
/// （`octo_image-2.1.2/lib/src/image/image.dart:203`）。所以这里复用**同一个工厂**，
/// 不手搓 `ResizeImage(...)`——上游改默认值时键会悄悄变掉，而键一变就等于没预热。
///
/// **只覆盖 http(s):// 与 file://**：`local://` / `content://` 的内嵌封面由
/// [PlayerArtworkImage] 的 State 异步提取字节，外部拿不到同一份 bytes，凑不出同一个
/// `MemoryImage` 键——宁可不预热，也不要解一份不同键的大图。
///
/// 返回值是**一行可直接进日志的状态**。上一轮阴影预热静默执行，判「无效」时连它到底
/// 跑没跑都没有证据（AGENTS 第 0 节第 1 条：判定必须以日志为准），这次把成败与原因都吐出来。
Future<String> prewarmPlayerArtworkTexture({
  required String? artworkUri,
  required double settledLogicalWidth,
  required double devicePixelRatio,
}) async {
  final uri = artworkUri;
  if (uri == null || uri.isEmpty) return 'skip:no-uri';
  final provider = coverPrewarmProviderFor(
    artworkUri: uri,
    settledLogicalWidth: settledLogicalWidth,
    devicePixelRatio: devicePixelRatio,
  );
  if (provider == null) {
    // 剩下的两种可能：源类型不支持（内嵌封面），或 file:// 指向的文件不存在。
    final supported = uri.startsWith('http://') ||
        uri.startsWith('https://') ||
        uri.startsWith('file://');
    return supported ? 'skip:file-missing' : 'skip:embedded-source';
  }
  ui.Image? image;
  try {
    image = await _resolveCoverImage(provider);
  } catch (e) {
    return 'fail:resolve $e';
  }
  if (image == null) return 'fail:resolve-empty';
  try {
    // 离屏画一次就够：dst 只要有一小块落在渲染目标内就不会被裁掉，源纹理整张上传；
    // 渲染目标只开 64×64，别为了预热再占一张全尺寸的中间图。
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(image, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    final offscreen = await picture.toImage(64, 64);
    picture.dispose();
    offscreen.dispose();
    // 源 `ui.Image` 属于图片缓存，**不 dispose**：飞行层随后要用的就是它。
    return 'ok tier=${_coverPrewarmTier(uri, settledLogicalWidth, devicePixelRatio)}'
        ' src=${image.width}x${image.height}';
  } catch (e) {
    return 'fail:upload $e';
  }
}

/// 与飞行层同一缓存键的封面 provider；不该预热时返回 null（判据见
/// [prewarmPlayerArtworkTexture] 的说明）。
///
/// 单独拆出来是为了能被测试直接钉住「键是不是同一个」——这是整条预热唯一的前提，
/// 靠读日志反推要等一轮真机。
@visibleForTesting
ImageProvider<Object>? coverPrewarmProviderFor({
  required String? artworkUri,
  required double settledLogicalWidth,
  required double devicePixelRatio,
}) {
  final uri = artworkUri;
  if (uri == null || uri.isEmpty) return null;
  if (uri.startsWith('http://') || uri.startsWith('https://')) {
    return ResizeImage.resizeIfNeeded(
      _coverPrewarmTier(uri, settledLogicalWidth, devicePixelRatio),
      null,
      CachedNetworkImageProvider(uri),
    );
  }
  if (uri.startsWith('file://')) {
    final file = File.fromUri(Uri.parse(uri));
    if (!file.existsSync()) return null;
    return ResizeImage.resizeIfNeeded(
      _coverPrewarmTier(uri, settledLogicalWidth, devicePixelRatio),
      null,
      FileImage(file),
    );
  }
  return null;
}

/// 飞行层那一档的解码宽度：与 [PlayerArtworkImage] 的 LayoutBuilder 同式
/// （逻辑宽 × devicePixelRatio，再量化进 [_decodeTierFor]）。
int _coverPrewarmTier(String uri, double logicalWidth, double devicePixelRatio) {
  final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  // dpr 异常（0 / NaN / 负）时宁可按 1 解，也不能按 0 解出空图。
  final width = logicalWidth.isFinite && logicalWidth > 0 ? logicalWidth : 200.0;
  return _PlayerArtworkImageState._decodeTierFor(width * dpr);
}

/// 把 provider 解析成 `ui.Image`（成功）或 null（失败）。
///
/// 刻意**不设超时**：`Future.timeout` 会留下 pending Timer，把与本条线无关的
/// widget 测试判成失败（本仓踩过一次）。真机上 resolve 要么成功要么走 onError。
Future<ui.Image?> _resolveCoverImage(ImageProvider<Object> provider) {
  final completer = Completer<ui.Image?>();
  late final ImageStream stream;
  late final ImageStreamListener listener;
  void finish(ui.Image? image) {
    if (completer.isCompleted) return;
    stream.removeListener(listener);
    completer.complete(image);
  }

  stream = provider.resolve(const ImageConfiguration());
  listener = ImageStreamListener(
    (ImageInfo info, _) => finish(info.image),
    onError: (_, _) => finish(null),
  );
  stream.addListener(listener);
  return completer.future;
}

/// 封面是否已就绪（同键解码缓存命中，渲染首帧即有图）。
///
/// 与 [PlayerArtworkImage] 渲染**同键**：宽度经 [_decodeTierFor] 量化成档位后
/// 交给 `CachedNetworkImage(memCacheWidth: tier)`，octo_image 内部落成
/// `ResizeImage.resizeIfNeeded(tier, null, provider)`——所以这里复用同一个工厂
/// [coverPrewarmProviderFor] 解析，避免「探测一份、渲染另一份」的键漂移
/// （与 [prewarmPlayerArtworkTexture] 同源的理由；`CachedNetworkImageProvider
/// .obtainKey` 不读 configuration，空配置与渲染层的环境配置同键）。
///
/// 未命中时本次 resolve 即开始加载，完成时返回 true——顺带把解码结果放进缓存，
/// 渲染层随后同键命中，不会重复取数。
///
/// 内嵌封面（local://、content://）外部拿不到同一份字节，无法探测，按就绪返回
/// true（其读取走本地文件/Isolate，通常一帧内完成，由渲染层自行兜底）。
Future<bool> isPlayerArtworkReady({
  required String? artworkUri,
  required double settledLogicalWidth,
  required double devicePixelRatio,
}) async {
  final provider = coverPrewarmProviderFor(
    artworkUri: artworkUri,
    settledLogicalWidth: settledLogicalWidth,
    devicePixelRatio: devicePixelRatio,
  );
  // 探测不了的类型（内嵌封面 / 不存在的 file://）：按就绪处理。
  if (provider == null) return true;
  final image = await _resolveCoverImage(provider);
  return image != null;
}

/// 解析封面为 `ui.Image` 位图句柄（与渲染/预热**同键**，见
/// [coverPrewarmProviderFor]），供低分辨率模糊快照等二次加工使用。
///
/// 返回的位图属于图片缓存（[ImageStreamCompleter] 持有），调用方**不得**
/// `dispose`；用完 `image.dispose()` 会破坏缓存中其他消费者的引用计数。
/// 探测不了的源（内嵌封面 / file:// 缺失 / 解析失败）返回 null，
/// 调用方退回既有渲染路径。
Future<ui.Image?> resolvePlayerArtworkImage({
  required String? artworkUri,
  required double settledLogicalWidth,
  required double devicePixelRatio,
}) async {
  final provider = coverPrewarmProviderFor(
    artworkUri: artworkUri,
    settledLogicalWidth: settledLogicalWidth,
    devicePixelRatio: devicePixelRatio,
  );
  if (provider == null) return null;
  return _resolveCoverImage(provider);
}
