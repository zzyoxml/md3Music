import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/album.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/app_animation.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../../widgets/md3e_refresh_indicator.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/song_list_item.dart';
import '../charts/charts_page.dart';
import '../playlist/playlist_page.dart';
import '../recognition/song_recognition_page.dart';
import '../search/search_page.dart';

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key, this.onAvatarTap});

  /// 点击头像时的回调（用于切换到"我的"tab）
  final VoidCallback? onAvatarTap;

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  static const String _kDiscoverLastDateKey = 'discover_last_date';

  // 三个可折叠区块的折叠状态（true=折叠）。SharedPreferences 存"是否折叠"。
  static const String _kCollapsedDaily = 'discover_collapsed_daily';
  static const String _kCollapsedPlaylist = 'discover_collapsed_playlist';
  static const String _kCollapsedRank = 'discover_collapsed_rank';

  bool _isLoading = true;
  String? _error;

  bool _isDailyExpanded = true;
  bool _isPlaylistExpanded = true;
  bool _isRankExpanded = true;

  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享，监听滚动 offset
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initIfNeeded();
      _loadCollapseStates();
    });
  }

  /// 从 SharedPreferences 恢复三个 section 的折叠状态
  Future<void> _loadCollapseStates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDailyExpanded = !(prefs.getBool(_kCollapsedDaily) ?? false);
      _isPlaylistExpanded = !(prefs.getBool(_kCollapsedPlaylist) ?? false);
      _isRankExpanded = !(prefs.getBool(_kCollapsedRank) ?? false);
    });
  }

  /// 切换 section 展开/折叠并持久化
  Future<void> _toggleCollapse({
    required String prefKey,
    required bool currentlyExpanded,
    required ValueChanged<bool> apply,
  }) async {
    final next = !currentlyExpanded;
    setState(() => apply(next));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, !next);
  }

  /// 每天只自动加载一次：内存有数据且是同一天则跳过，否则拉取
  Future<void> _initIfNeeded() async {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastDate = prefs.getString(_kDiscoverLastDateKey);
    final today = _todayString();
    if (kugou.hasLoadedDiscoverData && lastDate == today) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (lastDate != null && lastDate != today) {
      // 跨天：重置标志，让 _loadAllData 重新拉
      kugou.resetDiscoverLoadedFlag();
    }

    // 自动重试：首次启动时 Node.js 服务器可能尚未完全就绪
    int retryCount = 0;
    while (retryCount < 3) {
      await _loadAllData();
      if (!mounted) return;

      // 检查是否真的加载到了数据
      if (kugou.playlistList.isNotEmpty ||
          kugou.rankList != null ||
          kugou.recommendSongs.isNotEmpty ||
          kugou.sceneData != null) {
        break; // 有数据了，退出重试
      }

      retryCount++;
      if (retryCount < 3 && mounted) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  String _todayString() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadAllData() async {
    if (!mounted) return; // 页面已销毁则放弃，避免访问 context 触发 null check 崩溃
    final kugou = context.read<KugouProvider>();
    final hasExistingData = kugou.hasLoadedDiscoverData;
    // 已有数据时直接展示，后台静默刷新
    if (!hasExistingData) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      await Future.wait([
        kugou.getPlaylist(forceRefresh: hasExistingData),
        kugou.getRankList(forceRefresh: hasExistingData),
        kugou.getRecommendDaily(forceRefresh: hasExistingData),
        kugou.getYuekuBanner(forceRefresh: hasExistingData),
        kugou.getSceneMusic(forceRefresh: hasExistingData),
        kugou.getThemeMusic(forceRefresh: hasExistingData),
        kugou.getThemePlaylist(forceRefresh: hasExistingData),
        kugou.getIpHome(forceRefresh: hasExistingData),
        kugou.getPersonalFm(forceRefresh: hasExistingData),
      ]);

      // 只有确实加载到数据时才标记为已加载
      final hasAnyData =
          kugou.playlistList.isNotEmpty ||
          kugou.rankList != null ||
          kugou.recommendSongs.isNotEmpty ||
          kugou.sceneData != null ||
          kugou.themePlaylistData.isNotEmpty;
      if (!mounted) return;
      if (hasAnyData) {
        kugou.markDiscoverLoaded();
        // 任何一次加载成功都把日期标记为今天
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        await prefs.setString(_kDiscoverLastDateKey, _todayString());
      }
    } catch (e) {
      if (!mounted) return;
      _error = e.toString();
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: 'MD3Music',
        scrollController: _scrollController,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SearchPage())),
          ),
          IconButton(
            icon: const Icon(Icons.mic_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SongRecognitionPage()),
            ),
          ),
          Selector<KugouProvider, (String?, String, bool)>(
            selector: (_, kugou) => (
              kugou.userInfo?.avatar,
              kugou.userInfo?.userid ?? 'default',
              kugou.isLoggedIn,
            ),
            builder: (context, data, _) {
              final (avatarUrl, userId, isLoggedIn) = data;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => widget.onAvatarTap?.call(),
                  child: _buildAvatar(
                    avatarUrl,
                    userId,
                    isLoggedIn,
                    colorScheme,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: MD3ERefreshIndicator(
        onRefresh: _loadAllData,
        child: _isLoading
            ? const Center(child: MD3ELoadingIndicator())
            : _error != null
            ? _buildError(colorScheme)
            : CustomScrollView(
                controller: _scrollController,
                slivers: [
                  _buildBannerSection(colorScheme),
                  _buildDailySection(colorScheme),
                  _buildThemeMusicSection(colorScheme),
                  _buildSceneSection(colorScheme),
                  _buildPlaylistSection(colorScheme),
                  _buildRankSection(colorScheme),
                  const SliverToBoxAdapter(child: SizedBox(height: 80)),
                ],
              ),
      ),
    );
  }

  String _getGreeting() {
    final h = DateTime.now().hour;
    if (h < 6) return '夜深了';
    if (h < 12) return '早上好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  Widget _buildAvatar(
    String? avatarUrl,
    String userId,
    bool isLoggedIn,
    ColorScheme colorScheme,
  ) {
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        radius: 16,
        child: Icon(
          isLoggedIn ? Icons.person : Icons.person_outline,
          size: 18,
          color: colorScheme.onPrimaryContainer,
        ),
      );
    }

    return CircleAvatar(
      radius: 16,
      backgroundColor: colorScheme.primaryContainer,
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatarUrl,
          cacheKey: 'avatar_$userId',
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          placeholder: (context, url) => Icon(
            isLoggedIn ? Icons.person : Icons.person_outline,
            size: 18,
            color: colorScheme.onPrimaryContainer,
          ),
          errorWidget: (context, url, error) => Icon(
            isLoggedIn ? Icons.person : Icons.person_outline,
            size: 18,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }

  Widget _buildError(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _loadAllData,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBannerSection(ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return SliverToBoxAdapter(
      child: FadeInUp(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 140),
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: cs.primaryContainer,
            ),
            child: Stack(
              children: [
                Positioned(
                  right: -12,
                  top: -12,
                  child: Icon(
                    Icons.music_note,
                    size: 80,
                    color: cs.onPrimaryContainer.withValues(alpha: 0.1),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getGreeting(),
                        style: tt.displaySmall?.copyWith(
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '发现你喜欢的音乐',
                        style: tt.bodyLarge?.copyWith(
                          color: cs.onPrimaryContainer.withValues(alpha: 0.8),
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
    );
  }

  Widget _buildDailySection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouSongDetail>>(
      selector: (_, kugou) => kugou.recommendSongs,
      builder: (context, songs, _) {
        if (songs.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 150,
            child: _CollapsibleSection(
              title: '每日推荐',
              isExpanded: _isDailyExpanded,
              onToggle: () => _toggleCollapse(
                prefKey: _kCollapsedDaily,
                currentlyExpanded: _isDailyExpanded,
                apply: (v) => _isDailyExpanded = v,
              ),
              trailing: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const _DailyRecommendDetailPage(),
                    ),
                  );
                },
                child: const Text('查看更多'),
              ),
              child: SizedBox(
                height: 72,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: songs.length > 5 ? 5 : songs.length,
                  itemBuilder: (context, i) {
                    final s = songs[i];
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        avatar: CircleAvatar(
                          backgroundColor: cs.primaryContainer,
                          child: Text(
                            '${i + 1}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: cs.onPrimaryContainer),
                          ),
                        ),
                        label: Text(s.songName),
                        onPressed: () =>
                            context.read<PlayerProvider>().playOnlinePlaylist(
                              songs.map((e) => e.toSong()).toList(),
                              i,
                            ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildThemeMusicSection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouThemeInfo>>(
      selector: (_, kugou) => kugou.themePlaylistData,
      builder: (context, themes, _) {
        if (themes.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '主题歌单',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      TextButton(onPressed: () {}, child: const Text('查看更多')),
                    ],
                  ),
                ),
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: themes.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: FadeInUp(
                        delayMs: i * 30,
                        child: SizedBox(
                          width: 130,
                          child: Column(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: CachedNetworkImage(
                                    imageUrl: themes[i].coverUrl ?? '',
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    placeholder: (_, _) => Container(
                                      color: cs.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.music_note,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                    errorWidget: (_, _, _) => Container(
                                      color: cs.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.music_note,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                themes[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: cs.onSurface,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSceneSection(ColorScheme cs) {
    return Selector<KugouProvider, Map<String, dynamic>?>(
      selector: (_, kugou) => kugou.sceneData,
      builder: (context, sceneData, _) {
        if (sceneData == null)
          return const SliverToBoxAdapter(child: SizedBox());
        final data = sceneData['data'] as Map<String, dynamic>? ?? sceneData;
        final list = data['list'] ?? data['info'] ?? [];
        if (list is! List || list.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox());
        }
        final items = list;
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 250,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '场景音乐',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                SizedBox(
                  height: 110,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[i] as Map<String, dynamic>;
                      return Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Container(
                          width: 90,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: cs.surfaceContainerLow,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.headphones,
                                color: cs.primary,
                                size: 28,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                item['name']?.toString() ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: cs.onSurface),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistSection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouPlaylistBrief>>(
      selector: (_, kugou) => kugou.playlistList,
      builder: (context, plist, _) {
        if (plist.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 300,
            child: _CollapsibleSection(
              title: '热门歌单',
              isExpanded: _isPlaylistExpanded,
              onToggle: () => _toggleCollapse(
                prefKey: _kCollapsedPlaylist,
                currentlyExpanded: _isPlaylistExpanded,
                apply: (v) => _isPlaylistExpanded = v,
              ),
              trailing: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const _PlaylistBrowsePage(),
                  ),
                ),
                child: const Text('查看更多'),
              ),
              child: SizedBox(
                height: 200,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: plist.length,
                  itemBuilder: (context, i) => FadeInUp(
                    delayMs: i * 30,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 150,
                        child: AlbumCard(
                          album: Album(
                            id: plist[i].id,
                            name: plist[i].name,
                            artist: '',
                            artworkUri: plist[i].coverUrl,
                            songCount: plist[i].songCount,
                          ),
                          onTap: () {
                            final brief = plist[i];
                            final playlist = brief.toPlaylist();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    PlaylistPage(playlist: playlist),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRankSection(ColorScheme cs) {
    return Selector<KugouProvider, KugouRankList?>(
      selector: (_, kugou) => kugou.rankList,
      builder: (context, rankList, _) {
        final ranks = rankList?.ranks.map((e) => e.toAlbum()).toList() ?? [];
        if (ranks.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: FadeInUp(
            delayMs: 350,
            child: _CollapsibleSection(
              title: '排行榜',
              isExpanded: _isRankExpanded,
              onToggle: () => _toggleCollapse(
                prefKey: _kCollapsedRank,
                currentlyExpanded: _isRankExpanded,
                apply: (v) => _isRankExpanded = v,
              ),
              trailing: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const ChartsPage())),
                child: const Text('查看更多'),
              ),
              child: SizedBox(
                height: 200,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: ranks.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 150,
                      child: AlbumCard(
                        album: ranks[i],
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _RankDetailPage(
                                rankId: rankList!.ranks[i].id,
                                rankName: ranks[i].name,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistBrowsePage extends StatefulWidget {
  const _PlaylistBrowsePage();
  @override
  State<_PlaylistBrowsePage> createState() => _PlaylistBrowsePageState();
}

class _PlaylistBrowsePageState extends State<_PlaylistBrowsePage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getPlaylist();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('热门歌单')),
      body: _isLoading
          ? const Center(child: MD3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouPlaylistBrief>>(
              selector: (_, kugou) => kugou.playlistList,
              builder: (context, list, _) {
                if (list.isEmpty) return const Center(child: Text('暂无数据'));
                // 使用 PinchableGridView：Pad 模式下双指捏合可动态调整列数，
                // 非 Pad 模式内部固定 2 列；保持原 childAspectRatio=0.85、spacing=12、padding=16
                return PinchableGridView(
                  padding: const EdgeInsets.all(16),
                  childAspectRatio: 0.85,
                  spacing: 12,
                  itemCount: list.length,
                  itemBuilder: (context, i) => FadeInUp(
                    delayMs: i * 30,
                    child: AlbumCard(
                      album: Album(
                        id: list[i].id,
                        name: list[i].name,
                        artist: '',
                        artworkUri: list[i].coverUrl,
                        songCount: list[i].songCount,
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              PlaylistPage(playlist: list[i].toPlaylist()),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _DailyRecommendDetailPage extends StatefulWidget {
  const _DailyRecommendDetailPage();

  @override
  State<_DailyRecommendDetailPage> createState() =>
      _DailyRecommendDetailPageState();
}

class _DailyRecommendDetailPageState extends State<_DailyRecommendDetailPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRecommendDaily();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('每日推荐')),
      body: _isLoading
          ? const Center(child: MD3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouSongDetail>>(
              selector: (_, kugou) => kugou.recommendSongs,
              builder: (context, recommendSongs, _) {
                final songs = recommendSongs.map((e) => e.toSong()).toList();
                if (songs.isEmpty) return const Center(child: Text('暂无数据'));
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return SongListItem(
                      song: song,
                      onTap: () {
                        context.read<PlayerProvider>().playOnlinePlaylist(
                          songs,
                          index,
                        );
                      },
                      onMoreTap: () {},
                    );
                  },
                );
              },
            ),
    );
  }
}

class _RankDetailPage extends StatefulWidget {
  final String rankId;
  final String rankName;
  const _RankDetailPage({required this.rankId, required this.rankName});
  @override
  State<_RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends State<_RankDetailPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRankSongs(rankId: widget.rankId);
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.rankName)),
      body: _isLoading
          ? const Center(child: MD3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouSongDetail>>(
              selector: (_, kugou) => kugou.rankSongs,
              builder: (context, songs, _) {
                if (songs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('暂无数据'),
                        ElevatedButton(
                          onPressed: () async {
                            setState(() => _isLoading = true);
                            await context.read<KugouProvider>().getRankSongs(
                              rankId: widget.rankId,
                              forceRefresh: true,
                            );
                            if (mounted) setState(() => _isLoading = false);
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: songs.length,
                  itemBuilder: (context, i) {
                    final song = songs[i].toSong();
                    return FadeInUp(
                      delayMs: i * 30,
                      child: SongListItem(
                        song: song,
                        onTap: () =>
                            context.read<PlayerProvider>().playOnlinePlaylist(
                              songs.map((e) => e.toSong()).toList(),
                              i,
                            ),
                        onMoreTap: () {},
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

/// 可折叠 section 容器：
/// - 标题行左侧可点击区域（标题 + chevron 图标）触发 onToggle 折叠/展开
/// - 标题行右侧可放额外 widget（如"查看更多"按钮）
/// - 内容用 AnimatedCrossFade 在展示态和零高度态间平滑过渡
class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.isExpanded,
    required this.onToggle,
    required this.child,
    this.trailing,
  });

  final String title;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: tt.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: isExpanded ? 0 : 0.5,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          sizeCurve: Curves.easeInOut,
          firstChild: child,
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
