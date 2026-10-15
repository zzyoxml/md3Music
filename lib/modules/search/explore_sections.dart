import '../../core/layout/adaptive_navigator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/song_list_item.dart';
import '../album/album_detail_page.dart';
import '../charts/charts_page.dart';
import '../player/secondary_mini_player.dart';
import '../playlist/playlist_page.dart';

/// 音乐探索内容模块（改版计划一：从发现页迁移到搜索空白态）。
///
/// 每个模块统一「标题 + 横向滑动内容带」结构，视觉密度参照推荐内容，
/// 不复制发现页原有的折叠状态。复用 [KugouProvider] 已有数据与缓存，
/// 避免发现页、搜索页重复请求：仅在对应数据为空时补一次请求。
class MusicExploreSections extends StatefulWidget {
  const MusicExploreSections({super.key});

  @override
  State<MusicExploreSections> createState() => _MusicExploreSectionsState();
}

class _MusicExploreSectionsState extends State<MusicExploreSections> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  /// 仅在数据缺失时补拉；forceRefresh=false 命中 5 分钟缓存即不重复请求，
  /// 与发现页共享同一份 KugouProvider 数据。
  void _ensureLoaded() {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    if (kugou.themePlaylistData.isEmpty) kugou.getThemePlaylist();
    if (kugou.sceneData == null) kugou.getSceneMusic();
    if (kugou.playlistList.isEmpty) kugou.getPlaylist();
    if (kugou.rankList == null) kugou.getRankList();
    if (kugou.topAlbums.isEmpty) kugou.getTopAlbum();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildThemeSection(),
        _buildSceneSection(),
        _buildPlaylistSection(),
        _buildRankSection(),
        _buildNewAlbumSection(),
        const Gap(AppSpacing.sm),
      ],
    );
  }
  /// 主题歌单：横滑方卡（130 宽），展示态，无「更多」入口。
  Widget _buildThemeSection() {
    return Selector<KugouProvider, List<KugouThemeInfo>>(
      selector: (_, kugou) => kugou.themePlaylistData,
      builder: (context, themes, _) {
        if (themes.isEmpty) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeader(title: '主题歌单'),
            SizedBox(
              height: 166,
              child: TvScrollRegion(
                memoryKey: 'tv/explore-themes-row',
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  itemCount: themes.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.md),
                    child: SizedBox(
                      width: 130,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: AppRadius.lgAll,
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
                                placeholder: (_, _) => _coverPlaceholder(cs),
                                errorWidget: (_, _, _) => _coverPlaceholder(cs),
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
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
          ],
        );
      },
    );
  }

  static Widget _coverPlaceholder(ColorScheme cs) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      );
  /// 场景音乐：一行 chip 流（展示态，无点击目标）。
  Widget _buildSceneSection() {
    return Selector<KugouProvider, Map<String, dynamic>?>(
      selector: (_, kugou) => kugou.sceneData,
      builder: (context, sceneData, _) {
        if (sceneData == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        final data = sceneData['data'] as Map<String, dynamic>? ?? sceneData;
        final list = data['list'] ?? data['info'] ?? [];
        if (list is! List || list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeader(title: '场景音乐'),
            SizedBox(
              height: 44,
              child: TvScrollRegion(
                memoryKey: 'tv/explore-scene-row',
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final item = list[i] as Map<String, dynamic>;
                    return Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: Chip(
                        label: Text(item['name']?.toString() ?? ''),
                        labelStyle: Theme.of(context)
                            .textTheme
                            .labelLarge
                            ?.copyWith(color: cs.onSurfaceVariant),
                        backgroundColor: cs.surfaceContainerLow,
                        side: BorderSide(color: cs.outlineVariant),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 热门歌单：2 列小封面网格（封面在左、标题在右，与每日推荐布局相似），
  /// 最多 6 个，点击进歌单详情，「›」进浏览页。
  Widget _buildPlaylistSection() {
    return Selector<KugouProvider, List<KugouPlaylistBrief>>(
      selector: (_, kugou) => kugou.playlistList,
      builder: (context, plist, _) {
        if (plist.isEmpty) return const SizedBox.shrink();
        // tag 口径与 PlaylistBrowsePage 的卡片一致（同一份 playlistList）：区块小
        // 封面 → 完整列表大封面、区块小封面 → 歌单详情页头，两段转场共用一套 tag。
        // 重复 gid 只给首次出现挂 tag（同一路由子树重复 tag 会在转场收集阶段抛
        // FlutterError，见 firstIndexById 的说明）。
        final firstGid = firstIndexById(
          [for (final p in plist) p.globalCollectionId ?? p.id],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: '热门歌单',
              onMore: () => AdaptiveNav.openDetail(context,
                (_) => const PlaylistBrowsePage(),
              ),
            ),
            _CompactAlbumGrid(
              albums: [
                for (final p in plist)
                  Album(
                    id: p.id,
                    name: p.name,
                    artist: '',
                    artworkUri: p.coverUrl,
                    songCount: p.songCount,
                  ),
              ],
              heroTags: [
                for (var i = 0; i < plist.length; i++)
                  firstGid[plist[i].globalCollectionId ?? plist[i].id] == i
                      ? playlistCoverHeroTag(
                          plist[i].globalCollectionId ?? plist[i].id,
                        )
                      : null,
              ],
              onTap: (i) => AdaptiveNav.openDetail(context,
                (_) => PlaylistPage(playlist: plist[i].toPlaylist()),
              ),
              regionKey: 'tv/explore-hot-playlists',
            ),
          ],
        );
      },
    );
  }

  /// 排行榜：2 列小封面网格，最多 6 个，点击进榜单歌曲页，「›」进排行榜页。
  Widget _buildRankSection() {
    return Selector<KugouProvider, KugouRankList?>(
      selector: (_, kugou) => kugou.rankList,
      builder: (context, rankList, _) {
        final ranks = rankList?.ranks ?? const <KugouRank>[];
        if (ranks.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: '排行榜',
              onMore: () => AdaptiveNav.openDetail(context, (_) => const ChartsPage()),
            ),
            _CompactAlbumGrid(
              albums: [for (final r in ranks) r.toAlbum()],
              onTap: (i) => AdaptiveNav.openDetail(context,
                (_) => RankDetailPage(
                    rankId: ranks[i].id,
                    rankName: ranks[i].name,
                ),
              ),
              regionKey: 'tv/explore-ranks',
            ),
          ],
        );
      },
    );
  }

  /// 新碟上架：2 列小封面网格，最多 6 个，点击进专辑详情，「›」进浏览页。
  Widget _buildNewAlbumSection() {
    return Selector<KugouProvider, List<KugouAlbumBrief>>(
      selector: (_, kugou) => kugou.topAlbums,
      builder: (context, briefs, _) {
        if (briefs.isEmpty) return const SizedBox.shrink();
        // 一次构造喂给卡片、tag、详情页三处：id 口径必须与 AlbumDetailPage 收到的
        // widget.album.id 逐字一致，对不上就是静默不飞（与 NewAlbumBrowsePage
        // 同一约定）。专辑走 albumCoverHeroTag 命名空间，与歌单 tag 互斥。
        final albums = [for (final a in briefs) a.toAlbum()];
        final firstId = firstIndexById([for (final a in albums) a.id]);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: '新碟上架',
              onMore: () => AdaptiveNav.openDetail(context,
                (_) => const NewAlbumBrowsePage(),
              ),
            ),
            _CompactAlbumGrid(
              albums: albums,
              heroTags: [
                for (var i = 0; i < albums.length; i++)
                  firstId[albums[i].id] == i
                      ? albumCoverHeroTag(albums[i].id)
                      : null,
              ],
              onTap: (i) => AdaptiveNav.openDetail(context,
                (_) => AlbumDetailPage(album: albums[i]),
              ),
              regionKey: 'tv/explore-new-albums',
            ),
          ],
        );
      },
    );
  }
}

