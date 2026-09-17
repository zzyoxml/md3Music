import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/song_list_item.dart';
import '../login/login_page.dart';
import '../player/mini_player.dart';
import 'channel_story_detail_page.dart';

/// 音乐故事条目（/youth/channel/song 列表项）。
///
/// 兼容两种结构：平铺歌曲字段，或 story 帖（含嵌套 files 音频数组）。
class _ChannelStory {
  final String fileId; // 故事 fileid，用于下钻详情
  final String title;
  final String? coverUrl;
  final String? desc;
  final KugouSongDetail? song; // hash 非空才可播放

  const _ChannelStory({
    required this.fileId,
    required this.title,
    this.coverUrl,
    this.desc,
    this.song,
  });
}

/// 安利板块（/youth/channel/amway）解析结果。
class _AmwayInfo {
  final String title;
  final String content;
  final String? coverUrl;
  final List<KugouSongDetail> songs;

  const _AmwayInfo({
    this.title = '',
    this.content = '',
    this.coverUrl,
    this.songs = const [],
  });

  bool get isEmpty => title.isEmpty && content.isEmpty && songs.isEmpty;
}

/// 频道详情页。
///
/// 并行加载：频道详情（detail）+ 安利（amway）+ 音乐故事（song，分页）+
/// 相似频道（similar）。支持订阅/取消订阅（sub）。
class ChannelDetailPage extends StatefulWidget {
  final KugouYouthChannel channel;

  const ChannelDetailPage({super.key, required this.channel});

  @override
  State<ChannelDetailPage> createState() => _ChannelDetailPageState();
}

class _ChannelDetailPageState extends State<ChannelDetailPage> {
  static const int _pageSize = 30;

  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;

  // 头部
  String _name = '';
  String? _coverUrl;
  String? _desc;
  bool _subscribed = true;

  _AmwayInfo _amway = const _AmwayInfo();
  List<_ChannelStory> _stories = [];
  List<KugouYouthChannel> _similar = [];

  @override
  void initState() {
    super.initState();
    _name = widget.channel.name;
    _coverUrl = widget.channel.coverUrl;
    _desc = widget.channel.desc;
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    await _loadSongs(reset: false);
    _loadingMore = false;
  }

  /// 首次加载：并行请求 detail / amway / song(第1页) / similar。
  /// 单个接口失败（超时/上游错误）不阻塞整体，失败项降级为 null。
  Future<void> _load({bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => _isLoading = true);
    final api = KugouApiClient();
    final id = widget.channel.id;
    final results = await Future.wait([
      _safe(() => api.getYouthChannelDetail(id)),
      _safe(() => api.getYouthChannelAmway(id)),
      _safe(
        () => api.getYouthChannelSong(id, page: 1, pagesize: _pageSize),
      ),
      _safe(() => api.getYouthChannelSimilar(id)),
    ]);
    if (!mounted) return;

    // 详情头部：detail 的 data 可能是 List（单元素频道对象）或 Map
    final detail = results[0];
    final d = detail?['data'];
    final detailObj = d is Map<String, dynamic>
        ? d
        : (d is List && d.isNotEmpty && d.first is Map<String, dynamic>
            ? d.first as Map<String, dynamic>
            : null);
    if (detailObj != null) {
      final info = KugouYouthChannel.fromJson(detailObj);
      if (info.name.isNotEmpty) _name = info.name;
      if (info.coverUrl != null && info.coverUrl!.isNotEmpty) {
        _coverUrl = info.coverUrl;
      }
      if (info.desc != null && info.desc!.isNotEmpty) _desc = info.desc;
      // 订阅状态：字段名不确定，防御式解析
      final sub = detailObj['is_subscribe'] ??
          detailObj['subscribe'] ??
          detailObj['is_sub'] ??
          detailObj['sub_status'] ??
          detailObj['subscribe_status'];
      if (sub != null) {
        _subscribed = sub is bool ? sub : sub.toString() == '1';
      }
    }

    _amway = _parseAmway(results[1]);
    _similar = _parseSimilar(results[3]);

    // 音乐故事第 1 页
    _page = 1;
    _hasMore = true;
    _stories = _parseStories(results[2]);

    setState(() => _isLoading = false);
  }

  /// 音乐故事分页加载。
  Future<void> _loadSongs({required bool reset}) async {
    if (reset) {
      _page = 1;
      _hasMore = true;
    }
    Map<String, dynamic>? r;
    try {
      r = await KugouApiClient().getYouthChannelSong(
        widget.channel.id,
        page: _page,
        pagesize: _pageSize,
      );
    } catch (_) {
      r = null;
    }
    final parsed = _parseStories(r);
    if (!mounted) return;
    setState(() {
      if (reset) {
        _stories = parsed;
      } else {
        _stories.addAll(parsed);
      }
      _hasMore = parsed.length >= _pageSize;
      _page++;
    });
  }

