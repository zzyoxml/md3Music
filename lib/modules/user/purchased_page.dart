import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../player/mini_player.dart';

/// 「已购」页：单曲 / 专辑两个 Tab。
///
/// 数据来自酷狗已购接口（需登录）：
/// - 单曲：/user/purchased/songs
/// - 专辑：/user/purchased/albums
///
/// 酷狗返回 JSON 字段结构不固定，这里采用**自适应多字段解析**：
/// 优先复用 KugouSongDetail / KugouAlbumBrief 的多兜底解析，
/// 失败时回退到宽松字段映射，并兼容多种返回形状（info/audio_list/list/...）。
class PurchasedPage extends StatefulWidget {
  const PurchasedPage({super.key});

  @override
  State<PurchasedPage> createState() => _PurchasedPageState();
}

class _PurchasedPageState extends State<PurchasedPage> {
  static const int _tabSongs = 0;
  static const int _tabAlbums = 1;

  int _currentTab = _tabSongs;
  bool _isLoading = true;
  String? _error;

  List<Song> _songs = [];
  List<Album> _albums = [];
  bool _songsLoaded = false;
  bool _albumsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  void _switchTab(int tab) {
    if (_currentTab == tab) return;
    setState(() => _currentTab = tab);
    if (tab == _tabAlbums && !_albumsLoaded) {
      _loadAlbums();
    } else if (tab == _tabSongs && !_songsLoaded) {
      _loadSongs();
    }
  }

