import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';

/// 歌曲伴奏面板入口。
///
/// 与「看成绩单」同模式的统一入口（歌曲信息页 / 歌曲行菜单 / 无法播放对话框共用）：
/// 数据来自 /audio/accompany/matching（最佳伴奏匹配，匿名可用）；
/// K 歌数量来自 /audio/ktv/total（入参取自伴奏返回，拉取失败静默隐藏该行）。
void showSongAccompanySheet(BuildContext context, Song song) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      expand: false,
      builder: (innerCtx, scrollController) => Column(
        children: [
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(innerCtx).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '伴奏: ${song.displayName}',
                    style: Theme.of(innerCtx).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(innerCtx).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SongAccompanyView(
              song: song,
              scrollController: scrollController,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 伴奏内容视图：最佳伴奏匹配卡 + 播放伴奏 + K 歌数量。
class SongAccompanyView extends StatefulWidget {
  final Song song;

  /// 绑定 DraggableScrollableSheet 的滚动控制器（列表滚到顶后继续拖可缩放面板）。
  final ScrollController? scrollController;

  const SongAccompanyView({
    super.key,
    required this.song,
    this.scrollController,
  });

  @override
  State<SongAccompanyView> createState() => _SongAccompanyViewState();
}

class _SongAccompanyViewState extends State<SongAccompanyView> {
  KugouAccompany? _accompany;
  bool _loading = true;
  String? _error;

  /// K 歌作品总数：null=尚未拉到（静默隐藏该行，不提示失败）。
  int? _ktvTotal;

  /// 伴奏曲目封面：匹配响应不含封面字段，反查回填；null=尚未反查到。
  String? _coverUrl;

  /// 展示/播放共用的封面：反查结果优先，回退原曲封面。
  String? get _effectiveCover => _coverUrl ?? widget.song.artworkUri;

  String? get _mixId {
    final id = widget.song.albumAudioId;
    if (id == null || id.isEmpty) return null;
    return id;
  }

  @override
  void initState() {
    super.initState();
    if (_mixId != null) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final song = widget.song;
    final accompany = await KugouApiClient().getAudioAccompany(
      hash: song.id,
      mixId: _mixId!,
      // 酷狗 fileName 口径为 "歌手 - 歌名"（无扩展名），作匹配提示
      fileName: '${song.artist} - ${song.displayName}',
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (accompany == null) {
        _error = '伴奏信息加载失败';
      } else {
        _accompany = accompany;
        if (accompany.hasMatch) {
          _loadKtvTotal(accompany);
          _loadCover(accompany);
        }
      }
    });
  }

  /// 封面反查：伴奏匹配响应不含封面字段，用伴奏 hash 回查——
  /// 主曲库详情（多为原曲同款专辑封面，部分响应无封面）→ /images 兜底
  /// （无需登录态，键序与下载编排一致）。全落空则保持音符图标占位。
  Future<void> _loadCover(KugouAccompany accompany) async {
    final hash = accompany.hash!;
    final detail = await KugouApiClient().getSongDetail(hash);
    var url = detail?.artworkUri;
    url ??= await _coverFromImages(hash);
    if (!mounted) return;
    if (url != null && url.isNotEmpty) {
      setState(() => _coverUrl = url);
    }
  }

  /// /images 封面兜底：img_url/imgurl/img_5/sizable_cover 取首个非空，
  /// `{size}` 占位归一为 400（与 KugouSongDetail.artworkUri 同口径）。
  Future<String?> _coverFromImages(String hash) async {
    final img = await KugouApiClient().getImages(hash);
    final raw = img?['img_url'] ??
        img?['imgurl'] ??
        img?['img_5'] ??
        img?['sizable_cover'];
    if (raw == null) return null;
    final url = raw.toString().replaceAll('{size}', '400');
    return url.isEmpty ? null : url;
  }

  /// K 歌数量入参取自伴奏返回；字段缺失或拉取失败都静默隐藏，不影响主内容。
  Future<void> _loadKtvTotal(KugouAccompany accompany) async {
    final songId = accompany.songId;
    if (songId == null || songId.isEmpty) return;
    final total = await KugouApiClient().getAudioKtvTotal(
      songId: songId,
      singerName: accompany.singerName ?? '',
      songHash: accompany.hash ?? '',
    );
    if (!mounted) return;
    final n = total?.totalOpusNum;
    if (n == null || n <= 0) return;
    setState(() => _ktvTotal = n);
  }

  /// 用伴奏返回的 hash 构造在线 Song 走现有播放链路。
  void _playAccompany() {
    final accompany = _accompany;
    if (accompany == null || !accompany.hasMatch) return;
    final source = widget.song;
    final accompanySong = Song(
      id: accompany.hash!,
      title: '${source.displayName} (伴奏)',
      artist: accompany.singerName ?? source.artist,
      album: source.album,
      duration: Duration(milliseconds: accompany.durationMs ?? 0),
      isOnline: true,
      artworkUri: _effectiveCover,
    );
    final player = context.read<PlayerProvider>();
    Navigator.of(context).pop();
    unawaited(player.playSong(accompanySong));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 伴奏匹配依赖 album_audio_id（即 MixSongID），缺失时无可查询
    if (_mixId == null) {
      return _buildEmpty(context, '该歌曲暂无伴奏数据', colorScheme, textTheme);
    }
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text('伴奏加载中…',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final accompany = _accompany;
    if (accompany == null || !accompany.hasMatch) {
      return _buildEmpty(context, '未找到匹配的伴奏', colorScheme, textTheme);
    }

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        _buildAccompanyCard(accompany, colorScheme, textTheme),
        if (_ktvTotal != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mic_none,
                    size: 16, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  '$_ktvTotal 人在酷狗唱过这首歌',
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty(
    BuildContext context,
    String message,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic_none,
              size: 40, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message,
              style: textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildAccompanyCard(
    KugouAccompany accompany,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final infoLine = <String>[
      if (accompany.singerName?.isNotEmpty ?? false) accompany.singerName!,
      if (_durationText(accompany.durationMs).isNotEmpty)
        _durationText(accompany.durationMs),
    ].join(' · ');
    final qualityLine = <String>[
      if (accompany.bitrate != null && accompany.bitrate! > 0)
        '${accompany.bitrate}kbps',
      if (accompany.extName?.isNotEmpty ?? false)
        accompany.extName!.toUpperCase(),
      if (_sizeText(accompany.fileSize).isNotEmpty)
        _sizeText(accompany.fileSize),
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _buildCover(colorScheme),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(accompany.songName ?? widget.song.displayName,
                    style: textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (infoLine.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(infoLine,
                      style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
                if (qualityLine.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(qualityLine,
                      style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _buildPlayButton(colorScheme, textTheme),
        ],
      ),
    );
  }

  /// 卡片封面：反查到则显示图片，否则音符图标占位（结构照抄成绩单 _buildLogo）。
  Widget _buildCover(ColorScheme colorScheme) {
    Widget fallback() => Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
        );
    final url = _effectiveCover;
    if (url == null || url.isEmpty) return fallback();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 48,
        height: 48,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, _) => fallback(),
          errorWidget: (_, _, _) => fallback(),
        ),
      ),
    );
  }

  /// 播放伴奏：TV 下 DpadFocusable 单停点接管点击（FilledButton 会吞方向键的样式
  /// 不适合直接当停点，用与成绩单卡片头部一致的自绘胶囊 + 双驱动封装）。
  Widget _buildPlayButton(ColorScheme colorScheme, TextTheme textTheme) {
    final visual = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_arrow_rounded,
              size: 20, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 2),
          Text('播放伴奏',
              style: textTheme.labelLarge
                  ?.copyWith(color: colorScheme.onPrimaryContainer)),
        ],
      ),
    );
    return kTvBuild
        ? DpadFocusable(
            debugLabel: 'tv/song-accompany-play',
            onSelect: _playAccompany,
            child: visual,
          )
        : InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _playAccompany,
            child: visual,
          );
  }

  String _durationText(int? ms) {
    if (ms == null || ms <= 0) return '';
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _sizeText(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }
}