/// 新碟上架浏览页（从发现页迁移）。
class NewAlbumBrowsePage extends StatefulWidget {
  const NewAlbumBrowsePage({super.key});
  @override
  State<NewAlbumBrowsePage> createState() => _NewAlbumBrowsePageState();
}

class _NewAlbumBrowsePageState extends State<NewAlbumBrowsePage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // 完整列表与搜索页区块共用同一份 Provider 数据：从区块「›」进来时通常已
    // 加载完毕。转场首帧必须就有网格上的 Hero 端点，区块小封面 → 完整列表大
    // 封面的衔接才配得上对（框架 Hero 在 push 后一帧内配对两端，首帧若是
    // loading 圈，转场收集扑空、封面就只剩页面自身的推入动画）——先按现有
    // 数据渲染网格，后台只做一次补拉刷新。
    _isLoading = context.read<KugouProvider>().topAlbums.isEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getTopAlbum();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新碟上架')),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouAlbumBrief>>(
              selector: (_, kugou) => kugou.topAlbums,
              builder: (context, list, _) {
                if (list.isEmpty) return const Center(child: Text('暂无数据'));
                // 一次构造喂给卡片、tag、详情页三处：id 口径必须与 AlbumDetailPage
                // 收到的 widget.album.id 逐字一致，对不上就是静默不飞。
                final albums = [for (final a in list) a.toAlbum()];
                // Hero tag 唯一性防护：完整列表来自服务端，可能出现重复专辑 id；
                // 同一路由子树重复 tag 会在转场收集阶段抛 FlutterError。只给每个
                // id 首次出现的卡片挂 Hero（与 PlaylistPage 相似歌单同口径）。
                final firstId = firstIndexById(
                  [for (final a in albums) a.id],
                );
                return TvScrollRegion(
                  memoryKey: 'tv/browse-albums',
                  horizontalEdge: DpadEdgeBehavior.leave,
                  child: PinchableGridView(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                      AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                    ),
                    childAspectRatio: 0.8,
                    spacing: 12,
                    itemCount: albums.length,
                    itemBuilder: (context, i) {
                      final album = albums[i];
                      return AlbumCard(
                        album: album,
                        heroTag: firstId[album.id] == i && album.id.isNotEmpty
                            ? albumCoverHeroTag(album.id)
                            : null,
                        onTap: () => AdaptiveNav.openDetail(
                          context,
                          (_) => AlbumDetailPage(album: album),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}

/// 排行榜歌曲页（从发现页迁移）。
class RankDetailPage extends StatefulWidget {
  final String rankId;
  final String rankName;
  const RankDetailPage({super.key, required this.rankId, required this.rankName,
  });
  @override
  State<RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends State<RankDetailPage> {
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
      body: SecondaryMiniPlayerHost(
        child: _isLoading
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
                return TvScrollRegion(
                  memoryKey: 'tv/browse-rank',
                  horizontalEdge: DpadEdgeBehavior.leave,
                  child: ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                      AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
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
                  ),
                );
              },
            ),
      ),
    );
  }
}