  /// 容错包装：接口异常返回 null，避免 Future.wait 整体失败。
  Future<Map<String, dynamic>?> _safe(
    Future<Map<String, dynamic>?> Function() f,
  ) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  // ─────────────────── 防御式解析 ───────────────────

  String _str(dynamic v) => v?.toString().trim() ?? '';

  /// 从响应中提取列表（data 可能是 Map 或 List，list 字段名多变）
  List<dynamic> _listOf(Map<String, dynamic>? json) {
    if (json == null) return const [];
    final d = json['data'];
    if (d is Map<String, dynamic>) {
      final l = d['list'] ?? d['info'] ?? d['items'] ?? d['channels'];
      if (l is List) return l;
    }
    if (d is List) return d;
    final l = json['list'] ?? json['info'];
    if (l is List) return l;
    return const [];
  }

  List<_ChannelStory> _parseStories(Map<String, dynamic>? json) {
    final out = <_ChannelStory>[];
    for (final e in _listOf(json)) {
      if (e is! Map<String, dynamic>) continue;
      final story = _parseStory(e);
      if (story != null) out.add(story);
    }
    return out;
  }

  _ChannelStory? _parseStory(Map<String, dynamic> json) {
    try {
      final fileId = _str(
        json['fileid'] ?? json['file_id'] ?? json['post_id'] ?? json['id'],
      );
      final title =
          _str(
            json['title'] ??
                json['name'] ??
                json['songname'] ??
                json['ori_audio_name'] ??
                json['post_title'] ??
                json['content_title'],
          );
      final cover = _str(
        json['img'] ??
            json['imgurl'] ??
            json['cover'] ??
            json['pic'] ??
            json['channel_pic'],
      );
      final desc = _str(
        json['desc'] ?? json['description'] ?? json['content'],
      );

      // 歌曲：优先平铺字段，story 帖结构则取 files 首个音频
      KugouSongDetail? song;
      final direct = KugouSongDetail.fromJson(json);
      if (direct.hash.isNotEmpty) {
        song = direct;
      } else {
        for (final k in ['files', 'audio', 'songs', 'audio_list']) {
          final arr = json[k];
          if (arr is! List) continue;
          for (final item in arr) {
            if (item is Map<String, dynamic>) {
              final s = KugouSongDetail.fromJson(item);
              if (s.hash.isNotEmpty) {
                song = s;
                break;
              }
            }
          }
          if (song != null) break;
        }
      }
      // 无任何可展示信息则丢弃
      if (title.isEmpty && song == null) return null;
      return _ChannelStory(
        fileId: fileId,
        title: title.isNotEmpty ? title : (song?.songName ?? ''),
        coverUrl: cover.isNotEmpty ? cover : song?.artworkUri,
        desc: desc.isNotEmpty ? desc : song?.artistName,
        song: song,
      );
    } catch (_) {
      // 单个 story 结构异常（如 song 接口的字段类型不兼容）时跳过，
      // 避免中断整个列表加载
      return null;
    }
  }

  List<KugouYouthChannel> _parseSimilar(Map<String, dynamic>? json) {
    final out = <KugouYouthChannel>[];
    for (final e in _listOf(json)) {
      if (e is! Map<String, dynamic>) continue;
      final c = KugouYouthChannel.fromJson(e);
      if (c.id.isNotEmpty && c.id != widget.channel.id) out.add(c);
    }
    return out;
  }

  _AmwayInfo _parseAmway(Map<String, dynamic>? json) {
    if (json == null) return const _AmwayInfo();
    final texts = <String>[];
    String? cover;
    final songs = <KugouSongDetail>[];
    final seenHash = <String>{};

    // 递归扫描未知结构：收集文案字段 / 封面 / 歌曲数组
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

    scan(json);
    // 文案合并去重（保持顺序）
    final unique = <String>{};
    final content = texts.where((t) => unique.add(t)).join('\n');
    return _AmwayInfo(
      title: '安利',
      content: content,
      coverUrl: cover,
      songs: songs,
    );
  }

  // ─────────────────── 交互 ───────────────────

  Future<void> _toggleSubscribe() async {
    if (!KugouApiClient().isLoggedIn) {
      _showLoginRequiredDialog();
      return;
    }
    final target = !_subscribed;
    try {
      final r = await KugouApiClient().subscribeYouthChannel(
        widget.channel.id,
        t: target ? 1 : 0,
      );
      if (!mounted) return;
      final status = r?['status'];
      final success = status == 1 || status == 200 || r?['error_code'] == 0;
      setState(() => _subscribed = success ? target : _subscribed);
      showToast(
        success ? (target ? '已订阅' : '已取消订阅') : '操作失败',
        long: true,
      );
    } catch (_) {
      if (mounted) {
        showToast('操作失败', long: true);
      }
    }
  }

  void _showLoginRequiredDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请先登录'),
        content: const Text('该操作需要登录账号，是否前往登录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
            },
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  /// 播放音乐故事整表（仅含可播放项）。
  void _playStories(List<_ChannelStory> stories, int index) {
    final playable = stories.where((s) => s.song != null).toList();
    if (playable.isEmpty) return;
    // 找到当前条目在可播放列表中的位置
    final target = stories[index];
    var start = playable.indexWhere((s) => identical(s, target));
    if (start < 0) start = 0;
    context.read<PlayerProvider>().playOnlinePlaylist(
      playable.map((s) => s.song!.toSong()).toList(),
      start,
    );
  }

