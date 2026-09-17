import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../player/mv_player_page.dart';
import 'brush_vertical_page.dart';
import '../../widgets/scroll_aware_app_bar.dart';

/// 「刷刷」页：展示 /brush 返回的推荐 feed 卡片列表。
///
/// 采用普通列表卡片形态（先跑通再升级全屏）。下拉刷新重新拉取。
/// 卡片字段由 /brush（genesisapi feed）返回，结构不定，做自适应解析：
/// 优先取直接的 video_url 播放视频，否则尝试构建 Song 播放。
class BrushPage extends StatefulWidget {
  const BrushPage({super.key});

  @override
  State<BrushPage> createState() => _BrushPageState();
}

class BrushCard {
  final String title;
  final String? subtitle;
  final String? coverUrl;
  final String? videoUrl;
  final Song? song;

  const BrushCard({
    required this.title,
    this.subtitle,
    this.coverUrl,
    this.videoUrl,
    this.song,
  });
}

class _BrushPageState extends State<BrushPage> {
  List<BrushCard> _cards = [];
  bool _isLoading = true;
  bool _loadingMore = false;
  String? _error;
  /// 下次请求的批次游标（刷刷 feed 用 page 作为游标，每次随机返回 0~3 条）。
  int _nextPage = 1;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// 下拉刷新：从 page=1 起连续请求多批，合并去重凑够一屏。
  /// 已有数据时静默刷新（不闪 loading，与发现页一致），仅首次加载显示 loading。
  Future<void> _load() async {
    final hasExisting = _cards.isNotEmpty;
    if (mounted) {
      setState(() {
        if (!hasExisting) _isLoading = true;
        _error = null;
      });
    }
    try {
      final res = await _fetchPages(startPage: 1, minCount: 8, maxPages: 4);
      if (!mounted) return;
      setState(() {
        _cards = res.cards;
        _nextPage = 1 + res.consumed;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[Brush] error=$e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        // 已有数据时刷新失败不覆盖现有列表
        if (!hasExisting) _error = '加载失败，请稍后重试';
      });
    }
  }

  /// 上拉加载更多：从 _nextPage 起再请求几批，追加去重。
  Future<void> _loadMore() async {
    if (_isLoading || _loadingMore) return;
    _loadingMore = true;
    try {
      final res = await _fetchPages(startPage: _nextPage, minCount: 4, maxPages: 3);
      if (!mounted) return;
      setState(() {
        _cards = _merge(_cards, res.cards);
        _nextPage += res.consumed;
      });
    } catch (e) {
      debugPrint('[Brush] loadMore error=$e');
    } finally {
      _loadingMore = false;
    }
  }

  /// 供竖屏视频流页滑到末尾时加载更多：推进 page 游标并返回新卡片（不直接改列表）。
  Future<List<BrushCard>> _loadMoreForVertical() async {
    if (_isLoading) return const [];
    final res = await _fetchPages(startPage: _nextPage, minCount: 3, maxPages: 2);
    _nextPage += res.consumed;
    return res.cards;
  }

