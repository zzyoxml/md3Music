import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../player/mini_player.dart';
import '../playlist/playlist_page.dart';
import 'scene_audio_list_page.dart';
import 'scene_collection_list_page.dart';
import 'scene_video_list_page.dart';

/// 场景音乐详情页。
///
/// 展示：场景头部 + 场景模块列表（/scene/module 的 content.music/video）+
/// 讨论区动态流（/scene/lists/v2 的 data.list）。
/// 点击模块进入 [SceneModuleTagsPage]；讨论区动态可播放关联歌曲/进入关联歌单。
class SceneDetailPage extends StatefulWidget {
  final KugouSceneInfo scene;

  const SceneDetailPage({super.key, required this.scene});

  @override
  State<SceneDetailPage> createState() => _SceneDetailPageState();
}

class _SceneDetailPageState extends State<SceneDetailPage> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;

  /// 按 content_type 分组的 tag（记录所属 module_id，audio 列表需要）
  List<({String moduleId, KugouSceneTag tag})> _musicTags = [];
  List<({String moduleId, KugouSceneTag tag})> _collectionTags = [];
  List<({String moduleId, KugouSceneTag tag})> _videoTags = [];
  List<KugouSceneDiscuss> _discusses = [];

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
    final api = KugouApiClient();
    // 并行加载模块 + 讨论区
    final results = await Future.wait([
      api.getSceneModule(widget.scene.id),
      api.getSceneListsV2(widget.scene.id),
    ]);
    final music = <({String moduleId, KugouSceneTag tag})>[];
    final collections = <({String moduleId, KugouSceneTag tag})>[];
    final videos = <({String moduleId, KugouSceneTag tag})>[];
    for (final e in _moduleListOf(results[0])) {
      if (e is! Map<String, dynamic>) continue;
      final m = KugouSceneModule.fromJson(e);
      for (final t in m.tags) {
        switch (t.contentType) {
          case 1:
            // 歌单
            collections.add((moduleId: m.moduleId, tag: t));
          case 2:
            // 视频
            videos.add((moduleId: m.moduleId, tag: t));
          default:
            // 6=音乐及其他（缺省按音乐处理）
            music.add((moduleId: m.moduleId, tag: t));
        }
      }
    }
    final discusses = <KugouSceneDiscuss>[];
    for (final e in _listOf(results[1])) {
      if (e is! Map<String, dynamic>) continue;
      final d = KugouSceneDiscuss.fromJson(e);
      if (d.id.isNotEmpty) discusses.add(d);
    }
    if (!mounted) return;
    setState(() {
      _musicTags = music;
      _collectionTags = collections;
      _videoTags = videos;
      _discusses = discusses;
      _isLoading = false;
    });
  }

  /// /scene/module：模块在 data.content 下的 music[]/video[] 等数组
  List<dynamic> _moduleListOf(Map<String, dynamic>? json) {
    if (json == null) return const [];
    final d = json['data'];
    if (d is Map<String, dynamic>) {
      final content = d['content'];
      if (content is Map<String, dynamic>) {
        final result = <dynamic>[];
        for (final key in ['music', 'video', 'song', 'collection']) {
          final v = content[key];
          if (v is List) result.addAll(v);
        }
        return result;
      }
    }
    return const [];
  }

  /// 通用列表提取（讨论区 data.list）
  List<dynamic> _listOf(Map<String, dynamic>? json) {
    if (json == null) return const [];
    final d = json['data'];
    if (d is Map<String, dynamic>) {
      final l = d['list'];
      if (l is List) return l;
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: widget.scene.name,
        opaque: true,
        scrollController: _scrollController,
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Md3PullToRefresh(
              onRefresh: () => _load(showLoading: false),
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  _buildHeader(context),
                  if (_musicTags.isNotEmpty)
                    _buildTagSection(context, '音乐', _musicTags),
                  if (_collectionTags.isNotEmpty)
                    _buildTagSection(context, '歌单', _collectionTags),
                  if (_videoTags.isNotEmpty)
                    _buildTagSection(context, '视频', _videoTags),
                  if (_discusses.isNotEmpty) _buildDiscussSection(context),
                  if (_musicTags.isEmpty &&
                      _collectionTags.isEmpty &&
                      _videoTags.isEmpty &&
                      _discusses.isEmpty)
                    _buildEmpty(context),
                ],
              ),
            ),
    );
  }

  /// 场景头部：大图 + 名称
  Widget _buildHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 120,
              height: 120,
              child: widget.scene.coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: widget.scene.coverUrl!,
                      memCacheWidth: 360,
                      memCacheHeight: 360,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(
                        color: cs.surfaceContainerHighest,
                        child: Icon(
                          Icons.landscape_outlined,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Container(
                      color: cs.surfaceContainerHighest,
                      child: Icon(
                        Icons.landscape_outlined,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              widget.scene.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 按类型分组的 Tag 区块：横向卡片流，点击直接进入对应列表
  Widget _buildTagSection(
    BuildContext context,
    String title,
    List<({String moduleId, KugouSceneTag tag})> items,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        SizedBox(
          height: 130,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _TagCard(
                  tag: item.tag,
                  onTap: () => _onTagTap(title, item),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 点击 Tag：按区块类型进入对应列表页
  void _onTagTap(
    String sectionTitle,
    ({String moduleId, KugouSceneTag tag}) item,
  ) {
    final Widget page;
    switch (sectionTitle) {
      case '歌单':
        page = SceneCollectionListPage(
          tagId: item.tag.tagId,
          title: item.tag.name,
        );
      case '视频':
        page = SceneVideoListPage(tagId: item.tag.tagId, title: item.tag.name);
      default:
        page = SceneAudioListPage(
          sceneId: widget.scene.id,
          moduleId: item.moduleId,
          tagId: item.tag.tagId,
          title: item.tag.name,
        );
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// 讨论区：用户动态流
  Widget _buildDiscussSection(BuildContext context) {
    final items = _discusses
        .where((d) => d.content.isNotEmpty || d.song != null)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '讨论区',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        for (final d in items)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: _DiscussCard(
              discuss: d,
              onSongTap: () {
                final song = d.song;
                if (song == null || song.hash.isEmpty) return;
                // 整表播放关联歌曲（仅当前动态的歌曲）
                context.read<PlayerProvider>().playOnlineSong(song.toSong());
              },
              onCollectionTap: () {
                final c = d.collection;
                if (c == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlaylistPage(playlist: c.toPlaylist()),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.landscape_outlined,
              size: 48,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '该场景暂无内容',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tag 卡片：封面图（无图用类型图标）+ 名称
class _TagCard extends StatelessWidget {
  final KugouSceneTag tag;
  final VoidCallback? onTap;

  const _TagCard({required this.tag, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 110,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: cs.surfaceContainerLow,
          child: InkWell(
            onTap: onTap,
            child: Column(
              children: [
                Expanded(
                  child: tag.picUrl != null
                      ? CachedNetworkImage(
                          imageUrl: tag.picUrl!,
                          memCacheWidth: 330,
                          memCacheHeight: 330,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => _fallback(cs),
                        )
                      : _fallback(cs),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(
                    tag.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme cs) {
    // 歌单/视频 Tag 的 pic 常为空串，用类型图标占位（透明背景，无大块矩形）
    final icon = switch (tag.contentType) {
      1 => Icons.queue_music_outlined,
      2 => Icons.videocam_outlined,
      _ => Icons.music_note_outlined,
    };
    return ColoredBox(
      color: Colors.transparent,
      child: Center(child: Icon(icon, color: cs.onSurfaceVariant)),
    );
  }
}

/// 讨论区动态卡片：头像 + 昵称 + 内容 + 关联歌曲/歌单 + 点赞/评论
class _DiscussCard extends StatelessWidget {
  final KugouSceneDiscuss discuss;
  final VoidCallback? onSongTap;
  final VoidCallback? onCollectionTap;

  const _DiscussCard({
    required this.discuss,
    this.onSongTap,
    this.onCollectionTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final song = discuss.song;
    final collection = discuss.collection;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 用户信息
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: cs.surfaceContainerHighest,
                backgroundImage: discuss.avatar != null
                    ? NetworkImage(discuss.avatar!)
                    : null,
                child: discuss.avatar == null
                    ? Icon(Icons.person, size: 18, color: cs.onSurfaceVariant)
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  discuss.nickname.isEmpty ? '匿名' : discuss.nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelLarge,
                ),
              ),
            ],
          ),
          if (discuss.topicTitle != null && discuss.topicTitle!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '#${discuss.topicTitle}',
              style: tt.labelMedium?.copyWith(color: cs.primary),
            ),
          ],
          if (discuss.content.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(discuss.content, style: tt.bodyMedium),
          ],
          // 关联歌曲
          if (song != null && song.hash.isNotEmpty) ...[
            const SizedBox(height: 8),
            Material(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onSongTap,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: song.artworkUri != null
                              ? CachedNetworkImage(
                                  imageUrl: song.artworkUri!,
                                  memCacheWidth: 120,
                                  memCacheHeight: 120,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => Icon(
                                    Icons.music_note,
                                    color: cs.onSurfaceVariant,
                                  ),
                                )
                              : Icon(Icons.music_note, color: cs.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.songName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.labelMedium,
                            ),
                            if (song.artistName != null &&
                                song.artistName!.isNotEmpty)
                              Text(
                                song.artistName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(Icons.play_circle_outline, color: cs.primary),
                    ],
                  ),
                ),
              ),
            ),
          ],
          // 关联歌单
          if (collection != null && collection.id.isNotEmpty) ...[
            const SizedBox(height: 8),
            Material(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onCollectionTap,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: collection.coverUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: collection.coverUrl!,
                                  memCacheWidth: 120,
                                  memCacheHeight: 120,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => Icon(
                                    Icons.queue_music,
                                    color: cs.onSurfaceVariant,
                                  ),
                                )
                              : Icon(
                                  Icons.queue_music,
                                  color: cs.onSurfaceVariant,
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          collection.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tt.labelMedium,
                        ),
                      ),
                      Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
          ],
          // 点赞/评论数
          if (discuss.likeTotal > 0 || discuss.commentTotal > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.thumb_up_outlined, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  '${discuss.likeTotal}',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 16),
                Icon(Icons.mode_comment_outlined, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  '${discuss.commentTotal}',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
