import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/platform_capabilities.dart';
import '../../core/services/usb_audio_service.dart';
import '../../core/utils/audio_format_utils.dart';
import '../../core/utils/audio_scanner.dart' show audioExtensions;
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/player_provider.dart';
import '../../providers/song_match_provider.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/usb_exclusive_section.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../library/song_match_sheet.dart';
import '../sheet/song_sheet_sheet.dart';
import 'comments_view.dart';
import 'song_accompany_sheet.dart';
import 'song_ranking_sheet.dart';

/// 歌曲信息页：展示当前播放歌曲的音频格式（采样频率/位深/码率/声道）与
/// USB 独占输出开关（与设置页共用同一 [UsbExclusiveSection]，信息保持一致）。
///
/// Android 使用 ExoPlayer 源格式/解码遥测；Windows 使用当前播放项的音轨属性。
/// FLAC/WAV 文件头可补充原始位深，不把系统混音器格式当作歌曲属性。
///
/// 平台可见性：USB 独占相关内容（页尾开关区块 + 解码输出/USB 输出两行遥测）只在
/// [supportsUsbExclusive] 为真时渲染 —— 即仅 Android 手机；桌面端与 TV 构建没有
/// USB Host 原生插件（TV 的 `FEATURE_TV` 不注册 UsbAudioPlugin），整块隐藏，
/// 避免出现点不动、也永远没有数据的死 UI。
class SongInfoPage extends StatefulWidget {
  const SongInfoPage({super.key});

  @override
  State<SongInfoPage> createState() => _SongInfoPageState();
}

class _SongInfoPageState extends State<SongInfoPage> {
  Map<String, dynamic> _status = const {};

  /// 当前曲目的源格式（TrackGroup，含歌曲原始采样率/码率/声道），null=尚未获取。
  Map<String, dynamic>? _sourceFormat;

  /// 从音频文件头解析的原始位深（FLAC/WAV），null=未知。
  int? _headerBitDepth;

  /// 文件大小（字节），null=暂无数据。获取成功后不再重复请求（文件大小恒定）。
  int? _fileSizeBytes;
  bool _fileSizeResolved = false;
  Timer? _fileSizeTimer;
  String? _sourceSongId;
  int _sourceFormatRequest = 0;
  bool _sourceFormatLoading = false;

