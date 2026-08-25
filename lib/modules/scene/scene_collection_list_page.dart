import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../player/mini_player.dart';
import '../playlist/playlist_page.dart';

/// 场景音乐歌单列表页（/scene/collection/list?tag_id=tag_id）。
///
/// 分页加载歌单，点击进入 [PlaylistPage]。
class SceneCollectionListPage extends StatefulWidget {
  final String tagId;
  final String? title;

  const SceneCollectionListPage({super.key, required this.tagId, this.title});

  @override
  State<SceneCollectionListPage> createState() => _SceneCollectionListPageState();
}

class _SceneCollectionListPageState extends State<SceneCollectionListPage> {
  static const int _pageSize = 30;

  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  List<KugouPlaylistBrief> _lists = [];

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
    final r = await KugouApiClient().getSceneCollectionList(
      widget.tagId,
      page: _page,
      pagesize: _pageSize,
    );
    final parsed = <KugouPlaylistBrief>[];
    for (final e in _listOf(r)) {
      if (e is! Map<String, dynamic>) continue;
      final brief = KugouPlaylistBrief.fromJson(_normalize(e));
      if (brief.id.isNotEmpty) parsed.add(brief);
    }
    if (!mounted) return;
    setState(() {
      if (reset) {
        _lists = parsed;
      } else {
        _lists.addAll(parsed);
      }
      // 本页未满 → 无更多
      _hasMore = parsed.length >= _pageSize;
      _page++;
      _isLoading = false;
    });
  }

  /// 场景歌单接口字段名与标准歌单不同，归一化到 [KugouPlaylistBrief] 认识的键
  Map<String, dynamic> _normalize(Map<String, dynamic> json) {
    final m = Map<String, dynamic>.from(json);
    // 场景歌单的 id 即 global_collection_id（collection_3_{userid}_{listid}_0），
    // PlaylistPage 统一走 /playlist/track/all?global_collection_id= 拉歌。
    // 注意：不要映射 slid→listid，否则已登录时会优先走 /playlist/track/all/new
    // （仅支持用户本人的收藏歌单），场景歌单是他人歌单会拉空且跳过回退。
    m['global_collection_id'] ??= m['id'];
    m['specialid'] ??= m['collection_id'] ?? m['list_id'];
    m['name'] ??= m['collection_name'] ?? m['playlist_name'] ?? m['title'];
    m['imgurl'] ??= m['img'] ?? m['cover'] ?? m['pic'];
    m['song_count'] ??= m['songnum'] ?? m['song_count_num'];
    m['play_count'] ??= m['playnum'] ?? m['listen_count'];
    return m;
  }

  /// 从响应中提取列表（防御：data 可能是 Map 或 List，list 字段名多变）
  List<dynamic> _listOf(Map<String, dynamic>? json) {
    if (json == null) return const [];
    final d = json['data'];
    if (d is Map<String, dynamic>) {
      final l = d['list'] ?? d['info'] ?? d['items'];
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
        title: widget.title ?? '场景歌单',
        opaque: true,
        scrollController: _scrollController,
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _lists.isEmpty
              ? _buildEmpty(cs)
              : Md3PullToRefresh(
                  onRefresh: () => _load(reset: true, showLoading: false),
                  child: PinchableGridView(
                    controller: _scrollController,
                    itemCount: _lists.length,
                    childAspectRatio: 0.75,
                    padding: const EdgeInsets.all(16),
                    loadingWidget: _loadingMore
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: M3ECircularProgressIndicator(size: 24, strokeWidth: 2),
                              ),
                            ),
                          )
                        : null,
                    itemBuilder: (context, i) {
                      final brief = _lists[i];
                      return _CollectionCard(
                        brief: brief,
                        onTap: () {
                          final playlist = brief.toPlaylist();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PlaylistPage(playlist: playlist),
                            ),
                          );
                        },
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
            Icons.queue_music_outlined,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无歌单',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 歌单卡片：封面（无图显示类型图标占位，避免加载灰块）+ 名称
class _CollectionCard extends StatelessWidget {
  final KugouPlaylistBrief brief;
  final VoidCallback? onTap;

  const _CollectionCard({required this.brief, this.onTap});

  /// 无封面/加载失败占位：透明背景 + 类型图标，避免大块纯色矩形
  Widget _placeholder(ColorScheme cs) {
    return ColoredBox(
      color: Colors.transparent,
      child: Center(
        child: Icon(Icons.queue_music_outlined, color: cs.onSurfaceVariant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: cs.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: brief.coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: brief.coverUrl!,
                        memCacheWidth: 540,
                        memCacheHeight: 540,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _placeholder(cs),
                      )
                    : _placeholder(cs),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      brief.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.labelMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                    if (brief.songCount > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${brief.songCount} 首',
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
