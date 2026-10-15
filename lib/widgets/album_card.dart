import 'package:material_ui/material_ui.dart';

import '../core/remote/tv_card_focus.dart';
import '../core/theme/app_dimens.dart';
import '../data/models/album.dart';
import 'playlist_cover_hero.dart';
import 'smart_artwork_image.dart';

class AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback? onTap;

  /// 非空时封面参与封面连贯过渡（Hero）。
  /// **tag 必须由调用方按目标详情页实际收到的 id 口径构造**：
  /// - 进 `PlaylistPage` → `playlistCoverHeroTag(...)`，且要与该来源 `toPlaylist()`
  ///   的 id 口径一致（热门歌单 Album 用 brief.id，Playlist.id 用
  ///   globalCollectionId ?? id，两者可能不同）；
  /// - 进 `AlbumDetailPage` → `albumCoverHeroTag(album.id)`，与详情页
  ///   `widget.album.id` 同源。
  final String? heroTag;

  /// 与 [heroTag] 搭配的封面圆角。卡片外层 ClipRRect(16) 圆整卡四角，封面区
  /// 只占卡片上部——其可见圆角仅上两角，故默认值是「上圆角 16、下 0」。
  final BorderRadius heroRadius;

  const AlbumCard({
    super.key,
    required this.album,
    this.onTap,
    this.heroTag,
    this.heroRadius = const BorderRadius.vertical(
      top: Radius.circular(AppRadius.lg),
    ),
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final card = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            children: [
              Expanded(
                child: heroTag == null
                    ? SmartArtworkImage(
                        artworkUri: album.artworkUri,
                        size: double.infinity,
                        borderRadius: 0,
                      )
                    : PlaylistCoverHero(
                        tag: heroTag!,
                        radius: heroRadius,
                        child: SmartArtworkImage(
                          artworkUri: album.artworkUri,
                          size: double.infinity,
                          borderRadius: 0,
                        ),
                      ),
              ),
              _buildInfo(colorScheme, textTheme),
            ],
          ),
        ),
      ),
    );

    // tv: 卡片单停点（OK = 原 onTap）。本卡被首页/探索/榜单/搜索等多条
    // 横向带复用，在组件内部接一次焦点线，带子调用点无需重复包装。
    // 刻意不带缩放特效：焦点缩放会让 PlaylistCoverHero 从放大后的矩形起飞。
    return TvCardFocus(
      onSelect: onTap,
      debugLabel: 'album-card',
      child: card,
    );
  }

  Widget _buildInfo(ColorScheme colorScheme, TextTheme textTheme) {
    final hasArtist = album.artist.isNotEmpty;
    return Container(
      // 文字信息块在卡片下方区域内垂直居中（minHeight 兜住单行标题）
      constraints: const BoxConstraints(minHeight: 40),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
            // 无副标题（如热门歌单 artist 为空）时不渲染空行，避免文字下方留大片空白
            if (hasArtist) ...[
              const SizedBox(height: 2),
              Text(
                album.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
