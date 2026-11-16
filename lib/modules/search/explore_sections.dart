import '../../core/layout/adaptive_navigator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/album.dart';
import '../player/secondary_mini_player.dart';
import '../../widgets/song_list_item.dart';
import '../../providers/player_provider.dart';
import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';
import 'search_section_header.dart';
import '../../core/theme/app_dimens.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/compact_album_grid.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../playlist/playlist_page.dart';
import '../charts/charts_page.dart';

/// 搜索空态的音乐探索：主题歌单、推荐歌单与排行榜（新碟上架已移至发现页）。
/// 浏览入口独立于主题歌单数据，避免该接口返回空或失败时整段入口消失。
/// 复用 Provider 的缓存，只对缺失的数据独立补拉，不等待主题请求。
class MusicExploreSections extends StatefulWidget {
  const MusicExploreSections({super.key});

  @override
  State<MusicExploreSections> createState() => _MusicExploreSectionsState();
}

class _MusicExploreSectionsState extends State<MusicExploreSections> {
  /// 主题卡宽度（=1:1 封面边长）。口径沿用原搜索空态横滑带，未另调。
  static const double _themeCardExtent = 130;

  /// 横滑带高度 = 封面 [_themeCardExtent] + 文本区 36
  /// （titleSmall 行高 20 + 上下内衬 AppSpacing.sm 各 8，恰好填满）。
  static const double _themeBandHeight = 166;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  /// 仅在数据缺失时补拉；forceRefresh=false 命中 5 分钟缓存即不重复请求，
  /// 与其它页面共享同一份 KugouProvider 数据。
  void _ensureLoaded() {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    if (kugou.themePlaylistData.isEmpty) kugou.getThemePlaylist();
    if (kugou.playlistList.isEmpty) kugou.getPlaylist();
    if (kugou.rankList == null) kugou.getRankList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 入口不放进任何数据 Selector，首次打开和请求失败时也始终可见。
        const SearchSectionHeader(title: '探索音乐'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Wrap(
            spacing: AppSpacing.sm,
            children: [
              _buildExploreEntry('热门歌单', Icons.queue_music,
                  (_) => const PlaylistBrowsePage()),
              _buildExploreEntry('排行榜', Icons.leaderboard,
                  (_) => const ChartsPage()),
            ],
          ),
        ),
        _buildThemeSection(),
        _buildPlaylistSection(),
        _buildRankSection(),
        const Gap(AppSpacing.sm),
      ],
    );
  }

  Widget _buildExploreEntry(String label, IconData icon, WidgetBuilder page) {
    void open() => AdaptiveNav.openDetail(context, page);
    return TvCardFocus(
      onSelect: open,
      debugLabel: 'explore-entry-$label',
      child: SearchSectionAction(icon: icon, label: label, onTap: open),
    );
  }

  /// 主题歌单仍保留原有横滑展示；它的数据不控制其他目录的显示。
  Widget _buildThemeSection() {
    return Selector<KugouProvider, List<KugouThemeInfo>>(
      selector: (_, kugou) => kugou.themePlaylistData,
      builder: (context, themes, _) {
        if (themes.isEmpty) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _themeBandHeight,
              child: TvScrollRegion(
                memoryKey: 'tv/explore-themes-row',
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  itemCount: themes.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.md),
                    child: SizedBox(
                      width: _themeCardExtent,
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
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    themes[i].name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.titleSmall,
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
            _ExploreSectionHeader(
              title: '推荐歌单',
              onMore: () => AdaptiveNav.openDetail(context,
                (_) => const PlaylistBrowsePage(),
              ),
            ),
            CompactAlbumGrid(
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
            _ExploreSectionHeader(
              title: '排行榜',
              onMore: () => AdaptiveNav.openDetail(context, (_) => const ChartsPage()),
            ),
            CompactAlbumGrid(
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


}

/// 热门歌单浏览页（从发现页迁移）：完整歌单网格，
/// 也是探索段段头「探索更多」的目标页。
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
    // 完整列表与其它页面共用同一份 Provider 数据：从「探索更多」进来时通常已
    // 加载完毕。转场首帧必须就有网格上的 Hero 端点（区块小封面 → 完整列表大
    // 封面的衔接）——先按现有数据渲染，后台只做一次补拉刷新。
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
                // 只给每个 id 首次出现的卡片挂 Hero（tag 口径与引用方一致，
                // 推入/返回时封面成对飞行）。
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
                    // 0.8 与搜索结果卡、专辑浏览卡统一（浏览页已验证值）。
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
                        M3EButton(
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


/// 复用当前搜索页的标题样式与 TV 单停点，而不是恢复旧版独立标题控件。
class _ExploreSectionHeader extends StatelessWidget {
  const _ExploreSectionHeader({required this.title, required this.onMore});
  final String title;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => SearchSectionHeader(
        title: title,
        actions: [
          TvCardFocus(
            onSelect: onMore,
            debugLabel: 'explore-more-$title',
            child: SearchSectionAction(
              label: '查看全部', icon: Icons.chevron_right, onTap: onMore),
          ),
        ],
      );
}
