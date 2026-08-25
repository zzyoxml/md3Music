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

/// 场景音乐音乐列表页（/scene/audio/list?id=scene_id&module_id=module_id&tag=tag_id）。
///
/// 分页加载歌曲，点击任意一首整表播放（[PlayerProvider.playOnlinePlaylist]）。
class SceneAudioListPage extends StatefulWidget {
  final String sceneId;
  final String moduleId;
  final String tagId;
  final String? title;

  const SceneAudioListPage({
    super.key,
    required this.sceneId,
    required this.moduleId,
    required this.tagId,
    this.title,
  });

  @override
  State<SceneAudioListPage> createState() => _SceneAudioListPageState();
}

class _SceneAudioListPageState extends State<SceneAudioListPage> {
  static const int _pageSize = 30;

  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  List<KugouSongDetail> _songs = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load(reset: true);
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    await _load(reset: false);
    _loadingMore = false;
  }

  Future<void> _load({required bool reset, bool showLoading = true}) async {
    if (reset) {
      _page = 1;
      _hasMore = true;
      if (showLoading && mounted) setState(() => _isLoading = true);
    }
    final r = await KugouApiClient().getSceneAudioList(
      sceneId: widget.sceneId,
      moduleId: widget.moduleId,
      tag: widget.tagId,
      page: _page,
      pagesize: _pageSize,
    );
    final parsed = <KugouSongDetail>[];
    for (final e in _listOf(r)) {
      if (e is! Map<String, dynamic>) continue;
      final song = KugouSongDetail.fromJson(e);
      if (song.hash.isNotEmpty) parsed.add(song);
    }
    if (!mounted) return;
    setState(() {
      if (reset) {
        _songs = parsed;
      } else {
        _songs.addAll(parsed);
      }
      _hasMore = parsed.length >= _pageSize;
      _page++;
      _isLoading = false;
    });
  }

  /// 从响应中提取列表（防御：data 可能是 Map 或 List，list 字段名多变）
  List<dynamic> _listOf(Map<String, dynamic>? json) {
    if (json == null) return const [];
    final d = json['data'];
    if (d is Map<String, dynamic>) {
      final l = d['list'] ?? d['info'] ?? d['items'] ?? d['song_list'];
      if (l is List) return l;
    }
    if (d is List) return d;
    final l = json['list'] ?? json['info'];
    if (l is List) return l;
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: widget.title ?? '场景音乐列表',
        opaque: true,
        scrollController: _scrollController,
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _songs.isEmpty
              ? _buildEmpty(cs)
              : Md3PullToRefresh(
                  onRefresh: () => _load(reset: true, showLoading: false),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: _songs.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _songs.length) {
                        // 底部加载更多指示器
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: M3ECircularProgressIndicator(size: 24, strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      final songs = _songs;
                      return SongListItem(
                        song: songs[i].toSong(),
                        onTap: () =>
                            context.read<PlayerProvider>().playOnlinePlaylist(
                              songs.map((e) => e.toSong()).toList(),
                              i,
                            ),
                        onMoreTap: () {},
                      );
                    },
                  ),
                ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_off_outlined,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无音乐',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