  /// 打开竖屏视频流，复用当前已加载的卡片。
  void _openVertical() {
    if (_cards.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BrushVerticalPage(
          cards: List.of(_cards),
          fetchMore: _loadMoreForVertical,
        ),
      ),
    );
  }

  /// 从 startPage 起连续请求若干批，按歌名去重，直到凑够 minCount 或达到 maxPages 次。
  Future<({List<BrushCard> cards, int consumed})> _fetchPages({
    required int startPage,
    required int minCount,
    required int maxPages,
  }) async {
    final result = <BrushCard>[];
    final seen = <String>{};
    var consumed = 0;
    for (var i = 0; i < maxPages; i++) {
      final page = startPage + i;
      final r = await KugouApiClient().getBrush(page: page);
      debugPrint('[Brush] page=$page raw=$r');
      consumed++;
      for (final c in _parseFeed(r)) {
        if (seen.add(c.title)) result.add(c);
      }
      if (result.length >= minCount) break;
    }
    debugPrint('[Brush] fetchPages(start=$startPage)=${result.length} consumed=$consumed');
    return (cards: result, consumed: consumed);
  }

  /// 将新批次合并到已有列表，按歌名去重。
  List<BrushCard> _merge(List<BrushCard> base, List<BrushCard> added) {
    final seen = base.map((c) => c.title).toSet();
    final out = [...base];
    for (final c in added) {
      if (seen.add(c.title)) out.add(c);
    }
    return out;
  }

  /// 从 /brush 响应中自适应提取 feed 卡片列表。
  List<BrushCard> _parseFeed(Map<String, dynamic>? r) {
    if (r == null) return const [];
    final d = r['data'];
    List<dynamic> raw = const [];
    if (d is Map<String, dynamic>) {
      final list = d['feed'] ?? d['dataset'] ?? d['list'] ?? d['items'] ?? d['data'];
      if (list is List) raw = list;
    } else if (d is List) {
      raw = d;
    }
    final out = <BrushCard>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final c = _mapCard(e);
      if (c != null) out.add(c);
    }
    return out;
  }

  /// 单条 feed 卡片映射。
  BrushCard? _mapCard(Map<String, dynamic> item) {
    // 部分卡片把内容嵌套在 video/audio/song/feed 字段里
    final Map<String, dynamic> body = () {
      for (final key in ['video', 'audio', 'song', 'feed', 'content']) {
        final v = item[key];
        if (v is Map<String, dynamic> && v.isNotEmpty) return v;
      }
      return item;
    }();

    final title = _str(body, ['video_name', 'title', 'name', 'songname', 'song_name', 'audio_name', 'intro'])
        ?.replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    if (title == null || title.isEmpty) return null;

    final cover = _coverOf(body, item);
    final subtitle = _str(body, ['user_name', 'author_name', 'singer_name', 'singername', 'desc'])
        ?.replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();

    // 直接视频地址（优先），不命中再从 hp_mv_info 嵌套结构提取
    final videoUrl = _str(body, ['video_url', 'play_url', 'url', 'mp4_url', 'src']) ??
        _nestedVideoUrl(item);
    final videoHash = _str(body, ['video_hash', 'hash', 'mv_hash']);

    // 尝试构建可播放 Song；hash 可能在 song_extra.audio_info 里
    Song? song;
    var rawHash = body['hash'] ?? body['audio_hash'];
    if ((rawHash == null || rawHash.toString().isEmpty) &&
        body['song_extra'] is Map<String, dynamic>) {
      final audioInfo = (body['song_extra'] as Map)['audio_info'];
      if (audioInfo is Map<String, dynamic>) rawHash = audioInfo['hash'];
    }
    final hash = (rawHash ?? '').toString();
    if (hash.isNotEmpty) {
      song = Song(
        id: hash,
        title: title,
        artist: subtitle ?? '',
        album: '',
        duration: Duration.zero,
        isOnline: true,
        albumId: (body['album_id'] ?? '').toString(),
        albumAudioId: (body['album_audio_id'] ?? body['mixsongid'] ?? '').toString(),
        artworkUri: cover,
      );
    }

    if (videoUrl == null && videoHash == null && song == null) return null;
    // 酷狗视频地址为 http 明文；Android 明文策略仅放行本地回环，统一转 https
    // 避免 VideoError ... Source error
    final playUrl = videoUrl != null && videoUrl.startsWith('http://')
        ? videoUrl.replaceFirst('http://', 'https://')
        : videoUrl;
    return BrushCard(
      title: title,
      subtitle: subtitle,
      coverUrl: cover,
      videoUrl: playUrl,
      song: song,
    );
  }

  /// 从刷刷 feed 的 hp_mv_info 嵌套结构提取可直接播放的视频地址。
  /// 优先取 mv_info.preview.url（预览），其次 play_info.src_file.h264.play_url。
  String? _nestedVideoUrl(Map<String, dynamic> item) {
    final hp = item['hp_mv_info'];
    if (hp is! Map<String, dynamic>) return null;

    final mvInfo = hp['mv_info'];
    if (mvInfo is Map<String, dynamic>) {
      final preview = mvInfo['preview'];
      if (preview is Map<String, dynamic>) {
        final u = preview['url'];
        if (u != null && u.toString().isNotEmpty) return u.toString();
      }
    }

    final playInfo = hp['play_info'];
    if (playInfo is Map<String, dynamic>) {
      final srcFile = playInfo['src_file'];
      if (srcFile is Map<String, dynamic>) {
        final h264 = srcFile['h264'];
        if (h264 is Map<String, dynamic>) {
          final u = h264['play_url'];
          if (u != null && u.toString().isNotEmpty) return u.toString();
        }
      }
    }
    return null;
  }

  String? _str(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return null;
  }

  String? _coverOf(Map<String, dynamic> body, Map<String, dynamic> item) {
    final v = body['cover'] ??
        body['cover_url'] ??
        body['album_cover'] ??
        body['author_cover'] ??
        body['img'] ??
        body['pic'] ??
        body['flexible_cover'] ??
        item['cover'] ??
        item['img'] ??
        (item['cover_info'] is Map<String, dynamic>
            ? (item['cover_info'] as Map)['first_frame_img']
            : null);
    if (v == null) return null;
    var s = v.toString();
    if (s.isEmpty) return null;
    if (s.startsWith('//')) s = 'https:$s';
    s = s.replaceAll('{size}', '200');
    return s;
  }

  void _playCard(BrushCard card) {
    if (card.videoUrl != null && card.videoUrl!.isNotEmpty) {
      final song = card.song ??
          Song(
            id: card.title,
            title: card.title,
            artist: card.subtitle ?? '',
            album: '',
            duration: Duration.zero,
            isOnline: true,
            artworkUri: card.coverUrl,
          );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MvPlayerPage(song: song, directVideoUrl: card.videoUrl),
        ),
      );
      return;
    }
    if (card.song != null) {
      context.read<PlayerProvider>().playOnlineSong(card.song!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '刷刷',
        opaque: true,
        scrollController: _scrollController,
        actions: [
          IconButton(
            onPressed: _openVertical,
            tooltip: '竖屏模式',
            icon: const Icon(Icons.smartphone),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _error != null
              ? _buildMessage(cs, _error!, Icons.error_outline)
              : _cards.isEmpty
                  ? _buildMessage(cs, '暂无内容', Icons.video_library_outlined)
                  : Md3PullToRefresh(
                      onRefresh: _load,
                      child: ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: _cards.length + 1,
                        itemBuilder: (context, i) {
                          if (i == _cards.length) {
                            return _loadingMore
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 16),
                                    child: Center(
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: M3ECircularProgressIndicator(size: 22, strokeWidth: 2),
                                      ),
                                    ),
                                  )
                                : const SizedBox(height: 8);
                          }
                          return _buildCard(cs, _cards[i]);
                        },
                      ),
                    ),
    );
  }

  Widget _buildCard(ColorScheme cs, BrushCard card) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: card.coverUrl != null
              ? CachedNetworkImage(
                  imageUrl: card.coverUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => _placeholder(cs),
                )
              : _placeholder(cs),
        ),
      ),
      title: Text(
        card.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: card.subtitle != null && card.subtitle!.isNotEmpty
          ? Text(card.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: Icon(
        card.videoUrl != null ? Icons.play_circle_outline : Icons.music_note,
        color: cs.primary,
      ),
      onTap: () => _playCard(card),
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.music_note, color: Colors.grey)),
    );
  }

  Widget _buildMessage(ColorScheme cs, String text, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}