/// 内容模块标题行：标题 + 可选「›」更多入口。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onMore});

  final String title;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.sm, AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onMore != null)
            IconButton(
              onPressed: onMore,
              icon: const Icon(Icons.chevron_right),
            ),
        ],
      ),
    );
  }
}

/// 2 列小封面网格：每格「小方封面（左）+ 标题/曲数（右）」，与每日推荐的
/// 列表项形态一致，两两并排。最多展示 [maxItems] 个，其余在标题「›」里查看。
class _CompactAlbumGrid extends StatelessWidget {
  const _CompactAlbumGrid({
    required this.albums,
    required this.onTap,
    required this.regionKey,
    this.maxItems = 6,
    this.heroTags,
  });

  final List<Album> albums;
  final ValueChanged<int> onTap;
  final int maxItems;

  /// 与 [albums] 等长的 Hero tag 表；null 或表内 null = 该格不参与封面连贯过渡。
  /// **tag 必须按目标页收到的 id 口径由调用方构造**：进 `PlaylistPage` 用
  /// `playlistCoverHeroTag`、进 `AlbumDetailPage` 用 `albumCoverHeroTag`——
  /// 与对应完整列表页卡片的 tag 同口径，区块 → 完整列表的推入也靠它衔接。
  final List<String?>? heroTags;

  /// tv: 焦点区域记忆键，同一组件在三处调用点各用一把（同一 memoryKey
  /// 会被 dpad 视为同一个区域，离开再回来会串到别的面板位置）。
  final String regionKey;

