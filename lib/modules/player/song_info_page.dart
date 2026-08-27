import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/services/usb_audio_service.dart';
import '../../core/utils/audio_scanner.dart' show audioExtensions;
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/usb_exclusive_section.dart';

/// 歌曲信息页：展示当前播放歌曲的音频格式（采样频率/位深/码率/声道）与
/// USB 独占输出开关（与设置页使用同一 [UsbExclusiveSection]，信息保持一致）。
///
/// 频率/位深/码率/声道取自 ExoPlayer 实际解码输出格式（原生 UsbAudioSinkController
/// 在 configure() 时捕获，无论是否开启独占都会更新）。
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

  @override
  void initState() {
    super.initState();
    _status = UsbAudioService.instance.lastStatus;
    UsbAudioService.instance.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    // 每秒刷新一次文件大小
    _fileSizeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshFileSize();
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
    try {
      final size = await _resolveFileSize();
      if (mounted && size != null && size != _fileSizeBytes) {
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
      } else if (local.startsWith('/')) {
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

  /// 从 ExoPlayer TrackGroup 读取源格式 + 解析音频文件头位深（歌曲原始属性）。
  Future<void> _refreshSourceFormat() async {
    final player = context.read<PlayerProvider>().audioService?.player;
    final song = context.read<PlayerProvider>().currentSong;
    Map<String, dynamic>? fmt;
    if (player != null) {
      fmt = await player.getSourceFormat();
    }
    final headerBits = await _parseHeaderBitDepth(song?.url, song?.localPath);
    if (mounted) {
      setState(() {
        _sourceFormat = fmt;
        _headerBitDepth = headerBits;
      });
    }
  }

  /// 解析音频文件头（FLAC STREAMINFO / WAV fmt chunk）获取原始位深。
  /// 本地文件直接读，网络 URL 用 Range 请求前 64 字节。解析失败返回 null。
  Future<int?> _parseHeaderBitDepth(String? url, String? localPath) async {
    try {
      Uint8List head;
      if (localPath != null) {
        final f = File(localPath);
        if (!await f.exists()) return null;
        final raf = await f.open();
        head = await raf.read(64);
        await raf.close();
      } else if (url != null) {
        final resp = await http
            .get(Uri.parse(url), headers: {'Range': 'bytes=0-63'})
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
        head = resp.bodyBytes;
      } else {
        return null;
      }

      if (head.length < 32) return null;

      // FLAC: "fLaC" + STREAMINFO 块，采样参数在 offset 8+10=18（8 字节）
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
        const off = 18;
        if (head.length < off + 4) return null;
        final bps = (((head[off + 2] & 0x01) << 4) | ((head[off + 3] >> 4) & 0x0F)) + 1;
        if (bps > 0 && bps <= 32) return bps;
      }

      // WAV: "RIFF" + fmt chunk 的 bitsPerSample（offset 34，2 字节 LE）
      if (head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46) {
        if (head.length >= 36) {
          final bps = (head[34] & 0xFF) | ((head[35] & 0xFF) << 8);
          if (bps > 0 && bps <= 32) return bps;
        }
      }
    } catch (_) {
      // 网络/文件解析失败静默处理
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final playerProvider = context.watch<PlayerProvider>();
    final song = playerProvider.currentSong;

    // 切歌后异步拉取源格式（以歌曲 id 去重，避免重复请求）
    if (song?.id != _sourceSongId) {
      _sourceSongId = song?.id;
      _fileSizeBytes = null;  // 换歌重置
      _fileSizeResolved = false;
      _refreshSourceFormat();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('歌曲信息')),
      body: ListView(
        children: [
          _buildSongHeader(song, colorScheme, textTheme),
          const SizedBox(height: 8),
          _buildSectionHeader('音频格式'),
          _buildFormatCard(colorScheme),
          const SizedBox(height: 8),
          _buildSectionHeader('USB 独占'),
          UsbExclusiveSection(
            onAutoPause: () => context.read<PlayerProvider>().pause(),
          ),
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
    final srcBits = _headerBitDepth ?? 0;

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
        : (srcPcmEnc > 0 ? _encodingBits(srcPcmEnc) : _encodingBits(decEnc));

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
          _buildFormatRow('位深', hasData ? '$bits-bit' : '—'),
          if (!exclusiveEnabled)
            _buildFormatRow(
              '解码输出',
              hasData
                  ? (decRate > 0
                      ? '${_formatRate(decRate)} · ${_encodingBits(decEnc)}-bit'
                      : '${_encodingBits(decEnc)}-bit')
                  : '—',
            ),
          if (dacBits > 0) _buildFormatRow('USB 输出', '$dacBits-bit(USB输出)'),
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

  String _formatRate(int rate) {
    if (rate <= 0) return '—';
    if (rate % 1000 == 0) return '${rate ~/ 1000} kHz';
    return '${(rate / 1000).toStringAsFixed(1)} kHz';
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// Media3 编码常量 → 位深（bit）。
  int _encodingBits(int encoding) {
    switch (encoding) {
      case 4: // C.ENCODING_PCM_FLOAT
        return 32;
      case 2: // C.ENCODING_PCM_16BIT
        return 16;
      case 0x15: // C.ENCODING_PCM_24BIT
        return 24;
      case 0x16: // C.ENCODING_PCM_32BIT
        return 32;
      default:
        return 16;
    }
  }

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