  Future<void> _loadSongs() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final api = KugouApiClient();
      if (!api.isLoggedIn) {
        _finishLoad(error: '请先登录');
        return;
      }
      final result =
          await api.getUserPurchasedSongs(page: 1, pagesize: 50, noCache: true);
      if (!mounted) return;
      if (result == null) {
        _finishLoad(error: '加载失败，请稍后重试');
        return;
      }
      final raw = _extractList(result);
      final songs = _parseSongs(raw);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _songsLoaded = true;
        _isLoading = false;
      });
    } catch (e) {
      _finishLoad(error: '加载失败，请稍后重试');
    }
  }

  Future<void> _loadAlbums() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final api = KugouApiClient();
      if (!api.isLoggedIn) {
        _finishLoad(error: '请先登录');
        return;
      }
      final result =
          await api.getUserPurchasedAlbums(page: 1, pagesize: 15, noCache: true);
      if (!mounted) return;
      if (result == null) {
        _finishLoad(error: '加载失败，请稍后重试');
        return;
      }
      final raw = _extractList(result);
      final albums = _parseAlbums(raw);
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _albumsLoaded = true;
        _isLoading = false;
      });
    } catch (e) {
      _finishLoad(error: '加载失败，请稍后重试');
    }
  }

  void _finishLoad({String? error}) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _error = error;
    });
  }

  // ==================== 自适应解析 ====================

  /// 从响应中提取列表；兼容多种返回形状。
  List<dynamic> _extractList(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is List) return data;
    if (data is Map<String, dynamic>) {
      for (final key in ['info', 'audio_list', 'list', 'songs', 'album_list', 'albums', 'data']) {
        final v = data[key];
        if (v is List) return v;
      }
    }
    return const [];
  }

  List<Song> _parseSongs(List<dynamic> raw) {
    final out = <Song>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      Song? s;
      try {
        final d = KugouSongDetail.fromJson(e);
        final song = d.toSong();
        if (song.id.isNotEmpty) s = song;
      } catch (_) {}
      s ??= _fallbackSong(e);
      if (s != null && s.id.isNotEmpty) out.add(s);
    }
    return out;
  }

  /// 宽松字段映射兜底（获取已购单曲字段名与标准搜索不同时可用）。
  Song? _fallbackSong(Map<String, dynamic> item) {
    final hash = (item['hash'] ?? item['Hash'] ?? item['fileHash'] ?? item['audio_hash'] ?? '')
        .toString();
    if (hash.isEmpty) return null;
    final title = (item['songname'] ??
            item['songName'] ??
            item['audio_name'] ??
            item['FileName'] ??
            item['filename'] ??
            '')
        .toString();
    final artist = (item['singername'] ?? item['singerName'] ?? item['author_name'] ?? '')
        .toString();
    final album = (item['album_name'] ?? item['albumName'] ?? '').toString();
    final dur = item['duration'] ?? item['timelength'] ?? item['time_length'] ?? 0;
    int ms = 0;
    if (dur is num) {
      ms = dur.toInt();
      if (ms > 0 && ms < 1000) ms *= 1000; // 秒 → 毫秒
    }
    return Song(
      id: hash,
      title: title.isEmpty ? '未知歌曲' : title,
      artist: artist.isEmpty ? '未知歌手' : artist,
      album: album,
      duration: Duration(milliseconds: ms),
      isOnline: true,
      albumId: (item['album_id'] ?? item['albumId'] ?? '').toString(),
      albumAudioId: (item['album_audio_id'] ??
              item['AlbumAudioID'] ??
              item['mixsongid'] ??
              '')
          .toString(),
      artworkUri: _resolveCover(item),
    );
  }

  List<Album> _parseAlbums(List<dynamic> raw) {
    final out = <Album>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      Album? a;
      try {
        final b = KugouAlbumBrief.fromJson(e);
        if (b.id.isNotEmpty) a = b.toAlbum();
      } catch (_) {}
      a ??= _fallbackAlbum(e);
      if (a != null) out.add(a);
    }
    return out;
  }

  /// 宽松专辑映射兜底。
  Album? _fallbackAlbum(Map<String, dynamic> item) {
    final id = (item['album_id'] ?? item['albumid'] ?? item['AlbumID'] ?? item['id'] ?? '')
        .toString();
    if (id.isEmpty) return null;
    final name = (item['album_name'] ?? item['AlbumName'] ?? item['name'] ?? '').toString();
    final artist =
        (item['singername'] ?? item['artist_name'] ?? item['author_name'] ?? '').toString();
    return Album(
      id: id,
      name: name.isEmpty ? '未知专辑' : name,
      artist: artist,
      artworkUri: _resolveCover(item),
      songCount: 0,
    );
  }

  String? _resolveCover(Map<String, dynamic> m) {
    final v = m['sizable_cover'] ??
        m['img'] ??
        m['imgurl'] ??
        m['cover'] ??
        m['pic'] ??
        m['Image'] ??
        m['ImgUrl'] ??
        m['cover_url'];
    if (v == null) return null;
    final s = v.toString();
    if (s.isEmpty) return null;
    if (s.startsWith('//')) return 'https:$s';
    return s;
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('已购'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: M3EToggleButtonGroup(
              actions: const [
                M3EToggleButtonGroupAction(label: Text('单曲')),
                M3EToggleButtonGroupAction(label: Text('专辑')),
              ],
              selectedIndex: _currentTab,
              onSelectedIndexChanged: (index) {
                if (index != null) _switchTab(index);
              },
            ),
          ),
        ),
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_isLoading) return const Center(child: M3ELoadingIndicator());
    if (_error != null) return _buildMessage(cs, _error!, Icons.error_outline);
    if (_currentTab == _tabSongs) {
      if (_songs.isEmpty) return _buildMessage(cs, '暂无已购单曲', Icons.music_note);
      return Column(
        children: [
          _buildSongsHeader(cs),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: _songs.length,
              itemBuilder: (context, index) {
                return SongListItem(
                  song: _songs[index],
                  onTap: () => _playAt(index),
                  onMoreTap: () {},
                );
              },
            ),
          ),
          const MiniPlayer(),
        ],
      );
    }
    // 专辑 Tab
    if (_albums.isEmpty) return _buildMessage(cs, '暂无已购专辑', Icons.album_outlined);
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            itemCount: _albums.length,
            itemBuilder: (context, i) => _buildAlbumCard(cs, i),
          ),
        ),
        const MiniPlayer(),
      ],
    );
  }

  Widget _buildSongsHeader(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '共 ${_songs.length} 首',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (_songs.isNotEmpty)
            TextButton.icon(
              onPressed: () => _playAt(0),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
        ],
      ),
    );
  }

  Widget _buildAlbumCard(ColorScheme cs, int i) {
    final album = _albums[i];
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: cs.surfaceContainerLow,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: album.artworkUri != null
                    ? CachedNetworkImage(
                        imageUrl: album.artworkUri!,
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
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.album, size: 48)),
    );
  }

  Widget _buildMessage(ColorScheme cs, String text, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _playAt(int index) {
    if (_songs.isEmpty) return;
    context.read<PlayerProvider>().playOnlinePlaylist(_songs, index);
  }
}