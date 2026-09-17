import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

/// 音乐故事详情页（/youth/channel/song/detail）。
///
/// 展示故事正文文案 + 关联歌曲（可播放）。响应结构不定，采用防御式解析：
/// 递归扫描收集文案字段与歌曲数组。
class ChannelStoryDetailPage extends StatefulWidget {
  final String channelId;
  final String fileId;
  final String title;

  const ChannelStoryDetailPage({
    super.key,
    required this.channelId,
    required this.fileId,
    required this.title,
  });

  @override
  State<ChannelStoryDetailPage> createState() =>
      _ChannelStoryDetailPageState();
}

class _ChannelStoryDetailPageState extends State<ChannelStoryDetailPage> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  String _content = '';
  String? _coverUrl;
  List<KugouSongDetail> _songs = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
    });
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => _isLoading = true);
    Map<String, dynamic>? r;
    try {
      r = await KugouApiClient().getYouthChannelSongDetail(
        widget.channelId,
        widget.fileId,
      );
    } catch (_) {
      r = null;
    }
    final texts = <String>[];
    String? cover;
    final songs = <KugouSongDetail>[];
    final seenHash = <String>{};

    // 主体：data 通常是单个故事帖对象（平铺歌曲字段 sd_hash/ori_audio_name/authors）
    final d = r?['data'];
    if (d is Map<String, dynamic>) {
      final title = d['ori_audio_name']?.toString().trim() ?? '';
      if (title.isNotEmpty) texts.add(title);
      final remark = d['remark'];
      if (remark is String && remark.trim().isNotEmpty) {
        texts.add(remark.trim());
      }
      final nick = d['nick_name']?.toString().trim() ?? '';
      if (nick.isNotEmpty) texts.add('作者：$nick');
      cover = d['channel_pic']?.toString().trim() ?? cover;
      try {
        final s = KugouSongDetail.fromJson(d);
        if (s.hash.isNotEmpty && seenHash.add(s.hash)) songs.add(s);
      } catch (_) {
        // 单个条目结构异常时跳过
      }
    }

    // 递归扫描未知结构：收集文案字段 / 封面 / 歌曲数组（兜底）
    void scan(dynamic v) {
      if (v is Map) {
        for (final e in v.entries) {
          final key = e.key.toString().toLowerCase();
          final val = e.value;
          if (val is String && val.trim().isNotEmpty) {
            if (key == 'content' ||
                key == 'text' ||
                key == 'desc' ||
                key == 'intro' ||
                key == 'title' ||
                key == 'sub_title' ||
                key == 'summary') {
              texts.add(val.trim());
            } else if ((key == 'img' ||
                    key == 'cover' ||
                    key == 'pic' ||
                    key == 'imgurl') &&
                cover == null) {
              cover = val.trim();
            }
          } else {
            scan(val);
          }
        }
        for (final k in [
          'files',
          'audio',
          'songs',
          'music',
          'audio_list',
          'content_list',
        ]) {
          final arr = v[k];
          if (arr is! List) continue;
          for (final item in arr) {
            if (item is! Map<String, dynamic>) continue;
            try {
              final s = KugouSongDetail.fromJson(item);
              if (s.hash.isNotEmpty && seenHash.add(s.hash)) songs.add(s);
            } catch (_) {
              // 单个条目结构异常时跳过
            }
          }
        }
      } else if (v is List) {
        for (final item in v) {
          scan(item);
        }
      }
    }

    scan(r);
    // 文案合并去重（保持顺序）
    final unique = <String>{};
    final content = texts.where((t) => unique.add(t)).join('\n');
    if (!mounted) return;
    setState(() {
      _content = content;
      _coverUrl = cover;
      _songs = songs;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: widget.title,
        scrollController: _scrollController,
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Md3PullToRefresh(
              onRefresh: () => _load(showLoading: false),
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (_coverUrl != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CachedNetworkImage(
                          imageUrl: _coverUrl!,
                          memCacheWidth: 1080,
                          memCacheHeight: 540,
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  if (_content.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Card(
                        margin: EdgeInsets.zero,
                        color: cs.surfaceContainerLow,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _content,
                            style: tt.bodyMedium?.copyWith(
                              height: 1.6,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_songs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '歌曲',
                        style: tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ..._songs.asMap().entries.map((e) {
                    final i = e.key;
                    final s = e.value;
                    return SongListItem(
                      song: s.toSong(),
                      onTap: () =>
                          context.read<PlayerProvider>().playOnlinePlaylist(
                            _songs.map((x) => x.toSong()).toList(),
                            i,
                          ),
                      onMoreTap: () {},
                    );
                  }),
                  if (_content.isEmpty && _songs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 64),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.article_outlined,
                              size: 48,
                              color: cs.onSurfaceVariant.withValues(
                                alpha: 0.5,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '暂无故事内容',
                              style: tt.titleMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