  @override
  void initState() {
    super.initState();
    // USB 遥测只在支持 USB 独占的平台上有数据源（桌面端/TV 无原生插件通道，
    // 调用只会抛 MissingPluginException 被吞掉），故整体按能力门控。
    if (supportsUsbExclusive) {
      _status = UsbAudioService.instance.lastStatus;
      UsbAudioService.instance.statusStream.listen((s) {
        if (mounted) setState(() => _status = s);
      });
      // 兜底 c：页面可见时主动查一次（覆盖原生事件未推送的边界场景）
      UsbAudioService.instance.refresh();
    }
    // 每秒刷新一次文件大小
    _fileSizeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshFileSize();
      // Windows 装载尚未完成时没有音轨信息，页面保持打开也需在就绪后补取。
      if (isWindowsDesktop && !_sourceFormatLoading &&
          _sourceFormat?['hasData'] != true) {
        _refreshSourceFormat();
      }
    });
  }

  @override
  void dispose() {
    _fileSizeTimer?.cancel();
    super.dispose();
  }

  /// 每秒刷新文件大小。文件大小恒定，获取成功后即停（_fileSizeResolved）。
  Future<void> _refreshFileSize() async {
    if (_fileSizeResolved) return;
    final songId = _sourceSongId;
    try {
      final size = await _resolveFileSize();
      if (mounted && songId == _sourceSongId &&
          size != null && size != _fileSizeBytes) {
        setState(() {
          _fileSizeBytes = size;
          _fileSizeResolved = true;
        });
      }
    } catch (_) {
      // 静默
    }
  }

  /// 解析当前歌曲文件大小，优先级：
  /// 本地文件（裸路径或 file:// URI）→ 网络 HEAD Content-Length → 传输统计（已下载字节）兜底。
  Future<int?> _resolveFileSize() async {
    final playerProvider = context.read<PlayerProvider>();
    final song = playerProvider.currentSong;
    final local = song?.localPath;
    final url = song?.url;

    // 1) 本地文件：localPath 可能是裸路径、file:// URI 或 http URL（在线歌曲播放时被覆写）
    String? path;
    if (local != null && local.isNotEmpty) {
      if (local.startsWith('file://')) {
        path = Uri.parse(local).toFilePath();
      } else if (local.startsWith('/') || (isWindowsDesktop &&
          (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(local) || local.startsWith(r'\\')))) {
        path = local;
      }
    }
    if (path != null) {
      final f = File(path);
      if (await f.exists()) return await f.length();
    }
    // 2) url 指向本地文件
    if (url != null && url.startsWith('file://')) {
      final f = File(Uri.parse(url).toFilePath());
      if (await f.exists()) return await f.length();
    }
    // 3) 网络歌曲：HEAD 请求拿 Content-Length（文件真实大小）
    if (url != null && (url.startsWith('http://') || url.startsWith('https://'))) {
      try {
        final resp = await http
            .head(Uri.parse(url))
            .timeout(const Duration(seconds: 4));
        final len = int.tryParse(resp.headers['content-length'] ?? '');
        if (resp.statusCode >= 200 && resp.statusCode < 300 && len != null && len > 0) {
          return len;
        }
      } catch (_) {}
    }
    // 4) 兜底：传输统计（已下载字节）
    final player = playerProvider.audioService?.player;
    if (player != null) {
      final stats = await player.getTransferStats();
      final b = (stats?['totalBytes'] as num?)?.toInt() ?? 0;
      if (b > 0) return b;
    }
    return null;
  }

  /// Android 读取 TrackGroup，Windows 读取当前播放项；文件头补充原始位深。
  Future<void> _refreshSourceFormat() async {
    final player = context.read<PlayerProvider>().audioService?.player;
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return;
    final request = ++_sourceFormatRequest;
    _sourceFormatLoading = true;
    Map<String, dynamic>? fmt;
    if (player != null) {
      fmt = await player.getSourceFormat();
    }
    final headerBits = await _parseHeaderBitDepth(song.url, song.localPath);
    if (mounted && request == _sourceFormatRequest &&
        song.id == context.read<PlayerProvider>().currentSong?.id) {
      setState(() {
        _sourceFormat = fmt;
        _headerBitDepth = headerBits;
        _sourceFormatLoading = false;
      });
    }
  }

  /// 解析音频文件头（FLAC STREAMINFO / WAV fmt chunk）获取原始位深。
  /// 实现统一收敛到 [AudioFormatUtils]，与 USB 独占格式链共用同一逻辑。
  Future<int?> _parseHeaderBitDepth(String? url, String? localPath) =>
      AudioFormatUtils.parseAudioBitDepth(url, localPath);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final playerProvider = context.watch<PlayerProvider>();
    final song = playerProvider.currentSong;

    // 切歌后异步拉取源格式（以歌曲 id 去重，避免重复请求）
    if (song?.id != _sourceSongId) {
      _sourceSongId = song?.id;
      if (isWindowsDesktop) {
        ++_sourceFormatRequest;
        _sourceFormat = null;
        _headerBitDepth = null;
        _sourceFormatLoading = false;
      }
      _fileSizeBytes = null;  // 换歌重置
      _fileSizeResolved = false;
      _refreshSourceFormat();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('歌曲信息')),
      body: ListView(
        children: [
          _buildSongHeader(song, colorScheme, textTheme),
          // 本地/云盘歌曲：在线信息（匹配记忆 / 专辑 / 歌手 / 评论入口）
          if (song != null && (!song.isOnline || song.isCloud)) ...[
            const SizedBox(height: 8),
            _buildSectionHeader('在线信息'),
            _buildOnlineMatchCard(song, colorScheme),
          ],
          const SizedBox(height: 8),
          _buildSectionHeader('音频格式'),
          _buildFormatCard(colorScheme),
          // USB 独占：依赖 Android USB Host + native cpp（UAC1 DAC 直写 usbdevfs）。
          // supportsUsbExclusive 已排除桌面端与 TV 构建（TV 不注册原生插件），
          // 因此这里只剩 Android 手机可见；与设置页「USB 独占」共用同一组件，
          // 两处信息与开关必然一致（见 docs/agents/troubleshooting.md §4.11）。
          if (supportsUsbExclusive) ...[
            const SizedBox(height: 8),
            _buildSectionHeader('USB 独占'),
            UsbExclusiveSection(
              onAutoPause: () => context.read<PlayerProvider>().pause(),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  /// 本地/云盘歌曲的在线信息卡：已匹配展示专辑/歌手（可跳详情页）+ 评论/管理入口；
  /// 未匹配给出引导与「去匹配」。
  Widget _buildOnlineMatchCard(Song song, ColorScheme colorScheme) {
    final textTheme = Theme.of(context).textTheme;
    return Consumer<SongMatchProvider>(
      builder: (ctx, match, _) {
        final matchedSong = match.matchedSongFor(song);
        final isMatched = matchedSong != null;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              if (!isMatched)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '匹配在线歌曲后可查看评论区、补充封面与歌词',
                      style: textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              else ...[
                ListTile(
                  leading: const Icon(Icons.album_outlined),
                  title: const Text('专辑'),
                  subtitle: Text(
                    matchedSong.album.isEmpty ? '—' : matchedSong.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: matchedSong.albumId == null ||
                          matchedSong.albumId!.isEmpty
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AlbumDetailPage(
                                album: Album(
                                  id: matchedSong.albumId!,
                                  name: matchedSong.album,
                                  artist: matchedSong.artist,
                                  artworkUri: matchedSong.artworkUri,
                                  songCount: 0,
                                ),
                              ),
                            ),
                          );
                        },
                ),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('歌手'),
                  subtitle: Text(
                    matchedSong.artist.isEmpty ? '—' : matchedSong.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: matchedSong.artistId == null ||
                          matchedSong.artistId!.isEmpty
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ArtistDetailPage(
                                artistId: matchedSong.artistId!,
                                artistName: matchedSong.artist,
                              ),
                            ),
                          );
                        },
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (isMatched)
                      TextButton(
                        onPressed: () =>
                            showSongRankingSheet(context, matchedSong),
                        child: const Text('看成绩单'),
                      ),
                    if (isMatched &&
                        SettingsRepository.accompanyFeatureEnabled.value)
                      TextButton(
                        onPressed: () =>
                            showSongAccompanySheet(context, matchedSong),
                        child: const Text('获取伴奏'),
                      ),
                    if (isMatched)
                      TextButton(
                        onPressed: () =>
                            showSongSheetSheet(context, matchedSong),
                        child: const Text('看曲谱'),
                      ),
                    if (isMatched)
                      TextButton(
                        onPressed: () =>
                            showSongCommentsSheet(context, song),
                        child: const Text('看评论'),
                      ),
                    TextButton(
                      onPressed: () => showSongMatchSheet(context, song),
                      child: Text(isMatched ? '管理匹配' : '去匹配'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 去掉标题末尾的音频文件后缀（如 .flac/.mp3）。仅当确实以已知音频扩展名结尾才剥离。
  String _stripAudioExtension(String title) {
    final lower = title.toLowerCase();
    for (final ext in audioExtensions) {
      if (lower.endsWith(ext) && title.length > ext.length) {
        return title.substring(0, title.length - ext.length);
      }
    }
    return title;
  }

  Widget _buildSongHeader(
      Song? song, ColorScheme colorScheme, TextTheme textTheme) {
    // 去掉文件名后缀：仅当标题以音频扩展名结尾才剥离，避免误伤合法带点的标题
    final title = _stripAudioExtension(song?.title ?? '未在播放');
    final artist = song?.artist ?? '—';
    final artUrl = song?.artworkUri;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 64,
              height: 64,
              child: artUrl != null
                  ? PlayerArtworkImage(artworkUri: artUrl, isFill: true)
                  : Container(
                      color: colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.music_note, size: 28),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(artist,
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatCard(ColorScheme colorScheme) {
    final textTheme = Theme.of(context).textTheme;
    final src = _sourceFormat;
    final hasSrc = src != null && (src['hasData'] == true);

    // 源格式（歌曲原始属性，来自 ExoPlayer TrackGroup）
    final srcRate = hasSrc ? ((src['sampleRate'] as num?)?.toInt() ?? 0) : 0;
    final srcCh = hasSrc ? ((src['channelCount'] as num?)?.toInt() ?? 0) : 0;
    final srcPcmEnc = hasSrc ? ((src['pcmEncoding'] as num?)?.toInt() ?? 0) : 0;
    // 位深权威来源：音频文件头解析（FLAC/WAV 原始位深）
    final srcBits = _headerBitDepth ?? (isWindowsDesktop && hasSrc
        ? ((src['bitsPerSample'] as num?)?.toInt() ?? 0) : 0);

    // 回退：解码输出格式（未拿到源格式时）
    final decRate = (_status['lastSampleRate'] as num?)?.toInt() ?? 0;
    final decCh = (_status['lastChannelCount'] as num?)?.toInt() ?? 0;
    final decEnc = (_status['lastEncoding'] as num?)?.toInt() ?? 2;

    final hasData = hasSrc || decRate > 0;
    final rate = srcRate > 0 ? srcRate : decRate;
    final ch = srcCh > 0 ? srcCh : decCh;

    // 位深优先级：源 bitsPerSample > 源 pcmEncoding > 解码输出
    final bits = srcBits > 0
        ? srcBits
        : (isWindowsDesktop ? 0
            : (srcPcmEnc > 0 ? _encodingBits(srcPcmEnc) : _encodingBits(decEnc)));

    // USB 实际输出位深（独占开启时有效）
    final dacBits = (_status['dacBitDepth'] as num?)?.toInt() ?? 0;
    // 独占开启时音频直写 DAC，解码输出格式无意义 → 隐藏"解码输出"行
    final exclusiveEnabled = (_status['enabled'] as bool?) ?? false;

    // 文件大小：每秒刷新（网络=已下载字节，本地=文件大小）
    final fileSize = _fileSizeBytes;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _buildFormatRow('采样频率', hasData ? _formatRate(rate) : '—'),
          _buildFormatRow('位深', hasData && bits > 0 ? '$bits-bit' : '—'),
          // USB 遥测行（解码输出 / USB 输出）：数据源是原生 UsbAudioSinkController
          // 经 UsbAudioPlugin 上报，桌面端与 TV 构建没有该通道，永远只会显示「—」，
          // 故按能力隐藏（仅 Android 手机显示）。
          if (supportsUsbExclusive && !exclusiveEnabled)
            _buildFormatRow(
              '解码输出',
              hasData
                  ? (decRate > 0
                      ? '${_formatRate(decRate)} · ${_encodingBits(decEnc)}-bit'
                      : '${_encodingBits(decEnc)}-bit')
                  : '—',
            ),
          if (supportsUsbExclusive && dacBits > 0)
            _buildFormatRow('USB 输出', '$dacBits-bit(USB输出)'),
          if (fileSize != null) _buildFormatRow('文件大小', _formatFileSize(fileSize)),
          _buildFormatRow('声道', hasData ? _formatChannels(ch) : '—'),
          if (!hasData)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '播放歌曲后自动显示音频格式',
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFormatRow(String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Text(label,
              style: textTheme.bodyMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant)),
          const Spacer(),
          Text(value,
              style: textTheme.bodyMedium
                  ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  /// 采样率/位深格式化与 Media3 编码映射统一走 [AudioFormatUtils]（与 USB 格式链一致）。
  String _formatRate(int rate) => AudioFormatUtils.formatRate(rate);

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// Media3 编码常量 → 位深（bit）。
  int _encodingBits(int encoding) => AudioFormatUtils.encodingBits(encoding);

  String _formatChannels(int ch) {
    switch (ch) {
      case 1:
        return '单声道';
      case 2:
        return '立体声';
      case > 2:
        return '$ch 声道';
      default:
        return '—';
    }
  }
}
