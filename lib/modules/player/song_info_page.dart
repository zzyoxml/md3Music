import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/usb_audio_service.dart';
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

  @override
  void initState() {
    super.initState();
    _status = UsbAudioService.instance.lastStatus;
    UsbAudioService.instance.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final playerProvider = context.watch<PlayerProvider>();
    final song = playerProvider.currentSong;

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

  Widget _buildSongHeader(
      Song? song, ColorScheme colorScheme, TextTheme textTheme) {
    final title = song?.title ?? '未在播放';
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
    final hasData = ((_status['lastSampleRate'] as num?)?.toInt() ?? 0) > 0;
    final rate = (_status['lastSampleRate'] as num?)?.toInt() ?? 0;
    final ch = (_status['lastChannelCount'] as num?)?.toInt() ?? 0;
    final encoding = (_status['lastEncoding'] as num?)?.toInt() ?? 2;

    final bits = _encodingBits(encoding);
    final bitrate = rate > 0 && bits > 0 && ch > 0
        ? '${(rate * bits * ch / 1000).round()} kbps'
        : '—';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _buildFormatRow('采样频率', hasData ? _formatRate(rate) : '—'),
          _buildFormatRow('位深', hasData ? _bitDepthLabel(encoding) : '—'),
          _buildFormatRow('码率（PCM 输出）', hasData ? bitrate : '—'),
          _buildFormatRow('声道', hasData ? _formatChannels(ch) : '—'),
          if (!hasData)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '播放歌曲后自动显示解码格式',
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

  String _bitDepthLabel(int encoding) {
    switch (encoding) {
      case 4:
        return '32-bit Float';
      case 2:
        return '16-bit';
      case 0x15:
        return '24-bit';
      case 0x16:
        return '32-bit';
      default:
        return '16-bit';
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
