import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../data/repositories/collected_playlist_store.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_collection_notifier.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/song_list_item.dart';
import '../player/mini_player.dart';

class PlaylistPage extends StatefulWidget {
  final Playlist playlist;
  // 「我收藏」里的歌单：本身已是已收藏状态，不显示红心收藏按钮。
  final bool isInMyFavorites;

  const PlaylistPage({
    super.key,
    required this.playlist,
    this.isInMyFavorites = false,
  });

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  bool _isLoading = true;
  List<Song> _songs = [];
  String? _error;
  // 普通歌单（发现/热门/排行榜）的红心收藏状态
  bool _isCollected = false;
  String? _collectedListId;

  /// 顶栏渐变 ScrollController：监听 CustomScrollView 滚动 offset，
  /// 用于 SliverAppBar pinned 后 fade-in 显示歌单名称
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;

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
      // 只有普通歌单才需要查收藏状态。「我收藏」里进来的歌单跳过。
      if (!widget.isInMyFavorites) {
        _checkCollected();
      }
      _fetchSongs();
    });
  }

  /// 滚动监听：更新 _scrollOffset 触发重绘，驱动顶栏 fade-in 歌单名称
  void _onScroll() {
    if (!mounted) return;
    final offset = _scrollController.offset;
    if ((offset - _scrollOffset).abs() > 0.5) {
      setState(() => _scrollOffset = offset);
    }
  }

  // ==================== 收藏本地缓存（解决后端 user/playlist 列表 ~1-2 分钟缓存才同步的问题）====================

  /// 查询当前歌单是否已被收藏（仅供普通歌单「发现/热门/排行榜」用）。
  /// 「我收藏」里点进来的歌单本身已是已收藏状态，不需要再查。
  Future<void> _checkCollected() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    // 1) 本地缓存优先：即时显示红心，不再等后端 1~2 分钟的缓存
    final cached = await CollectedPlaylistStore.getListId(widget.playlist.id);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _isCollected = true;
          _collectedListId = cached;
        });
      }
      return;
    }

    // 2) 本地无记录时回退到服务器查询（覆盖在官方 App / 其他端收藏的外部场景）
    final listid = await _findCollectedListId(api);
    if (listid != null && mounted) {
      await CollectedPlaylistStore.setListId(widget.playlist.id, listid);
      setState(() {
        _isCollected = true;
        _collectedListId = listid;
      });
    }
  }

  /// 尽量多路径地从 playlist/add 响应里解析出新建歌单的 listid
  String? _parseListId(Map<String, dynamic>? result) {
    if (result == null) return null;
    final data = result['data'];
    if (data is Map) {
      for (final key in const ['listid', 'list_id', 'ListId', 'id']) {
        final v = data[key];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
    }
    for (final key in const ['listid', 'list_id', 'id']) {
      final v = result[key];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return null;
  }

  /// 兜底：重新拉取用户歌单列表，按 gid/name 匹配出新收藏歌单的 listid
  Future<String?> _findCollectedListId(KugouApiClient api) async {
    try {
      final result = await api.getUserPlaylist(pagesize: 50);
      if (result == null) return null;
      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }
      if (list == null) return null;
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final gid = item['global_collection_id']?.toString() ?? '';
          final name = item['name']?.toString() ?? '';
          if (gid == widget.playlist.id || name == widget.playlist.name) {
            return item['listid']?.toString();
          }
        }
      }
    } catch (e) {
      // 忽略
    }
    return null;
  }

  Future<void> _collectPlaylist() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请先登录'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    try {
      String? listCreateUserid = widget.playlist.listCreateUserid;
      String? listCreateListid = widget.playlist.listCreateListid;
      if ((listCreateUserid == null || listCreateListid == null) &&
          widget.playlist.id.contains('_')) {
        final parts = widget.playlist.id.split('_');
        if (parts.length >= 4) {
          listCreateUserid ??= parts[2];
          listCreateListid ??= parts[3];
        }
      }
      final result = await api.createPlaylist(
        widget.playlist.name,
        type: 1,
        listCreateUserid: listCreateUserid,
        listCreateListid: listCreateListid,
        globalCollectionId: widget.playlist.id,
      );
      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('收藏失败，请重试'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      // 尽量解析新建歌单的 listid；解析不到再回退到服务器查询
      String? newId = _parseListId(result);
      newId ??= await _findCollectedListId(api);
      await CollectedPlaylistStore.setListId(widget.playlist.id, newId);
      if (mounted) {
        setState(() {
          _isCollected = true;
          _collectedListId = newId;
        });
        // 通知「我的收藏」tab 立即刷新（绕过本地代理 2 分钟缓存）
        context.read<PlaylistCollectionNotifier>().notifyChanged();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('收藏成功'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('收藏失败'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _uncollectPlaylist() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    // 优先取本地缓存 / 页面状态里的 listid，取不到再回查服务器
    String? listId = await CollectedPlaylistStore.getListId(widget.playlist.id);
    listId ??= _collectedListId;
    listId ??= await _findCollectedListId(api);
    if (listId == null || listId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('找不到收藏记录，无法取消'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      // 收藏的歌单用 type=0 取消（与「我的收藏」页删除收藏歌单保持一致）
      final result = await api.deletePlaylist(listId, type: 0);
      if (result != null && mounted) {
        await CollectedPlaylistStore.remove(widget.playlist.id);
        setState(() {
          _isCollected = false;
          _collectedListId = null;
        });
        // 通知「我的收藏」tab 立即刷新（绕过本地代理 2 分钟缓存）
        context.read<PlaylistCollectionNotifier>().notifyChanged();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已取消收藏'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('取消收藏失败，请重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('取消收藏失败'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _fetchSongs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // 「我的收藏」里的歌单（listid 是用户订阅的版本）走 listid 接口拿完整歌曲；
      // 其它歌单（发现页、排行榜、热门歌单）走 globalCollectionId。
      // 两种情况都强制 forceRefresh，绕过本地代理 2 分钟 apicache，
      // 避免"换个歌单回来老歌单不刷新"。
      final api = KugouApiClient();
      final isLoggedIn = api.isLoggedIn;
      // 拉取歌曲的 listid 优先级：
      // 1. subscribedListId（用户订阅/收藏版本的 listid，调 /playlist/track/all/new）
      // 2. listCreateListid（仅自己创建的歌单有效，收藏别人的歌单这个是原作者的 id）
      final fetchListid =
          widget.playlist.subscribedListId ?? widget.playlist.listCreateListid;

      List<Song> all = [];
      if (isLoggedIn && fetchListid != null && fetchListid.isNotEmpty) {
        // 已登录 + 有 listid：用 /playlist/track/all/new 拉（仅支持用户创建/收藏的歌单）
        const int pageSize = 200;
        const int maxPages = 10;
        for (int page = 1; page <= maxPages; page++) {
          final r = await api.getPlaylistSongsByListid(
            listid: fetchListid,
            page: page,
            pagesize: pageSize,
            noCache: true,
          );
          if (!mounted) return;
          if (r == null) break;
          final batch = r.songs.map((s) => s.toSong()).toList();
          all.addAll(batch);
          if (batch.length < pageSize) break;
        }
        // listid 接口拉不到歌曲时，回退到用原始歌单的 global_collection_id 拉取
        // （收藏的歌单 listid 有时失效，用原始歌单的 listCreateGid 才能正确拉取
        final fallbackGid =
            widget.playlist.listCreateGid ??
            (widget.playlist.listCreateListid != null
                ? null
                : widget.playlist.id);
        if (all.isEmpty && fallbackGid != null && fallbackGid.isNotEmpty) {
          await context.read<KugouProvider>().getPlaylistTrackAll(
            id: fallbackGid,
            forceRefresh: true,
          );
          if (!mounted) return;
          all = context
              .read<KugouProvider>()
              .currentPlaylistSongs
              .map((e) => e.toSong())
              .toList();
        }
      } else if (widget.playlist.id.isNotEmpty) {
        // 未登录 或 无 listid：用 global_collection_id 调 /playlist/track/all 拉
        await context.read<KugouProvider>().getPlaylistTrackAll(
          id: widget.playlist.id,
          forceRefresh: true,
        );
        if (!mounted) return;
        all = context
            .read<KugouProvider>()
            .currentPlaylistSongs
            .map((e) => e.toSong())
            .toList();
      } else {
        // 普通歌单（未登录）：走 KugouProvider 的分页聚合（/playlist/track/all，30 一次翻页拉全）
        await context.read<KugouProvider>().getPlaylistTrackAll(
          id: widget.playlist.id,
          forceRefresh: true,
        );
        if (!mounted) return;
        all = context
            .read<KugouProvider>()
            .currentPlaylistSongs
            .map((e) => e.toSong())
            .toList();
      }

      setState(() {
        _songs = all.where((song) {
          final validTitle = song.title.isNotEmpty && song.title != '-';
          final validDuration = song.duration.inMilliseconds > 0;
          return validTitle && validDuration;
        }).toList();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final displayPlaylist = widget.playlist.copyWith(songs: _songs);

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _buildError(context, colorScheme)
          : Column(
              children: [
                Expanded(
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      SliverAppBar(
                        expandedHeight: 280,
                        pinned: true,
                        // pinned 后顶栏背景色：滚动到 expandedHeight - kToolbarHeight
                        // 之后从透明渐变到 surface
                        backgroundColor: Color.lerp(
                          Colors.transparent,
                          colorScheme.surface,
                          (_scrollOffset - (280 - kToolbarHeight))
                              .clamp(0.0, 60.0) / 60,
                        )!,
                        surfaceTintColor: Colors.transparent,
                        scrolledUnderElevation: 0,
                        // pinned 后顶栏标题：滚动超过阈值后 fade-in 显示歌单名称
                        title: Opacity(
                          opacity: ((_scrollOffset - (280 - kToolbarHeight)) /
                                  60.0)
                              .clamp(0.0, 1.0),
                          child: Text(
                            displayPlaylist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        flexibleSpace: FlexibleSpaceBar(
                          background: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  colorScheme.primaryContainer,
                                  colorScheme.surface,
                                ],
                              ),
                            ),
                            child: SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  48,
                                  24,
                                  16,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 140,
                                        height: 140,
                                        child:
                                            displayPlaylist.artworkUri != null
                                            ? CachedNetworkImage(
                                                imageUrl:
                                                    displayPlaylist.artworkUri!,
                                                fit: BoxFit.cover,
                                                placeholder: (_, _) => Container(
                                                  color: colorScheme
                                                      .surfaceContainerHighest,
                                                  child: Icon(
                                                    Icons.queue_music,
                                                    size: 48,
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                                errorWidget: (_, _, _) =>
                                                    Container(
                                                      color: colorScheme
                                                          .surfaceContainerHighest,
                                                      child: Icon(
                                                        Icons.queue_music,
                                                        size: 48,
                                                        color: colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                              )
                                            : Container(
                                                color: colorScheme
                                                    .surfaceContainerHighest,
                                                child: Icon(
                                                  Icons.queue_music,
                                                  size: 48,
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 20),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          Text(
                                            displayPlaylist.name,
                                            maxLines: 4,
                                            overflow: TextOverflow.ellipsis,
                                            style: textTheme.headlineSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                          ),
                                          if (displayPlaylist.description !=
                                              null) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              displayPlaylist.description!,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                          const SizedBox(height: 4),
                                          Text(
                                            '${displayPlaylist.creator ?? ''} · ${_songs.length} 首',
                                            style: textTheme.labelMedium
                                                ?.copyWith(
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () {
                                    if (_songs.isNotEmpty) {
                                      context
                                          .read<PlayerProvider>()
                                          .playOnlinePlaylist(_songs, 0);
                                    }
                                  },
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('播放全部'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    if (_songs.isNotEmpty) {
                                      final shuffled = List<Song>.from(_songs)
                                        ..shuffle();
                                      context
                                          .read<PlayerProvider>()
                                          .playOnlinePlaylist(shuffled, 0);
                                    }
                                  },
                                  icon: const Icon(Icons.shuffle),
                                  label: const Text('随机播放'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 红心收藏按钮：仅在「发现/热门歌单」等普通歌单显示
                              // （「我的收藏」里的歌单已是已收藏状态，外部「我的收藏」页有批量删除，
                              // 不需要再展示冗余的红心按钮）。
                              if (!widget.isInMyFavorites)
                                IconButton.filledTonal(
                                  onPressed: _isCollected
                                      ? _uncollectPlaylist
                                      : _collectPlaylist,
                                  icon: Icon(
                                    _isCollected
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: _isCollected
                                        ? colorScheme.error
                                        : null,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          return SongListItem(
                            song: _songs[index],
                            onTap: () {
                              context.read<PlayerProvider>().playOnlinePlaylist(
                                _songs,
                                index,
                              );
                            },
                            onMoreTap: () {},
                          );
                        }, childCount: _songs.length),
                      ),
                    ],
                  ),
                ),
                const MiniPlayer(),
              ],
            ),
    );
  }

  Widget _buildError(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '未知错误',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: _fetchSongs, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
