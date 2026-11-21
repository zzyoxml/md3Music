import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart' as flutter;
import 'package:material_ui/material_ui.dart';
import '../core/layout/responsive_layout.dart';
import '../core/remote/tv_card_focus.dart';
import '../core/remote/tv_scroll_region.dart';
import '../core/theme/app_dimens.dart';
import '../data/models/album.dart';
import 'playlist_cover_hero.dart';

/// 2 列小封面网格：每格「小方封面（左）+ 标题/曲数（右）」，与每日推荐的
/// 列表项形态一致，两两并排。最多展示 [maxItems] 个，其余在标题「›」里查看。
class CompactAlbumGrid extends StatelessWidget {
  const CompactAlbumGrid({
    super.key,
    required this.albums,
    required this.onTap,
    required this.regionKey,
    this.heroTags,
    this.maxItems = 6,
    this.columns,
    this.favoriteBuilder,
  });

  final List<Album> albums;
  final ValueChanged<int> onTap;
  final int maxItems;

  /// 与 [albums] 等长的 Hero tag 表；null 或表内 null = 该格不参与封面连贯过渡。
  /// **tag 必须按目标页收到的 id 口径由调用方构造**：进 `PlaylistPage` 用
  /// `playlistCoverHeroTag`、进 `AlbumDetailPage` 用 `albumCoverHeroTag`——
  /// 与对应完整列表页卡片的 tag 同口径，区块 → 完整列表的推入也靠它衔接。
  final List<String?>? heroTags;

  /// 强制列数（null = 按面板局部宽度自适应）。
  ///
  /// 用于「必须 N 行」的场景：发现页「新碟上架」与新歌速递在宽屏并排，
  /// 新歌固定 4 行，新碟如果按宽度自适应成 2 列，就只排 2 行、右侧空掉一截，
  /// 两栏参差不齐。传 1 让它单列 4 行，与邻居等高。
  final int? columns;

  /// 行尾附加控件（可选）。返回 null 或长度 0 时不占位。
  ///
  /// 用于在专辑行右侧放「收藏」等操作。只由宿主提供，组件本身不认识
  /// 收藏语义（发现页与探索页的可收藏条件不同）。
  final Widget? Function(BuildContext context, Album album)? favoriteBuilder;

  /// tv: 焦点区域记忆键，同一组件在三处调用点各用一把（同一 memoryKey
  /// 会被 dpad 视为同一个区域，离开再回来会串到别的面板位置）。
  final String regionKey;

  @override
  Widget build(BuildContext context) {
    final count = albums.length < maxItems ? albums.length : maxItems;
    // 计划 4.7：按面板局部宽度定列数——桌面宽面板多列，手机仍两列。
    // [columns] 非空时以调用方指定为准（见其文档）。
    return LayoutBuilder(
      builder: (context, c) {
        final columns = this.columns ??
            gridColumnsForWidth(c.maxWidth,
              targetExtent: 280, min: c.maxWidth < 360 ? 1 : 2, max: 4,
            );
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
          _coverPlaceholder(cs),
      errorWidget: (_, _, _) =>
          _coverPlaceholder(cs),
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
            const Gap(AppSpacing.md),
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
            ?favoriteBuilder?.call(context, album),
          ],
        ),
      ),
    );

    // tv: 区块行单停点（OK = 原 onTap）。
    return TvCardFocus(
      onSelect: () => onTap(index),
      debugLabel: 'explore-mini-row',
      child: flutter.Material(
        type: flutter.MaterialType.transparency,
        child: row,
      ),
    );
  }
  static Widget _coverPlaceholder(ColorScheme cs) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      );
}
