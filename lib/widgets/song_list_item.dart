import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils/app_toast.dart';
import '../data/models/song.dart';
import '../modules/player/comments_view.dart';
import '../modules/player/mv_player_page.dart';
import '../providers/favorites_provider.dart';
import '../providers/local_favorites_provider.dart';
import '../providers/player_provider.dart';
import 'playing_spectrum_indicator.dart';
import 'smart_artwork_image.dart';

class SongListItem extends StatelessWidget {
  /// 可选扩展：歌曲更多菜单的额外条目（默认关闭，由私有构建注入）。
  /// 返回的 Widget 追加在菜单底部（「下一首播放」之前）。
  static List<Widget> Function(BuildContext context, Song song)?
      extraMenuTilesBuilder;

  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onMoreTap;
  final bool showDuration;
  final bool forceFavorited;

  /// 多选模式：显示圆形复选框替代封面，点击切换选中而非播放。
  final bool isSelectMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onSelectToggle;

  const SongListItem({
    super.key,
    required this.song,
    this.onTap,
    this.onMoreTap,
    this.showDuration = true,
    this.forceFavorited = false,
    this.isSelectMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onSelectToggle,
  });

  void _showMoreMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.music_note),
              title: Text(song.displayName),
              subtitle: Text(song.artist),
            ),
            const Divider(height: 1),
            // 可选扩展：私有构建注入的额外菜单条目（默认无）
            ...?SongListItem.extraMenuTilesBuilder?.call(ctx, song),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('下一首播放'),
              onTap: () {
                Navigator.pop(ctx);
                final player = context.read<PlayerProvider>();
                player.insertAfterCurrent([song]);
                showToast('已加入下一首', long: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.comment_outlined),
              title: const Text('看评论'),
              onTap: () {
                Navigator.pop(ctx);
                showSongCommentsSheet(context, song);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final favoritesProvider = context.watch<FavoritesProvider>();
    final localFavoritesProvider = context.watch<LocalFavoritesProvider>();
    final isCurrentSong = playerProvider.currentSong?.id == song.id;
    final isFavorited = forceFavorited
        ? true
        : (song.isOnline
            ? favoritesProvider.isFavorite(song.id)
            : localFavoritesProvider.isFavorite(song.id));
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    const imgSize = 52.0; // 正方形封面，不被 ListTile 压缩

    return InkWell(
      onTap: isSelectMode ? onSelectToggle : onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelectMode && isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // 多选模式：圆形复选框；普通模式：封面图
            if (isSelectMode)
              _buildCheckbox(colorScheme, imgSize)
            else
              // 封面图：智能选择 Image.network（在线/content://）或 LocalArtworkImage（文件路径）
              SmartArtworkImage(
                artworkUri: song.artworkUri,
                fallbackFilePath: song.localPath,
                songId: song.id,
                size: imgSize,
                borderRadius: 8,
              ),
            const SizedBox(width: 12),

            // 标题 + 副标题
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    song.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: isCurrentSong ? colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} - ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: isCurrentSong
                          ? colorScheme.primary.withValues(alpha: 0.7)
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            // 右侧操作区：多选模式下不显示
            if (!isSelectMode)
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (isCurrentSong)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      // 频谱动画标识：3 根粒度柱 sin 波动
                      // 暂停时 isPlaying=false → ticker 停止，保留最后一帧
                      // 继续播放时 isPlaying=true → ticker 恢复，动画继续
                      child: PlayingSpectrumIndicator(
                        color: colorScheme.primary,
                        size: 14,
                        isPlaying: playerProvider.isPlaying,
                      ),
                    ),
                  if (showDuration)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(song.displayDuration, style: textTheme.labelSmall),
                    ),
                  GestureDetector(
                    onTap: () => song.isOnline
                        ? favoritesProvider.toggleFavorite(song)
                        : localFavoritesProvider.toggleFavorite(song.id),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                      child: Icon(
                        isFavorited ? Icons.favorite : Icons.favorite_border,
                        size: 18,
                        color: isFavorited ? colorScheme.error : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (song.isOnline)
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
                      ),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                        child: Icon(Icons.music_video_outlined, size: 18, color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  GestureDetector(
                    onTap: () => _showMoreMenu(context),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                      child: Icon(Icons.more_vert, size: 18, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 多选模式下的圆形复选框，与封面同等大小。
  Widget _buildCheckbox(ColorScheme colorScheme, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: isSelected
            ? Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary,
                ),
                child: Icon(
                  Icons.check,
                  color: colorScheme.onPrimary,
                  size: 28,
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.5),
                    width: 2,
                  ),
                ),
              ),
      ),
    );
  }
}