  @override
  Widget build(BuildContext context) {
    final count = albums.length < maxItems ? albums.length : maxItems;
    // 计划 4.7：按面板局部宽度定列数——桌面宽面板多列，手机仍两列。
    return LayoutBuilder(
      builder: (context, c) {
        final columns = gridColumnsForWidth(c.maxWidth,
                targetExtent: 280, min: c.maxWidth < 360 ? 1 : 2, max: 4,
        )
            ;
        final rows = <Widget>[];
        for (var i = 0; i < count; i += columns) {
          final cells = <Widget>[];
          for (var j = 0; j < columns; j++) {
            final idx = i + j;
            if (j > 0) cells.add(const Gap(AppSpacing.md));
            cells.add(
              Expanded(
                child: idx < count
                    ? _cell(context, idx)
                    : const SizedBox.shrink(),
              ),
            );
          }
          rows.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: cells,
              ),
            ),
          );
        }
        return TvScrollRegion(
            memoryKey: regionKey,
            horizontalEdge: DpadEdgeBehavior.leave,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          );
      },
    );
  }

  Widget _cell(BuildContext context, int index) {
    final cs = Theme.of(context).colorScheme;
    final album = albums[index];
    final heroTag = (heroTags != null && index < heroTags!.length)
        ? heroTags![index]
        : null;
    final image = CachedNetworkImage(
      imageUrl: album.artworkUri ?? '',
      memCacheWidth: 156,
      memCacheHeight: 156,
      fit: BoxFit.cover,
      placeholder: (_, _) =>
          _MusicExploreSectionsState._coverPlaceholder(cs),
      errorWidget: (_, _, _) =>
          _MusicExploreSectionsState._coverPlaceholder(cs),
    );
    final row = InkWell(
      onTap: () => onTap(index),
      borderRadius: AppRadius.mdAll,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: AppRadius.smAll,
              child: SizedBox(
                width: 52,
                height: 52,
                child: heroTag == null
                    ? image
                    : PlaylistCoverHero(
                        tag: heroTag,
                        radius: AppRadius.smAll,
                        child: image,
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                album.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
              ),
            ),
          ],
        ),
      ),
    );

    // tv: 区块行单停点（OK = 原 onTap）。
    return TvCardFocus(
      onSelect: () => onTap(index),
      debugLabel: 'explore-mini-row',
      child: row,
    );
  }
}

/// 热门歌单浏览页（从发现页迁移）。
class PlaylistBrowsePage extends StatefulWidget {
  const PlaylistBrowsePage({super.key});
  @override
  State<PlaylistBrowsePage> createState() => _PlaylistBrowsePageState();
}

class _PlaylistBrowsePageState extends State<PlaylistBrowsePage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // 完整列表与搜索页区块共用同一份 Provider 数据：从区块「›」进来时通常已
    // 加载完毕。转场首帧必须就有网格上的 Hero 端点（区块小封面 → 完整列表大
    // 封面的衔接，见 NewAlbumBrowsePage 同处的说明）——先按现有数据渲染，
    // 后台只做一次补拉刷新。
    _isLoading = context.read<KugouProvider>().playlistList.isEmpty;
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
                // Hero tag 唯一性防护：完整列表来自服务端，可能出现重复 gid；
                // 只给每个 id 首次出现的卡片挂 Hero（tag 口径与搜索页区块一致，
                // 推入/返回时区块小封面 ↔ 完整列表大封面成对飞行）。
                final firstGid = firstIndexById(
                  [for (final p in list) p.globalCollectionId ?? p.id],
                );
                return TvScrollRegion(
                  memoryKey: 'tv/browse-playlists',
                  horizontalEdge: DpadEdgeBehavior.leave,
                  child: PinchableGridView(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                      AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                    ),
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
                      heroTag:
                          firstGid[list[i].globalCollectionId ?? list[i].id] == i
                              ? playlistCoverHeroTag(
                                  list[i].globalCollectionId ?? list[i].id,
                                )
                              : null,
                      onTap: () => AdaptiveNav.openDetail(context,
                        (_) =>
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

