import 'dart:math' as math;

import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import '../../core/build_flags.dart';
import '../../core/layout/adaptive_navigator.dart';
import '../../core/layout/bottom_chrome_scope.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/playlist_cover_hero.dart';
import 'album_detail_page.dart';

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
    // 完整列表与发现页区块共用同一份 Provider 数据：从区块「›」进来时通常已
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
                final hasCurrentSong = context.select<PlayerProvider, bool>(
                  (player) => player.currentSong != null,
                );
                final miniPlayerInset =
                    BottomChromeScope.playerContentBottomInsetOf(
                      context,
                      hasPlayer: hasCurrentSong &&
                          !kTvBuild &&
                          !isDesktopLayout(context),
                    );
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
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg +
                          math.max(
                            MediaQuery.paddingOf(context).bottom,
                            miniPlayerInset,
                          ),
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
