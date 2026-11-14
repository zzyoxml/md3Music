// 本文件刻意只 import flutter/material，不 import material_ui：material_ui 的
// Scaffold 给 body 包的是它自家同名的 Material 类，flutter/material 的 InkWell
// 按类型找不到祖先会抛 No Material widget found（被全局兜底顶成「此处内容加载出错」），
// 故卡片自带一层 flutter/material 的 Material。
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../core/build_flags.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/models/album.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/album_card.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/playlist_cover_hero.dart';

/// 歌手专辑网格（纯展示 sliver，供调用页的 CustomScrollView 直接使用）。
///
/// 分页 / loading / 空态均由调用页负责，所以这里必须 `shrinkWrap` +
/// `NeverScrollableScrollPhysics`：整页只允许一条滚动轴，不能再起第二条。
/// 同理**不能传 `loadingWidget`** —— PinchableGridView 在它有值时会用
/// `Column + Expanded` 包裹，而 Expanded 在 SliverToBoxAdapter 给的无界高度下抛异常。
class ArtistAlbumGridSliver extends StatelessWidget {
  final List<Album> albums;
  final ValueChanged<int>? onTap;

  const ArtistAlbumGridSliver({
    super.key,
    required this.albums,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Hero tag 唯一性防护：服务端专辑列表可能返回重复 id，同一路由子树内重复 tag
    // 会在转场收集阶段抛 FlutterError，故只给每个 id 首次出现的那张卡挂 Hero。
    final firstId = firstIndexById([for (final a in albums) a.id]);
    Widget grid = PinchableGridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      childAspectRatio: 0.8,
      spacing: 12,
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final album = albums[i];
        final card = AlbumCard(
          album: album,
          heroTag: firstId[album.id] == i && album.id.isNotEmpty
              ? albumCoverHeroTag(album.id)
              : null,
          onTap: () => onTap?.call(i),
        );
        // tv: 卡片是网格里的唯一停点（excludeChildFocus 默认 true，AlbumCard 内的
        // InkWell 不再单独进遍历），手机版保持触屏 onTap 不包。
        if (!kTvBuild) return card;
        return DpadFocusable(
          onSelect: () => onTap?.call(i),
          child: card,
        );
      },
    );
    if (kTvBuild) {
      grid = TvScrollRegion(
        memoryKey: 'tv/artist-albums',
        horizontalEdge: DpadEdgeBehavior.leave,
        child: grid,
      );
    }
    return SliverToBoxAdapter(child: grid);
  }
}

/// 歌手 MV 网格（纯展示 sliver，滚动/约束口径与 [ArtistAlbumGridSliver] 一致）。
class ArtistMvGridSliver extends StatelessWidget {
  final List<KugouMvBrief> mvs;
  final ValueChanged<int>? onTap;

  const ArtistMvGridSliver({
    super.key,
    required this.mvs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget grid = PinchableGridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      childAspectRatio: 0.75,
      spacing: 12,
      itemCount: mvs.length,
      itemBuilder: (context, i) {
        final card = _ArtistMvCard(mv: mvs[i], onTap: () => onTap?.call(i));
        // tv: 同专辑网格，MV 卡自带 InkWell，TV 下由 DpadFocusable 单停点接管。
        if (!kTvBuild) return card;
        return DpadFocusable(
          onSelect: () => onTap?.call(i),
          child: card,
        );
      },
    );
    if (kTvBuild) {
      grid = TvScrollRegion(
        memoryKey: 'tv/artist-mv',
        horizontalEdge: DpadEdgeBehavior.leave,
        child: grid,
      );
    }
    return SliverToBoxAdapter(child: grid);
  }
}

/// MV 卡片：封面 + 播放角标 + 标题 + 副信息（作者 · 时长 · 年份）。
///
/// 不做封面连贯过渡（Hero）：MV 详情侧没有落点，挂了只会撞 tag 或静默不飞。
class _ArtistMvCard extends StatelessWidget {
  final KugouMvBrief mv;
  final VoidCallback? onTap;

  const _ArtistMvCard({required this.mv, this.onTap});

  /// 无封面/加载失败占位：透明背景 + 类型图标，避免大块纯色矩形。
  Widget _placeholder(ColorScheme cs) {
    return ColoredBox(
      color: Colors.transparent,
      child: Center(
        child: Icon(Icons.videocam_outlined, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// 缺哪个字段就少渲染哪一段，全缺时返回 null（副信息行整行不出现）。
  String? _subtitle() {
    final parts = <String>[];
    final author = mv.authorName;
    if (author != null && author.isNotEmpty) parts.add(author);
    if (mv.timelengthMs > 0) {
      final seconds = mv.timelengthMs ~/ 1000;
      parts.add('${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}');
    }
    final publishDate = mv.publishDate;
    if (publishDate != null && publishDate.length >= 4) {
      final year = int.tryParse(publishDate.substring(0, 4));
      if (year != null) parts.add('$year');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final subtitle = _subtitle();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: cs.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (mv.coverUrl != null)
                      CachedNetworkImage(
                        imageUrl: mv.coverUrl!,
                        memCacheWidth: 540,
                        memCacheHeight: 540,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _placeholder(cs),
                      )
                    else
                      _placeholder(cs),
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill,
                        color: Colors.white70,
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mv.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.labelMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