  void _openStoryDetail(_ChannelStory story) {
    if (story.fileId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChannelStoryDetailPage(
          channelId: widget.channel.id,
          fileId: story.fileId,
          title: story.title,
        ),
      ),
    );
  }

  // ─────────────────── UI ───────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: _name,
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
                  _buildHeader(context),
                  if (!_amway.isEmpty) _buildAmway(context),
                  _buildStoriesHeader(context),
                  ..._stories.map(
                    (s) => _buildStoryTile(context, s),
                  ),
                  if (_loadingMore)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: M3ECircularProgressIndicator(size: 24, strokeWidth: 2),
                        ),
                      ),
                    ),
                  if (_similar.isNotEmpty) _buildSimilar(context),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: _coverUrl != null
                ? CachedNetworkImage(
                    imageUrl: _coverUrl!,
                    memCacheWidth: 330,
                    memCacheHeight: 330,
                    width: 110,
                    height: 110,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => _coverPlaceholder(cs),
                  )
                : _coverPlaceholder(cs),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (_desc != null && _desc!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _desc!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _subscribed
                    ? OutlinedButton.icon(
                        onPressed: _toggleSubscribe,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('已订阅'),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: _toggleSubscribe,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('订阅'),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) {
    return Container(
      width: 110,
      height: 110,
      color: cs.surfaceContainerHighest,
      child: Icon(
        Icons.dynamic_feed_outlined,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  /// 安利板块：文案卡片 + 可播放歌曲列表
  Widget _buildAmway(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            _amway.title,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        if (_amway.content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              margin: EdgeInsets.zero,
              color: cs.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_amway.coverUrl != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: _amway.coverUrl!,
                          memCacheWidth: 1080,
                          memCacheHeight: 420,
                          height: 140,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Text(
                      _amway.content,
                      style: tt.bodyMedium?.copyWith(
                        height: 1.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_amway.songs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              children: _amway.songs.asMap().entries.map((e) {
                final i = e.key;
                final s = e.value;
                return SongListItem(
                  song: s.toSong(),
                  onTap: () => context.read<PlayerProvider>().playOnlinePlaylist(
                    _amway.songs.map((x) => x.toSong()).toList(),
                    i,
                  ),
                  onMoreTap: () {},
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildStoriesHeader(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        _stories.isEmpty ? '暂无音乐故事' : '音乐故事',
        style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildStoryTile(BuildContext context, _ChannelStory story) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final playable = story.song != null;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: story.coverUrl != null
            ? CachedNetworkImage(
                imageUrl: story.coverUrl!,
                memCacheWidth: 132,
                memCacheHeight: 132,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _storyPlaceholder(cs),
              )
            : _storyPlaceholder(cs),
      ),
      title: Text(
        story.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tt.bodyLarge,
      ),
      subtitle: story.desc != null && story.desc!.isNotEmpty
          ? Text(
              story.desc!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (story.fileId.isNotEmpty)
            IconButton(
              tooltip: '故事详情',
              icon: const Icon(Icons.article_outlined),
              onPressed: () => _openStoryDetail(story),
            ),
          if (playable)
            IconButton(
              tooltip: '播放',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => _playStories(_stories, _stories.indexOf(story)),
            ),
        ],
      ),
      onTap: playable
          ? () => _playStories(_stories, _stories.indexOf(story))
          : (story.fileId.isNotEmpty ? () => _openStoryDetail(story) : null),
    );
  }

  Widget _storyPlaceholder(ColorScheme cs) {
    return Container(
      width: 44,
      height: 44,
      color: cs.surfaceContainerHighest,
      child: Icon(Icons.music_note_outlined, color: cs.onSurfaceVariant),
    );
  }

  /// 相似频道：横向滚动卡片
  Widget _buildSimilar(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            '相似频道',
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _similar.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _SimilarChannelCard(
              channel: _similar[i],
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ChannelDetailPage(channel: _similar[i]),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 相似频道小卡片：封面 + 名称
class _SimilarChannelCard extends StatelessWidget {
  final KugouYouthChannel channel;
  final VoidCallback? onTap;

  const _SimilarChannelCard({required this.channel, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SizedBox(
      width: 110,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: channel.coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: channel.coverUrl!,
                      memCacheWidth: 330,
                      memCacheHeight: 330,
                      width: 110,
                      height: 110,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(
                        color: cs.surfaceContainerHighest,
                        child: Icon(
                          Icons.dynamic_feed_outlined,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Container(
                      width: 110,
                      height: 110,
                      color: cs.surfaceContainerHighest,
                      child: Icon(
                        Icons.dynamic_feed_outlined,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.labelMedium?.copyWith(color: cs.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}
