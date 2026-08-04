import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../../widgets/md3e_refresh_indicator.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/smart_artwork_image.dart';
import 'audiobook_album_detail_page.dart';

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

  /// 从每日推荐原始数据中提取专辑列表（字段多级兜底）。
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
    final sections = [
      _AlbumSection(title: '每日推荐', albums: dailyAlbums),
      _AlbumSection(title: '排行榜推荐', albums: kugou.longAudioAlbums),
      _AlbumSection(title: '每周推荐', albums: kugou.longAudioWeekAlbums),
      _AlbumSection(title: 'VIP 推荐', albums: kugou.longAudioVipAlbums),
    ];
    final hasAnyData = sections.any((s) => s.albums.isNotEmpty);

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '听书',
        scrollController: _scrollController,
      ),
      body: _isLoading
          ? const Center(child: MD3ELoadingIndicator())
          : MD3ERefreshIndicator(
              onRefresh: _loadAll,
              child: hasAnyData
                  ? ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.only(bottom: 16),
                      children: sections,
                    )
                  : ListView(
                      controller: _scrollController,
                      children: [
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

/// 单个听书分区：标题 + 横向滚动专辑卡片。
class _AlbumSection extends StatelessWidget {
  final String title;
  final List<KugouLongAudioAlbum> albums;

  const _AlbumSection({required this.title, required this.albums});

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: tt.titleLarge),
        ),
        SizedBox(
          height: 188,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final album = albums[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 130,
                  child: Material(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                AudiobookAlbumDetailPage(album: album),
                          ),
                        );
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SmartArtworkImage(
                              artworkUri: album.coverUrl,
                              size: double.infinity,
                              borderRadius: 0,
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
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
