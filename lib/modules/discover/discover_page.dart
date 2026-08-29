import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../data/models/album.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/smart_artwork_image.dart';
import '../../widgets/song_list_item.dart';
import '../charts/charts_page.dart';
import '../personal_fm/personal_fm_section.dart';
import '../playlist/playlist_page.dart';
import '../recognition/song_recognition_page.dart';
import '../search/search_page.dart';

/// 顶栏图标按钮（搜索 / 识曲）的尺寸：36 而不是 MD3 默认的 48，让两个图标之间
/// 由 24dp 收到 12dp；纵向仍保留 40dp 触达高度。
const double _kActionButtonWidth = 36.0;
const double _kActionButtonHeight = 40.0;

/// 补回按钮收窄的宽度，让最右那枚图标与屏幕边缘的距离保持不变。
const double _kActionTrailingGap = 6.0;

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  static const String _kDiscoverLastDateKey = 'discover_last_date';

  // 五个内容区块的折叠状态（true=折叠）。SharedPreferences 存"是否折叠"。
  //
  // 原来只有每日推荐/热门歌单/排行榜三个能折，主题歌单和场景音乐不能——
  // 同一页里五个标题行有两种交互契约，用户无法预测哪个能点。现在补齐。
  // 私人 FM 不在其中：它已经没有标题行（见 [PersonalFmSection]），也就没有
  // 折叠的把手，卡片恒定展示。
  static const String _kCollapsedDaily = 'discover_collapsed_daily';
  static const String _kCollapsedTheme = 'discover_collapsed_theme';
  static const String _kCollapsedScene = 'discover_collapsed_scene';
  static const String _kCollapsedPlaylist = 'discover_collapsed_playlist';
  static const String _kCollapsedRank = 'discover_collapsed_rank';

  bool _isLoading = true;
  String? _error;

  bool _isDailyExpanded = true;
  bool _isThemeExpanded = true;
  bool _isSceneExpanded = true;
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

  /// 从 SharedPreferences 恢复五个 section 的折叠状态
  Future<void> _loadCollapseStates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDailyExpanded = !(prefs.getBool(_kCollapsedDaily) ?? false);
      _isThemeExpanded = !(prefs.getBool(_kCollapsedTheme) ?? false);
      _isSceneExpanded = !(prefs.getBool(_kCollapsedScene) ?? false);
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
    // 私人 FM 不跟着刷新走。它背后是流式接口（`action=play`，「给我下一批」），
    // 每次请求返回的都是不同的一批歌，而发现页的 FM 卡片直接渲染列表第一首。
    // 跟着下拉刷新就会静默换掉卡上显示的、甚至正在播的那首歌：卡片与播放器
    // 脱钩（按钮翻回 ▶、收藏指向别的歌），而且刷新不传档位参数，服务端回落到
    // normal/0，用户停在「探索」「小众」时内容还会被换成「红心」档的。
    // 所以只在手上一首都没有时补一次，之后换歌只由用户自己触发
    // （切档位 / 完整 FM 页）。
    final needsPersonalFm = kugou.personalFmSongs.isEmpty;
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
        // 这里 forceRefresh 恒为 true 不是笔误：列表为空才会走到这一句，而空列表
        // 也会盖上新鲜时间戳（上一次请求成功但返回了空），不绕开 5 分钟 TTL 的话
        // 卡片会空着却「新鲜」，下拉也补不回来。
        if (needsPersonalFm) kugou.getPersonalFm(forceRefresh: true),
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
        title: '发现',
        tabId: 'discover',
        scrollController: _scrollController,
        // 公开版偏好：无壁纸时顶部恒为不透明 surface（文字区稳定）；
        // 有壁纸时顶栏完全透明，壁纸透出与页面主体透明度上下一致
        opaque: true,
        titleTrailing: _buildGreetingPill(colorScheme),
        actions: [
          _buildActionIcon(
            icon: Icons.search,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SearchPage())),
          ),
          Padding(
            padding: const EdgeInsets.only(right: _kActionTrailingGap),
            child: _buildActionIcon(
              icon: Icons.mic_outlined,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SongRecognitionPage()),
              ),
            ),
          ),
        ],
      ),
      body: Md3PullToRefresh(
        onRefresh: _loadAllData,
        child: _isLoading
            ? const Center(child: M3ELoadingIndicator())
            : _error != null
            ? _buildError(colorScheme)
            : CustomScrollView(
                controller: _scrollController,
                slivers: [
                  _buildPersonalFmSection(),
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

  /// 三个参数缺一不可：`constraints` 定按钮尺寸，`padding` 让 24dp 的图标塞得进
  /// 36dp 的框，`visualDensity` 改的是 MD3 垫在外面那层 48dp 的布局尺寸——不动它
  /// 按钮画小了、占位照旧。
  Widget _buildActionIcon({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      visualDensity: const VisualDensity(horizontal: -3, vertical: -2),
      constraints: const BoxConstraints.tightFor(
        width: _kActionButtonWidth,
        height: _kActionButtonHeight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  /// 问候胶囊，紧跟在顶栏标题右边。宽度贴着文字长短变，上限由标题区剩下的宽度
  /// 决定（见 [ScrollAwareAppBar.titleTrailing]），顶格时由 ellipsis 收尾。
  Widget _buildGreetingPill(ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
      decoration: ShapeDecoration(
        color: cs.primaryContainer,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Selector<KugouProvider, String?>(
              selector: (_, kugou) =>
                  kugou.isLoggedIn ? kugou.userInfo?.nickname : null,
              builder: (context, nickname, _) {
                final greeting = _getGreeting();
                return Text(
                  nickname == null || nickname.isEmpty
                      ? greeting
                      : '$greeting，$nickname',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelLarge?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.music_note, size: 16, color: cs.onPrimaryContainer),
        ],
      ),
    );
  }

  Widget _buildPersonalFmSection() {
    return const SliverToBoxAdapter(child: PersonalFmSection());
  }

  /// 每日推荐：竖排前三首。
  ///
  /// 原来是 76dp 高的横滑条，是全页最矮的区块——语义最重的内容拿到了最轻的
  /// 视觉权重。而且卡内布局是「封面在左、文字在右」的列表项形态，被硬塞进横滑
  /// 列表：横滑方向和卡内阅读方向一致，眼睛不知道该往哪走。
  ///
  /// 改成竖排后它同时打断了「五连横滑」的单一节奏，并且复用 [SongListItem]，
  /// 顺带拿到「正在播」高亮、收藏、MV、更多菜单——原来的 _DailySongCard 一个都没有。
  /// 全部 30 首仍在标题右侧的 `›` 里。
  Widget _buildDailySection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouSongDetail>>(
      selector: (_, kugou) => kugou.recommendSongs,
      builder: (context, songs, _) {
        if (songs.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        final all = songs.map((e) => e.toSong()).toList();
        final top = all.take(3).toList();
        return SliverToBoxAdapter(
          child: _CollapsibleSection(
            title: '每日推荐',
            isExpanded: _isDailyExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedDaily,
              currentlyExpanded: _isDailyExpanded,
              apply: (v) => _isDailyExpanded = v,
            ),
            trailing: IconButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const _DailyRecommendDetailPage(),
                  ),
                );
              },
              icon: const Icon(Icons.chevron_right),
            ),
            child: Padding(
              // SongListItem 自带 horizontal 10 的内边距，补 6 凑成
              // 与其他区块一致的 16dp 页边距。
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                children: [
                  for (var i = 0; i < top.length; i++)
                    SongListItem(
                      song: top[i],
                      showDuration: false,
                      onTap: () => context
                          .read<PlayerProvider>()
                          .playOnlinePlaylist(all, i),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 主题歌单：横滑方卡。
  ///
  /// 两处修正：
  /// - 补上 surfaceContainerLow 底板。原来是裸的 ClipRRect + Text，是全页
  ///   唯一没有容器的卡，和左右邻居的容器策略不一致。
  /// - 封面从 Expanded 改成 AspectRatio(1)。原来封面高度 = 180 - 文字块 ≈ 154、
  ///   宽度 130，正方形封面被 BoxFit.cover 裁掉两边。
  Widget _buildThemeMusicSection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouThemeInfo>>(
      selector: (_, kugou) => kugou.themePlaylistData,
      builder: (context, themes, _) {
        if (themes.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        return SliverToBoxAdapter(
          child: _CollapsibleSection(
            title: '主题歌单',
            isExpanded: _isThemeExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedTheme,
              currentlyExpanded: _isThemeExpanded,
              apply: (v) => _isThemeExpanded = v,
            ),
            child: SizedBox(
              // 130 封面 + 文字块（8 上 + 20 行高 + 8 下）
              height: 166,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: themes.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 130,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: cs.surfaceContainerLow,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: CachedNetworkImage(
                              imageUrl: themes[i].coverUrl ?? '',
                              memCacheWidth: 390,
                              memCacheHeight: 390,
                              fit: BoxFit.cover,
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
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  themes[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w500,
                                        color: cs.onSurface,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
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

  /// 场景音乐：一行 chip 流。
  ///
  /// 原来是 90×110 的方卡，每张卡顶着一个 `Icons.headphones`——跑步、睡眠、
  /// 专注、通勤全是同一个耳机图标，28dp 占了卡片大半却零信息量，已删除。
  /// 图标一去，卡里只剩一行文字，那它本来就该是 chip 而不是 card；90dp 固定
  /// 宽度截断长场景名的问题也随之消失（chip 宽度由文字决定）。
  ///
  /// 110 → 44dp 的高度落差顺便给首页当了个休止符，夹在主题歌单和热门歌单
  /// 两个大区块之间。
  Widget _buildSceneSection(ColorScheme cs) {
    return Selector<KugouProvider, Map<String, dynamic>?>(
      selector: (_, kugou) => kugou.sceneData,
      builder: (context, sceneData, _) {
        if (sceneData == null) {
          return const SliverToBoxAdapter(child: SizedBox());
        }
        final data = sceneData['data'] as Map<String, dynamic>? ?? sceneData;
        final list = data['list'] ?? data['info'] ?? [];
        if (list is! List || list.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox());
        }
        final items = list;
        return SliverToBoxAdapter(
          child: _CollapsibleSection(
            title: '场景音乐',
            isExpanded: _isSceneExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedScene,
              currentlyExpanded: _isSceneExpanded,
              apply: (v) => _isSceneExpanded = v,
            ),
            child: SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i] as Map<String, dynamic>;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    // 用 Chip 而不是 ActionChip：这些场景目前没有点击目标，
                    // 加 onTap 就是凭空造一个不存在的入口。
                    child: Chip(
                      label: Text(item['name']?.toString() ?? ''),
                      labelStyle: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: cs.onSurfaceVariant),
                      backgroundColor: cs.surfaceContainerLow,
                      side: BorderSide(color: cs.outlineVariant),
                    ),
                  );
                },
              ),
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
          child: _CollapsibleSection(
            title: '热门歌单',
            isExpanded: _isPlaylistExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedPlaylist,
              currentlyExpanded: _isPlaylistExpanded,
              apply: (v) => _isPlaylistExpanded = v,
            ),
            trailing: IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const _PlaylistBrowsePage(),
                ),
              ),
              icon: const Icon(Icons.chevron_right),
            ),
            child: SizedBox(
              // 150 封面（正方）+ 40 文字块。原来是 200，多出的 10dp 让
              // AlbumCard 把封面拉成 150×160 后裁掉了上下各 5dp。
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: plist.length,
                itemBuilder: (context, i) => Padding(
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
        );
      },
    );
  }

  /// 排行榜：竖排前三名，带名次。
  ///
  /// 原来是横滑 AlbumCard——排行榜本身是有序的，横滑方卡把「第几名」这个
  /// 唯一区别于普通歌单的信息完全丢掉了。改成竖排后名次回来了，同时给首页
  /// 补上第二个纵向断点。完整榜单在标题右侧的 `›` 里。
  Widget _buildRankSection(ColorScheme cs) {
    return Selector<KugouProvider, KugouRankList?>(
      selector: (_, kugou) => kugou.rankList,
      builder: (context, rankList, _) {
        final ranks = rankList?.ranks.map((e) => e.toAlbum()).toList() ?? [];
        if (ranks.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        final top = ranks.take(3).toList();
        return SliverToBoxAdapter(
          child: _CollapsibleSection(
            title: '排行榜',
            isExpanded: _isRankExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedRank,
              currentlyExpanded: _isRankExpanded,
              apply: (v) => _isRankExpanded = v,
            ),
            trailing: IconButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ChartsPage())),
              icon: const Icon(Icons.chevron_right),
            ),
            child: Column(
              children: [
                for (var i = 0; i < top.length; i++)
                  _RankRow(
                    rank: i + 1,
                    album: top[i],
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _RankDetailPage(
                            rankId: rankList!.ranks[i].id,
                            rankName: top[i].name,
                          ),
                        ),
                      );
                    },
                  ),
              ],
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
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouPlaylistBrief>>(
              selector: (_, kugou) => kugou.playlistList,
              builder: (context, list, _) {
                if (list.isEmpty) return const Center(child: Text('暂无数据'));
                // 使用 PinchableGridView：Pad 模式下双指捏合可动态调整列数，
                // 非 Pad 模式内部固定 2 列；保持原 childAspectRatio=0.85、spacing=12、padding=16
                return PinchableGridView(
                  // 底部叠加系统手势条（小横条）高度，避免末项被压住
                  padding: EdgeInsets.fromLTRB(
                    16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom,
                  ),
                  // 0.8 而不是 0.85：cell 高度要容纳「正方形封面 + 40dp 文字块」，
                  // 2 列 360dp 屏下每格 158 宽 → 高 198，比值 0.798。
                  // AlbumCard 内部会自适应，Pad 捏合改列数时也不会溢出。
                  childAspectRatio: 0.8,
                  spacing: 12,
                  itemCount: list.length,
                  itemBuilder: (context, i) => AlbumCard(
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
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouSongDetail>>(
              selector: (_, kugou) => kugou.recommendSongs,
              builder: (context, recommendSongs, _) {
                final songs = recommendSongs.map((e) => e.toSong()).toList();
                if (songs.isEmpty) return const Center(child: Text('暂无数据'));
                return Column(
                  children: [
                    // 播放全部：把当日的 30 首当一张歌单从头连播。
                    // 形态与专辑/歌单/听书详情页的主行动按钮一致
                    // （FilledButton.icon + play_arrow）。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => context
                              .read<PlayerProvider>()
                              .playOnlinePlaylist(songs, 0),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放全部'),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          16, 8, 16, 16 + MediaQuery.paddingOf(context).bottom,
                        ),
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
                      ),
                    ),
                  ],
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
          ? const Center(child: M3ELoadingIndicator())
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
                  padding: EdgeInsets.fromLTRB(
                    16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: songs.length,
                  itemBuilder: (context, i) {
                    final song = songs[i].toSong();
                    return SongListItem(
                      song: song,
                      onTap: () =>
                          context.read<PlayerProvider>().playOnlinePlaylist(
                            songs.map((e) => e.toSong()).toList(),
                            i,
                          ),
                      onMoreTap: () {},
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                            style: tt.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
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

/// 排行榜的一行：名次 + 封面 + 榜名。
///
/// 名次用 primary 色的数字而不是徽章：三行并列时数字本身就是最强的序列信号，
/// 加个圆底反而和封面抢注意力。
class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.rank,
    required this.album,
    required this.onTap,
  });

  final int rank;
  final Album album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$rank',
                textAlign: TextAlign.center,
                style: tt.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SmartArtworkImage(
              artworkUri: album.artworkUri,
              size: 52,
              borderRadius: 10,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
