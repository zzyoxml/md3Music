import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../player/mv_player_page.dart';
import '../playlist/playlist_page.dart';

/// 编辑精选详情页。
///
/// 接收 [ipId]，提供 5 个类型 tab（音乐 / 专辑 / 视频 / 歌手 / 歌单）：
/// - 音乐/专辑/视频/歌手 → `/ip?id=xx&type=xxx`
/// - 歌单 → `/ip/playlist?id=xx`
/// 音乐 tab 顶部可选展示 `/ip/zone/home` 专区简介（可能为空，静默跳过）。
/// 各 tab 首次进入时懒加载，数据保存在页面本地 state。
class IpDetailPage extends StatefulWidget {
  final String ipId;
  final String? title;

  const IpDetailPage({super.key, required this.ipId, this.title});

  @override
  State<IpDetailPage> createState() => _IpDetailPageState();
}

class _IpDetailPageState extends State<IpDetailPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 5,
    vsync: this,
  )..addListener(_onTabChanged);
  int _lastTab = 0;

  // 各 tab 加载状态
  final List<bool> _loading = List.filled(5, false);
  final List<bool> _loaded = List.filled(5, false);

  // 各 tab 数据
  List<KugouSongDetail> _songs = [];
  List<KugouAlbumBrief> _albums = [];
  List<Map<String, dynamic>> _videos = [];
  List<KugouArtistBrief> _artists = [];
  List<KugouPlaylistBrief> _playlists = [];

  // /ip/zone/home 专区简介（音乐 tab 顶部展示，可能为空）
  Map<String, dynamic>? _zoneHome;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureLoaded(0);
      _loadZoneHome();
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index != _lastTab) {
      _lastTab = _tabController.index;
      _ensureLoaded(_lastTab);
    }
  }

  Future<void> _loadZoneHome() async {
    try {
      final r = await context
          .read<KugouProvider>()
          .apiClient
          .getIpZoneHome(widget.ipId);
      if (r != null && mounted) {
        setState(() => _zoneHome = r);
      }
    } catch (_) {}
  }

  /// 懒加载指定 tab 的数据（每个 tab 只拉一次）
  Future<void> _ensureLoaded(int index) async {
    if (_loaded[index] || _loading[index]) return;
    setState(() => _loading[index] = true);
    try {
      final api = context.read<KugouProvider>().apiClient;
      switch (index) {
        case 0:
          _songs = _parseSongs(await api.getIpData(widget.ipId, type: 'audios'));
        case 1:
          _albums = _parseAlbums(
            await api.getIpData(widget.ipId, type: 'albums'),
          );
        case 2:
          _videos = _parseVideos(
            await api.getIpData(widget.ipId, type: 'videos'),
          );
        case 3:
          _artists = _parseArtists(
            await api.getIpData(widget.ipId, type: 'author_list'),
          );
        case 4:
          _playlists = _parsePlaylists(await api.getIpPlaylist(widget.ipId));
      }
      if (mounted) {
        _loaded[index] = true;
        _loading[index] = false;
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        _loaded[index] = true;
        _loading[index] = false;
        setState(() {});
      }
    }
  }

  // ---------- 响应解析（防御：data 可能是 Map/List，list 字段名多变） ----------

  List<Map<String, dynamic>> _rawList(Map<String, dynamic>? r) {
    if (r == null) return const [];
    final d = r['data'];
    if (d is Map<String, dynamic>) {
      final list = d['list'] ?? d['info'] ?? d['songs'] ?? d['data'];
      if (list is List) return list.whereType<Map<String, dynamic>>().toList();
    }
    if (d is List) return d.whereType<Map<String, dynamic>>().toList();
    return const [];
  }

  /// 把 /ip 响应的嵌套结构（base/audio_info/album_info/authors）拍平成
  /// 顶层字段，供 KugouSongDetail 等模型的 fromJson 直接解析。
  Map<String, dynamic> _flattenItem(
    Map<String, dynamic> item, {
    List<String> sections = const ['base', 'audio_info', 'album_info'],
  }) {
    final flat = <String, dynamic>{};
    for (final key in sections) {
      final section = item[key];
      if (section is Map<String, dynamic>) {
        flat.addAll(section);
      }
    }
    return flat;
  }

  List<KugouSongDetail> _parseSongs(Map<String, dynamic>? r) => _rawList(r)
      .map((e) {
        try {
          // base(songname/author_name/album_audio_id) + audio_info(hash/timelength)
          // + album_info(cover) 合并后字段齐全
          return KugouSongDetail.fromJson(_flattenItem(e));
        } catch (_) {
          return null;
        }
      })
      .whereType<KugouSongDetail>()
      .where((s) => s.hash.isNotEmpty)
      .toList();

  List<KugouAlbumBrief> _parseAlbums(Map<String, dynamic>? r) => _rawList(r)
      .map((e) {
        try {
          final flat = _flattenItem(e, sections: const ['base']);
          // base.cover → cover_url（KugouAlbumBrief.fromJson 认 cover_url）
          flat['cover_url'] = flat['cover'];
          return KugouAlbumBrief.fromJson(flat);
        } catch (_) {
          return null;
        }
      })
      .whereType<KugouAlbumBrief>()
      .where((a) => a.id.isNotEmpty)
      .toList();

  List<KugouArtistBrief> _parseArtists(Map<String, dynamic>? r) => _rawList(r)
      .map((e) {
        try {
          final flat = _flattenItem(e, sections: const ['base']);
          // base.author_id / base.avatar → fromJson 认识的 singerid / imgurl
          flat['singerid'] = flat['author_id'];
          flat['imgurl'] = flat['avatar'];
          return KugouArtistBrief.fromJson(flat);
        } catch (_) {
          return null;
        }
      })
      .whereType<KugouArtistBrief>()
      .where((a) => a.id.isNotEmpty)
      .toList();

  List<Map<String, dynamic>> _parseVideos(Map<String, dynamic>? r) =>
      _rawList(r);

  List<KugouPlaylistBrief> _parsePlaylists(Map<String, dynamic>? r) =>
      _rawList(r)
          .map((e) {
            try {
              return KugouPlaylistBrief.fromJson(e);
            } catch (_) {
              return null;
            }
          })
          .whereType<KugouPlaylistBrief>()
          .where((p) => p.id.isNotEmpty)
          .toList();

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title?.isNotEmpty == true ? widget.title! : '编辑精选详情',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '音乐'),
            Tab(text: '专辑'),
            Tab(text: '视频'),
            Tab(text: '歌手'),
            Tab(text: '歌单'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSongsTab(),
          _buildAlbumsTab(),
          _buildVideosTab(),
          _buildArtistsTab(),
          _buildPlaylistsTab(),
        ],
      ),
    );
  }

  /// 通用加载中/空态包装
  Widget _wrapTab(int index, Widget Function() builder) {
    if (_loading[index]) {
      return const Center(child: M3ELoadingIndicator());
    }
    return builder();
  }

  /// 音乐 tab：专区简介（可选）+ 歌曲列表
  Widget _buildSongsTab() {
    return _wrapTab(0, () {
      final songs = _songs;
      if (songs.isEmpty && _zoneHome == null) return _empty('暂无音乐');
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_zoneHome != null) _buildZoneHeader(),
          ...List.generate(songs.length, (i) {
            return SongListItem(
              song: songs[i].toSong(),
              onTap: () => context.read<PlayerProvider>().playOnlinePlaylist(
                songs.map((e) => e.toSong()).toList(),
                i,
              ),
              onMoreTap: () {},
            );
          }),
        ],
      );
    });
  }

  /// /ip/zone/home 专区简介头部（无有效字段时不渲染）
  Widget _buildZoneHeader() {
    final data = _zoneHome?['data'];
    final m = data is Map<String, dynamic> ? data : _zoneHome;
    final title = _strOf(m, ['title', 'name']);
    final intro = _strOf(m, ['intro', 'desc', 'description']);
    final cover = _coverOf(m);
    if (title.isEmpty && cover == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cs.surfaceContainerLow,
      ),
      child: Row(
        children: [
          if (cover != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 72,
                height: 72,
                child: CachedNetworkImage(
                  imageUrl: cover,
                  memCacheWidth: 216,
                  memCacheHeight: 216,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.edit_note, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (intro.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    intro,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 专辑 tab：可捏合网格（与搜索页专辑 tab 一致）。
  /// Pad 模式默认 4 列，支持双指捏合调整列数（持久化）；非 Pad 固定 2 列。
  Widget _buildAlbumsTab() {
    return _wrapTab(1, () {
      final albums = _albums;
      if (albums.isEmpty) return _empty('暂无专辑');
      final cs = Theme.of(context).colorScheme;
      return PinchableGridView(
        padding: const EdgeInsets.all(12),
        spacing: 12.0,
        childAspectRatio: 0.78,
        itemCount: albums.length,
        itemBuilder: (context, i) {
          final album = albums[i];
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: cs.surfaceContainerLow,
              child: InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AlbumDetailPage(album: album.toAlbum()),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: album.coverUrl != null
                          ? CachedNetworkImage(
                              imageUrl: album.coverUrl!,
                              memCacheWidth: 540,
                              memCacheHeight: 540,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              errorWidget: (_, _, _) => _coverPlaceholder(cs),
                            )
                          : _coverPlaceholder(cs),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      child: Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    });
  }

  /// 视频 tab：封面 + 标题 + 时长列表，点击进入 MvPlayerPage 播放
  Widget _buildVideosTab() {
    return _wrapTab(2, () {
      final videos = _videos;
      if (videos.isEmpty) return _empty('暂无视频');
      final cs = Theme.of(context).colorScheme;
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: videos.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final v = videos[i];
          // /ip type=videos 的字段在 base 内（mv_name/thumb/hdpic/duration）
          final base = v['base'];
          final b = base is Map<String, dynamic> ? base : const <String, dynamic>{};
          final title = _strOf(
            b,
            ['mv_name', 'name', 'title', 'video_name'],
          );
          final cover = _coverOf(b) ?? _coverOf(v);
          final duration = _formatDuration(b['duration'] ?? v['duration']);
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _playVideo(b, title, cover),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 72,
                    height: 48,
                    child: cover != null
                        ? CachedNetworkImage(
                            imageUrl: cover,
                            memCacheWidth: 216,
                            memCacheHeight: 144,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) =>
                                _coverPlaceholder(cs, radius: 0),
                          )
                        : _coverPlaceholder(cs, radius: 0),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (duration.isNotEmpty)
                  Text(
                    duration,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          );
        },
      );
    });
  }

  /// 点击视频：构造带 albumAudioId 的 Song，复用 MvPlayerPage 的
  /// /kmr/audio/mv → /video/detail → /video/url 完整加载链。
  void _playVideo(Map<String, dynamic> b, String title, String? cover) {
    final albumAudioId = b['album_audio_id']?.toString();
    if (albumAudioId == null || albumAudioId.isEmpty) {
      showToast('该视频无法播放', long: true);
      return;
    }
    final song = Song(
      id: b['video_id']?.toString() ?? '',
      title: title,
      artist: _strOf(b, ['singer', 'user_name', 'artist']),
      album: '',
      duration: Duration(
        milliseconds: (int.tryParse(b['duration']?.toString() ?? '') ?? 0),
      ),
      albumAudioId: albumAudioId,
      artworkUri: cover,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
    );
  }

  /// 歌手 tab：歌手列表
  Widget _buildArtistsTab() {
    return _wrapTab(3, () {
      final artists = _artists;
      if (artists.isEmpty) return _empty('暂无歌手');
      return ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: artists.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, i) {
          final artist = artists[i];
          return ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                width: 48,
                height: 48,
                child: artist.avatarUrl != null
                    ? CachedNetworkImage(
                        imageUrl: artist.avatarUrl!,
                        memCacheWidth: 144,
                        memCacheHeight: 144,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.person,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Container(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            title: Text(
              artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(
                alpha: 0.5,
              ),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtistDetailPage(
                  artistId: artist.id,
                  artistName: artist.name,
                  avatarUrl: artist.avatarUrl,
                ),
              ),
            ),
          );
        },
      );
    });
  }

  /// 歌单 tab：歌单列表
  Widget _buildPlaylistsTab() {
    return _wrapTab(4, () {
      final playlists = _playlists;
      if (playlists.isEmpty) return _empty('暂无歌单');
      final cs = Theme.of(context).colorScheme;
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: playlists.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final p = playlists[i];
          return Material(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaylistPage(playlist: p.toPlaylist()),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: p.coverUrl != null
                            ? CachedNetworkImage(
                                imageUrl: p.coverUrl!,
                                memCacheWidth: 168,
                                memCacheHeight: 168,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) =>
                                    _coverPlaceholder(cs, radius: 0),
                              )
                            : _coverPlaceholder(cs, radius: 0),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (p.songCount > 0)
                      Text(
                        '${p.songCount} 首',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    });
  }

  Widget _empty(String text) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox_outlined, size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs, {double radius = 12}) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant, size: 24),
      ),
    );
  }

  // ---------- 防御性字段解析 ----------

  String _strOf(Map<String, dynamic>? m, List<String> keys) {
    if (m == null) return '';
    for (final key in keys) {
      final v = m[key];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return '';
  }

  String? _coverOf(Map<String, dynamic>? m) {
    if (m == null) return null;
    for (final key in [
      'img_url',
      'cover_url',
      'img',
      'cover',
      'pic',
      'ImgUrl',
      'thumb',
      'hdpic',
      'icon',
      'image_url',
      'sizable_image_url',
    ]) {
      final v = m[key];
      if (v is String && v.isNotEmpty) return v.replaceAll('{size}', '400');
    }
    return null;
  }

  String _formatDuration(dynamic v) {
    final s = int.tryParse(v?.toString() ?? '');
    if (s == null || s <= 0) return '';
    // 单位可能是毫秒或秒
    final totalSec = s > 10000 ? s ~/ 1000 : s;
    final mm = totalSec ~/ 60;
    final ss = totalSec % 60;
    return '$mm:${ss.toString().padLeft(2, '0')}';
  }
}
