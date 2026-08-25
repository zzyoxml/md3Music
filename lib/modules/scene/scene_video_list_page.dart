import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../player/mini_player.dart';
import '../player/mv_player_page.dart';

/// 场景音乐视频列表页（/scene/video/list?tag_id=tag_id）。
///
/// 分页加载视频，点击后通过 /video/url 取播放地址并进入 [SceneVideoPlayerPage]。
class SceneVideoListPage extends StatefulWidget {
  final String tagId;
  final String? title;

  const SceneVideoListPage({super.key, required this.tagId, this.title});

  @override
  State<SceneVideoListPage> createState() => _SceneVideoListPageState();
}

class _SceneVideoListPageState extends State<SceneVideoListPage> {
  static const int _pageSize = 30;

  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  List<KugouSceneVideo> _videos = [];

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
    final r = await KugouApiClient().getSceneVideoList(
      widget.tagId,
      page: _page,
      pagesize: _pageSize,
    );
    final parsed = <KugouSceneVideo>[];
    for (final e in _listOf(r)) {
      if (e is! Map<String, dynamic>) continue;
      final v = KugouSceneVideo.fromJson(e);
      if (v.id.isNotEmpty) parsed.add(v);
    }
    if (!mounted) return;
    setState(() {
      if (reset) {
        _videos = parsed;
      } else {
        _videos.addAll(parsed);
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
      final l = d['list'] ?? d['info'] ?? d['items'];
      if (l is List) return l;
    }
    if (d is List) return d;
    final l = json['list'] ?? json['info'];
    if (l is List) return l;
    return const [];
  }

  Future<void> _playVideo(KugouSceneVideo video) async {
    final api = KugouApiClient();
    // 无 hash 时尝试用 video id 兜底；仍失败则提示
    final hash = video.hash ?? video.id;
    final url = await api.getVideoUrl(hash);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      showToast('该视频暂无法播放', long: true);
      return;
    }
    // 复用 MvPlayerPage：直接播放地址模式 + 展示标题/作者，支持投屏
    final song = Song(
      id: video.id,
      title: video.title,
      artist: video.authorName ?? '',
      album: '',
      duration: Duration.zero,
      isOnline: true,
      artworkUri: video.coverUrl,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MvPlayerPage(song: song, directVideoUrl: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: widget.title ?? '场景视频',
        opaque: true,
        scrollController: _scrollController,
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _videos.isEmpty
              ? _buildEmpty(cs)
              : Md3PullToRefresh(
                  onRefresh: () => _load(reset: true, showLoading: false),
                  child: PinchableGridView(
                    controller: _scrollController,
                    itemCount: _videos.length,
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
                    itemBuilder: (context, i) => _VideoCard(
                      video: _videos[i],
                      onTap: () => _playVideo(_videos[i]),
                    ),
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
            Icons.videocam_outlined,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无视频',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 视频卡片：封面 + 标题
class _VideoCard extends StatelessWidget {
  final KugouSceneVideo video;
  final VoidCallback? onTap;

  const _VideoCard({required this.video, this.onTap});

  /// 无封面/加载失败占位：透明背景 + 类型图标，避免大块纯色矩形
  Widget _placeholder(ColorScheme cs) {
    return ColoredBox(
      color: Colors.transparent,
      child: Center(
        child: Icon(Icons.videocam_outlined, color: cs.onSurfaceVariant),
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (video.coverUrl != null)
                      CachedNetworkImage(
                        imageUrl: video.coverUrl!,
                        memCacheWidth: 540,
                        memCacheHeight: 540,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _placeholder(cs),
                      )
                    else
                      _placeholder(cs),
                    // 播放角标
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill,
                        color: Colors.white70,
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.labelMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                    if (video.authorName != null &&
                        video.authorName!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        video.authorName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
