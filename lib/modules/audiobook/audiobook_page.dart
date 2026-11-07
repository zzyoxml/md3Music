import '../../core/layout/adaptive_navigator.dart';
import '../../core/layout/responsive_layout.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/theme/app_dimens.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/smart_artwork_image.dart';
import 'audiobook_album_detail_page.dart';
import 'audiobook_free_library_page.dart';
import 'audiobook_search_page.dart';

/// 听书 Tab 主页：聚合 每日推荐 / 排行榜推荐 / 每周推荐 / VIP 推荐 四个分区。
class AudiobookPage extends StatefulWidget {
  const AudiobookPage({super.key});

  @override
  State<AudiobookPage> createState() => _AudiobookPageState();
}

class _AudiobookPageState extends State<AudiobookPage> {
  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAll();
    });
  }

  /// 并行加载四个推荐接口。
  Future<void> _loadAll() async {
    final kugou = context.read<KugouProvider>();
    await Future.wait([
      kugou.getLongaudioDaily(),
      kugou.getLongaudioRank(),
      kugou.getLongaudioVip(),
      kugou.getLongaudioWeek(),
    ]);
    if (mounted) setState(() => _isLoading = false);
  }

  /// 从每日推荐原始数据中提取专辑列表（字段多级兜底，不做 VIP 过滤，全量展示限免内容）。
  List<KugouLongAudioAlbum> _parseDailyAlbums() {
    final raw = context.read<KugouProvider>().longAudioData;
    if (raw == null) return [];
    final data = raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    final list = data['list'] ?? data['info'] ?? data['albums'];
    if (list is! List) return [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(KugouLongAudioAlbum.fromJson)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kugou = context.watch<KugouProvider>();

    final dailyAlbums = _parseDailyAlbums();
    final sectionAlbums = <List<KugouLongAudioAlbum>>[
      dailyAlbums,
      kugou.longAudioAlbums,
      kugou.longAudioWeekAlbums,
      kugou.longAudioVipAlbums,
    ];
    final sectionTitles = const [
      '每日推荐',
      '排行榜推荐',
      '每周推荐',
      'VIP 推荐 仅显示不要听书会员的章节',
    ];
    // 同一专辑会跨 4 个推荐分区重复出现，而它们挂在同一棵 ListView 子树里：
    // 框架 Hero 要求 tag 在子树内唯一，重复会在转场收集阶段抛 FlutterError。
    // 展平取「每个 id 首次出现的下标」，再按各分区的起始偏移判定该不该挂 tag。
    final firstById = firstIndexById([
      for (final list in sectionAlbums) ...list.map((a) => a.id),
    ]);
    final sections = <Widget>[];
    var runningIndex = 0;
    for (var s = 0; s < sectionAlbums.length; s++) {
      sections.add(
        _AlbumSection(
          title: sectionTitles[s],
          albums: sectionAlbums[s],
          heroStartIndex: runningIndex,
          heroFirstIndexById: firstById,
        ),
      );
      runningIndex += sectionAlbums[s].length;
    }
    final hasAnyData = sectionAlbums.any((list) => list.isNotEmpty);
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '听书',
        // 有壁纸时顶栏完全透明（与发现页一致），无壁纸时恒不透明 surface
        opaque: true,
        scrollController: _scrollController,
        actions: [
          IconButton(
            tooltip: '搜索听书',
            icon: const Icon(Icons.search),
            onPressed: () {
              AdaptiveNav.openDetail(context,
                (_) => const AudiobookSearchPage(),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Md3PullToRefresh(
              onRefresh: _loadAll,
              child: hasAnyData
                  ? ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        const _FreeLibraryEntryCard(),
                        ...sections,
                      ],
                    )
                  : ListView(
                      controller: _scrollController,
                      children: [
                        const _FreeLibraryEntryCard(),
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.5,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.menu_book_outlined,
                                  size: 48,
                                  color: cs.onSurfaceVariant.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无听书数据',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                                const SizedBox(height: 16),
                                FilledButton.tonal(
                                  onPressed: _loadAll,
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
    );
  }
}

/// 免费听书库入口卡片：点击进入三级筛选列表页。
class _FreeLibraryEntryCard extends StatelessWidget {
  const _FreeLibraryEntryCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    Widget card = Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          AdaptiveNav.openDetail(context,
            (_) => const AudiobookFreeLibraryPage(),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.local_library_outlined, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('免费听书库', style: tt.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '分类 · 排序 · 男/女频 · 连载状态',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
    // tv: TV 构建下入口卡单停点（OK=进入免费听书库）
    if (kTvBuild) {
      card = DpadFocusable(
        onSelect: () {
          AdaptiveNav.openDetail(context,
            (_) => const AudiobookFreeLibraryPage(),
          );
        },
        child: card,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: card,
    );
  }
}

/// 单个听书分区：标题 + 横向滚动专辑卡片。
class _AlbumSection extends StatelessWidget {
  final String title;
  final List<KugouLongAudioAlbum> albums;

  /// 本分区第一张卡在「全页展平列表」里的下标偏移，配合 [heroFirstIndexById]
  /// 判断某张卡是不是该 id 的全页首次出现（见 AudiobookPage.build 的注释）。
  final int heroStartIndex;
  final Map<String, int> heroFirstIndexById;

  const _AlbumSection({
    required this.title,
    required this.albums,
    this.heroStartIndex = 0,
    this.heroFirstIndexById = const {},
  });

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = usesNavigationRail(constraints.maxWidth);
        final cardWidth = wide
            ? ((constraints.maxWidth - 32) / 3 - 12).clamp(130.0, 200.0)
            : 130.0;
        return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: tt.titleLarge),
        ),
        SizedBox(
          height: cardWidth + 58,
          // tv: TV 构建下横向封面轮播收进 DpadRegion——左右在区带内移动、
          // 到边缘回绕（wrap），上下可离开；memoryKey 保住回到本分区时的焦点位置。
          child: kTvBuild
              ? DpadRegion(
                  memoryKey: 'tv/audiobook/${title.hashCode}',
                  horizontalEdge: DpadEdgeBehavior.wrap,
                  child: _albumCarousel(cardWidth, cs, tt),
                )
              : _albumCarousel(cardWidth, cs, tt),
        ),
      ],
        );
      },
    );
  }

  /// 横向专辑封面轮播（P-A：每张卡单停点）。
  Widget _albumCarousel(double cardWidth, ColorScheme cs, TextTheme tt) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final album = albums[i];
        // 只有该 id 在全页首次出现的那张卡参与飞行（避免同子树重复 tag）。
        final heroTag = heroFirstIndexById[album.id] == heroStartIndex + i
            ? audiobookCoverHeroTag(album.id)
            : null;
        return Padding(
          padding: const EdgeInsets.only(right: 12),
          child: SizedBox(
            width: cardWidth,
            child: _buildAlbumCard(context, album, cs, tt, heroTag),
          ),
        );
      },
    );
  }

  Widget _buildAlbumCard(
    BuildContext context,
    KugouLongAudioAlbum album,
    ColorScheme cs,
    TextTheme tt,
    String? heroTag,
  ) {
    Widget card = Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          AdaptiveNav.openDetail(context,
                (_) => AudiobookAlbumDetailPage(album: album),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // 卡片外层 Material 圆整卡四角 16，封面只占上部 → 可见圆角仅上两角。
              // hero 的 radius 与之对齐，飞行起点才与静止封面逐像素重合；
              // child 保持未裁剪（圆角由 PlaylistCoverHero 自己施加）。
              child: heroTag == null
                  ? SmartArtworkImage(
                      artworkUri: album.coverUrl,
                      size: double.infinity,
                      borderRadius: 0,
                    )
                  : PlaylistCoverHero(
                      tag: heroTag,
                      radius: const BorderRadius.vertical(
                        top: Radius.circular(AppRadius.lg),
                      ),
                      child: SmartArtworkImage(
                        artworkUri: album.coverUrl,
                        size: double.infinity,
                        borderRadius: 0,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    album.author ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // tv: TV 构建下封面卡单停点（OK=进入专辑详情）
    if (kTvBuild) {
      card = DpadFocusable(
        onSelect: () {
          AdaptiveNav.openDetail(context,
                (_) => AudiobookAlbumDetailPage(album: album),
          );
        },
        child: card,
      );
    }
    return card;
  }
}
