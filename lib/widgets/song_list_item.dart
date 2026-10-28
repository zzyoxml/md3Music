import 'package:dpad/dpad.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/build_flags.dart';
import '../core/remote/tv_menu_key_shortcuts.dart';
import '../core/services/lyrico_editor.dart';
import '../core/utils/app_haptics.dart';
import '../core/utils/app_toast.dart';
import '../data/models/song.dart';
import '../modules/library/song_match_sheet.dart';
import '../modules/player/comments_view.dart';
import '../modules/player/song_accompany_sheet.dart';
import '../modules/player/song_ranking_sheet.dart';
import '../modules/sheet/song_sheet_sheet.dart';
import '../modules/player/full_player_route.dart' show activePlayerRoute;
import '../modules/player/mv_player_page.dart';
import '../modules/player/player_cover_morph.dart' show PlayerCoverMorphBus;
import '../providers/favorites_provider.dart';
import '../providers/blacklist_provider.dart';
import '../providers/kugou_provider.dart';
import '../providers/local_favorites_provider.dart';
import '../providers/player_provider.dart';
import 'add_to_playlist_dialog.dart';
import 'play_next_flight.dart';
import 'playing_spectrum_indicator.dart';
import 'smart_artwork_image.dart';
import 'song_menu_header.dart';
import 'song_menu_info_badges.dart';

/// 「复制歌名与歌手」写入剪贴板的文本（格式：`歌名 - 歌手`）。
///
/// 歌名取 [Song.displayName]（已剥离 `.mp3`/`.flac` 等扩展名后缀）；
/// 歌手经 [isUnknownArtist] 判空（覆盖在线 `未知歌手` 与本地 `未知艺术家`），
/// 缺省时退化为仅返回歌名——避免拼出 `歌名 - 未知歌手` 后缀。
String formatSongCopyText(Song song) {
  final title = song.displayName.trim();
  if (isUnknownArtist(song.artist)) {
    return title;
  }
  final artist = song.artist.trim();
  if (title.isEmpty) return artist;
  return '$title - $artist';
}

/// 歌曲行右侧操作区的呈现策略。
///
/// 不同场景只改变尾部操作，不改变歌曲行整体的视觉结构，从而保持跨页面一致性。
/// 用明确的枚举而非堆叠多个零散布尔参数（见改版计划三）。
enum SongTrailingActions {
  /// 默认完整操作：时长（受 [SongListItem.showDuration] 控制）+ 收藏 + 更多菜单。
  full,

  /// 每日推荐：右侧仅收藏按钮，不显示时长与更多菜单。
  favoriteOnly,

  /// 收藏 + 更多菜单，但不显示时长。
  ///
  /// 给"只有歌名/歌手有用，时长是噪音"的列表用——发现页每日推荐与刷歌推荐的
  /// **详情页**就是这一档：行尾要跟歌单页一样有三点菜单可点，但不要时长。
  favoriteAndMore,

  /// 搜索结果：MV + 详情（三个点，收藏并入详情面板），不显示时长与独立收藏按钮。
  /// MV 在前、三个点在最右；云盘歌曲不显示不可用的 MV 按钮。
  detailAndMv,
}

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

  /// 右侧操作区呈现策略，默认完整操作（见 [SongTrailingActions]）。
  final SongTrailingActions trailingActions;

  /// 可选副标题覆盖：非空时替换默认的「歌手 - 专辑」行
  /// （如歌词搜索结果用于显示命中的歌词片段）。
  final Widget? subtitleOverride;

  /// 多选模式：显示圆形复选框替代封面，点击切换选中而非播放。
  final bool isSelectMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onSelectToggle;

  /// tv: 遥控「菜单键」回调覆盖。默认回退整行长按 / 更多菜单；
  /// 歌单/收藏/云音乐等页面可重定向为进入多选/管理模式（仅 kTvBuild 使用）。
  final VoidCallback? onContextMenuOverride;

  const SongListItem({
    super.key,
    required this.song,
    this.onTap,
    this.onMoreTap,
    this.showDuration = true,
    this.forceFavorited = false,
    this.trailingActions = SongTrailingActions.full,
    this.subtitleOverride,
    this.isSelectMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onSelectToggle,
    this.onContextMenuOverride,
  });

  /// 菜单头信息徽章的 privilege/lite 拉取函数。
  ///
  /// KugouProvider 缺席（纯组件级测试 harness）时返回 null，徽章退化为
  /// 只显示即时数据——菜单本体不受影响。
  SongMenuInfoFetcher? _menuInfoFetcher(BuildContext context) {
    try {
      final apiClient = context.read<KugouProvider>().apiClient;
      return (hash, albumId) => apiClient.getPrivilegeLite(hash, albumId: albumId);
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _showMoreMenu(BuildContext context) {
    // 「下一首播放」的菜单内收缩控制器：每次打开菜单新建一次。
    final shrinkController = SongMenuHeaderShrinkController();
    // 收缩期间菜单仍开着，双击会重复入队/起飞——本菜单内只允许触发一次。
    var playNextStarted = false;
    showM3EModalBottomSheet(
      context: context,
      // 「更多」菜单改为实色：全局 M3E 弹层主题默认用 0.97 alpha 让背景图
      // 透出，这里显式给不透明色，避免菜单压在封面/壁纸上时内容难以辨认。
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 头部：圆角矩形封面 + 歌名/歌手/专辑 + 信息徽章（时长/音质/大小/VIP）
            SongMenuHeader(
              song: song,
              shrinkController: shrinkController,
              infoFetcher: _menuInfoFetcher(context),
            ),
            const Divider(height: 1),
            // 收藏 / 取消收藏：详情面板内实时状态。搜索结果的收藏入口即在此
            // （列表行不再放独立收藏按钮），其他场景作为附加操作也无害。
            Consumer2<FavoritesProvider, LocalFavoritesProvider>(
              builder: (ctx2, favorites, localFavorites, _) {
                final favorited = forceFavorited
                    ? true
                    : (song.isOnline
                        ? favorites.isFavorite(song.id)
                        : localFavorites.isFavorite(song.id));
                final cs = Theme.of(ctx2).colorScheme;
                return ListTile(
                  leading: Icon(
                    favorited ? Icons.favorite : Icons.favorite_border,
                    color: favorited ? cs.error : null,
                  ),
                  title: Text(favorited ? '取消收藏' : '收藏'),
                  onTap: () => song.isOnline
                      ? favorites.toggleFavorite(song)
                      : localFavorites.toggleFavorite(song.id),
                );
              },
            ),
            // 复制歌名与歌手：仅手机与桌面端展示（TV 端无剪贴板粘贴场景）
            if (!kTvBuild)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('复制歌名与歌手'),
                onTap: () async {
                  AppHaptics.click(HapticCategory.listItem);
                  final text = formatSongCopyText(song);
                  Navigator.pop(ctx);
                  await Clipboard.setData(ClipboardData(text: text));
                  showToast('已复制: $text');
                },
              ),
            // 本地音乐（有本地文件路径）：提供 Lyrico 外部编辑入口（公开功能）
            if (!song.isOnline && song.localPath != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑歌曲信息'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final r = await LyricoEditor.launchLyricoEdit(song.localPath!);
                  if (!r.installed) {
                    showToast('未安装 Lyrico，请先安装后再编辑', long: true);
                  } else if (!r.launched) {
                    showToast('无法打开 Lyrico 编辑', long: true);
                  }
                },
              ),
            // 本地音乐：匹配在线歌曲，补充封面兜底/歌词精确检索/评论区
            if (!song.isOnline && song.localPath != null)
              ListTile(
                leading: const Icon(Icons.manage_search),
                title: const Text('匹配在线信息'),
                onTap: () {
                  Navigator.pop(ctx);
                  showSongMatchSheet(context, song);
                },
              ),
            if (song.isOnline)
              ListTile(
                leading: const Icon(Icons.music_video_outlined),
                title: const Text('查看 MV'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(
                    context,
                    rootNavigator: true).push(
                    MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
                  );
                },
              ),
            // 内容黑名单（在线歌曲）：「不感兴趣 / 取消不感兴趣」。黑名单内容
            // 不会出现在猜你喜欢、每日推荐等推荐场景中（由酷狗服务端排除）。
            // 状态来自 BlacklistProvider，未拉满时按未加入处理并先全量拉取，
            // 重复标记交由「先查后加」拦截（与 EchoMusic 一致）。
            if (song.isOnline)
              Consumer<BlacklistProvider>(
                builder: (ctx2, blacklist, _) {
                  final present =
                      blacklist.statusFor('song', song.id.toLowerCase()) ==
                          BlacklistStatus.present;
                  return ListTile(
                    leading: Icon(
                      present
                          ? Icons.thumb_up_off_alt
                          : Icons.thumb_down_off_alt,
                    ),
                    title: Text(present ? '取消不感兴趣' : '不感兴趣'),
                    onTap: () {
                      Navigator.pop(ctx);
                      if (present) {
                        _unmarkSongBlacklist(context);
                      } else {
                        _markSongBlacklist(context);
                      }
                    },
                  );
                },
              ),
            // 可选扩展：私有构建注入的额外菜单条目（默认无）
            ...?SongListItem.extraMenuTilesBuilder?.call(ctx, song),
            if (song.isOnline)
              ListTile(
                // 与紧邻的「下一首播放」(playlist_add) 区分图标，避免同图标相邻
                leading: const Icon(Icons.add_to_queue_outlined),
                title: const Text('添加到歌单'),
                onTap: () {
                  Navigator.pop(ctx);
                  showAddToPlaylistDialog(context, song);
                },
              ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('下一首播放'),
              onTap: () {
                if (playNextStarted) return;
                playNextStarted = true;
                _playNextWithFlight(ctx, context, shrinkController);
              },
            ),
            // 在线歌曲恒提供；本地歌曲由「关闭本地音乐评论区」开关决定
            if (context.read<PlayerProvider>().showsCommentsFor(song))
              ListTile(
                leading: const Icon(Icons.comment_outlined),
                title: const Text('看评论'),
                onTap: () {
                  Navigator.pop(ctx);
                  showSongCommentsSheet(context, song);
                },
              ),
            // 成绩单依赖 album_audio_id（本地歌曲缺席该字段时隐藏入口）
            if (song.albumAudioId != null && song.albumAudioId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.leaderboard_outlined),
                title: const Text('看成绩单'),
                onTap: () {
                  Navigator.pop(ctx);
                  showSongRankingSheet(context, song);
                },
              ),
            // 伴奏匹配同样依赖 album_audio_id（与看成绩单同门控）
            if (song.albumAudioId != null && song.albumAudioId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.mic_none),
                title: const Text('获取伴奏'),
                onTap: () {
                  Navigator.pop(ctx);
                  showSongAccompanySheet(context, song);
                },
              ),
            // 曲谱同样依赖 album_audio_id（/sheet/song 查询键）
            if (song.albumAudioId != null && song.albumAudioId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.library_music_outlined),
                title: const Text('看曲谱'),
                onTap: () {
                  Navigator.pop(ctx);
                  showSongSheetSheet(context, song);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 标记「不感兴趣」（加入歌曲黑名单）。未拉满时先全量拉取防重复标记；
  /// 已存在则提示管理入口。登录态由调用处（菜单仅在在线歌曲出现）与此处共同把关。
  Future<void> _markSongBlacklist(BuildContext context) async {
    if (!context.read<KugouProvider>().isLoggedIn) {
      showToast('登录后才能标记不感兴趣');
      return;
    }
    final blacklist = context.read<BlacklistProvider>();
    final hash = song.id.toLowerCase();
    if (!blacklist.isFullyLoaded('song')) {
      await blacklist.ensureFullyLoaded('song');
    }
    if (blacklist.statusFor('song', hash) == BlacklistStatus.present) {
      showToast('已标记为不感兴趣，可在黑名单管理中移除');
      return;
    }
    final ok = await blacklist.addSong(
      hash: hash,
      name: '${song.artist} - ${song.displayName}',
      mixSongId: song.albumAudioId,
    );
    showToast(ok ? '已标记为不感兴趣' : '标记失败，请稍后重试');
  }

  /// 取消「不感兴趣」（从歌曲黑名单移除）。条目以 Provider 缓存为准
  /// （present 状态必然有缓存条目，移除接口需要它的显示名）。
  Future<void> _unmarkSongBlacklist(BuildContext context) async {
    final blacklist = context.read<BlacklistProvider>();
    final hash = song.id.toLowerCase();
    final matches =
        blacklist.entries('song').where((e) => e.key == hash).toList();
    if (matches.isEmpty) {
      showToast('未找到黑名单记录，请在黑名单管理中操作');
      return;
    }
    final ok = await blacklist.remove(matches.first);
    showToast(ok ? '已取消不感兴趣' : '操作失败，请稍后重试');
  }

  /// 「下一首播放」：队列操作先行，随后（条件满足时）播放封面跳水动画。
  ///
  /// 动画是纯装饰，任何闸门不满足都静默退回原来的「关菜单 + toast」：
  /// 系统减弱动效 / 播放页已打开（迷你条不可见）/ 无播放歌曲 /
  /// 没有迷你条封面矩形（MiniPlayer 从未画过）。收缩中菜单被意外关闭
  /// （barrier 点击）同样返回 null 走兜底。
  Future<void> _playNextWithFlight(
    BuildContext sheetCtx,
    BuildContext itemCtx,
    SongMenuHeaderShrinkController shrinkController,
  ) async {
    itemCtx.read<PlayerProvider>().insertAfterCurrent([song]);
    final miniRect = PlayerCoverMorphBus.instance.miniRect;
    final canFly = !MediaQuery.disableAnimationsOf(itemCtx) &&
        activePlayerRoute == null &&
        itemCtx.read<PlayerProvider>().currentSong != null &&
        miniRect != null &&
        miniRect.width > 0 &&
        miniRect.height > 0;
    if (!canFly) {
      Navigator.pop(sheetCtx);
      showToast('已加入下一首', long: true);
      return;
    }
    // await 前取齐全部入参，避免跨异步使用 context（lint & 稳定性）。
    final screenWidth = MediaQuery.sizeOf(itemCtx).width;
    // 菜单保持打开，封面收缩成正圆（220ms）；完成后关菜单、以圆形位置起飞。
    final circleRect = await shrinkController.shrinkToCircle();
    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
    showToast('已加入下一首', long: true);
    if (circleRect == null) return;
    PlayNextFlightController.instance.launch(
      PlayNextFlightSpec(
        artworkUri: song.artworkUri,
        fallbackFilePath: song.localPath,
        songId: song.id,
        start: circleRect,
        // canFly 已校验非空；miniRect 为局部 final 且不再赋值，Dart 3 的
        // flow analysis 会穿过 canFly 这个 bool 保留提升，无需 `!`
        // （计划里的 `miniRect!` 在本 SDK 上反而报 unnecessary_non_null_assertion）。
        target: miniRect,
        screenWidth: screenWidth,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 列表行只订阅实际影响自身外观的状态，避免播放器或收藏集合的
    // 无关通知让所有可见歌曲行一起重建。
    final playbackRowState = context.select<PlayerProvider, (bool, bool)>((
      provider,
    ) {
      final isCurrent = provider.currentSong?.id == song.id;
      // 非当前行不展示播放动画，不需要跟随全局播放/暂停状态重建。
      return (isCurrent, isCurrent && provider.isPlaying);
    });
    final isCurrentSong = playbackRowState.$1;
    final isPlaying = playbackRowState.$2;
    final isFavorited = forceFavorited
        ? true
        : (song.isOnline
              ? context.select<FavoritesProvider, bool>(
                  (provider) => provider.isFavorite(song.id),
                )
              : context.select<LocalFavoritesProvider, bool>(
                  (provider) => provider.isFavorite(song.id),
                ));
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    const imgSize = 52.0; // 正方形封面，不被 ListTile 压缩

    // 行级震动只挂在真实存在的手势回调上：原回调为空时保持 InkWell 不可点，
    // 不给「本就没有点击行为」的行凭空加一次震动。
    final tapHandler = isSelectMode ? onSelectToggle : onTap;
    final longPressHandler = onLongPress;

    final row = InkWell(
      onTap: tapHandler == null
          ? null
          : () {
              AppHaptics.click(HapticCategory.listItem);
              tapHandler();
            },
      onLongPress: longPressHandler == null
          ? null
          : () {
              AppHaptics.longPress(HapticCategory.listItem);
              longPressHandler();
            },
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
                  subtitleOverride ??
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
                        isPlaying: isPlaying,
                      ),
                    ),
                  ..._buildTrailingActions(
                    context,
                    colorScheme,
                    textTheme,
                    isFavorited,
                    context.read<FavoritesProvider>(),
                    context.read<LocalFavoritesProvider>(),
                  ),
                ],
              ),
          ],
        ),
      ),
    );

    // tv: TV 构建下整行单停点（DpadFocusable 默认 excludeChildFocus: true，
    // 内层 InkWell 不再产生第二个停点，无需 canRequestFocus=false 手法）；
    // OK=播放/切换选中，OK 长按=上下文菜单（页面可经 onContextMenuOverride 重定向）。
    if (kTvBuild) {
      // tv: 遥控菜单键=直接开本行「更多菜单」（与行尾三个点同源
      // [_showMoreMenu]），不走 _tvContextAction 优先级链——那是 OK 长按的
      // 语义（歌单/云盘页重定向进多选）。没有更多菜单的行（每日推荐/
      // 多选模式）onMenu 传 null，TvMenuKeyShortcuts 等价于裸 child。
      return TvMenuKeyShortcuts(
        onMenu: _hasMoreMenu ? () => _showMoreMenu(context) : null,
        child: DpadFocusable(
          onSelect: tapHandler == null
              ? null
              : () {
                  AppHaptics.click(HapticCategory.listItem);
                  tapHandler();
                },
          onLongSelect: _tvContextAction(context),
          child: row,
        ),
      );
    }
    return row;
  }

  /// 本行是否有「更多菜单」（行尾三个点）。多选模式下尾部操作整体隐藏
  /// （行体 `if (!isSelectMode)` 分支），每日推荐档（favoriteOnly）只有
  /// 收藏按钮；这两种行菜单键不接线（onMenu 传 null）。
  bool get _hasMoreMenu =>
      !isSelectMode && trailingActions != SongTrailingActions.favoriteOnly;

  /// tv: OK 长按（遥控菜单键语义）的动作，优先级与 TV 参考实现一致：
  /// 页面覆盖（如歌单/云盘页重定向进多选）→ 多选模式切换选中 →
  /// 整行长按 → 默认弹出更多菜单（行尾图标在 TV 下被 excludeChildFocus
  /// 排除，更多菜单是收藏/添加歌单等操作的主入口）。
  VoidCallback _tvContextAction(BuildContext context) {
    final override = onContextMenuOverride;
    if (override != null) return override;
    if (isSelectMode && onSelectToggle != null) return onSelectToggle!;
    final longPress = onLongPress;
    if (longPress != null) {
      return () {
        AppHaptics.longPress(HapticCategory.listItem);
        longPress();
      };
    }
    return () => _showMoreMenu(context);
  }

  /// 按 [trailingActions] 策略构建右侧操作。不同页面只改变尾部操作，
  /// 不改变歌曲行整体结构，保持跨页面一致性。
  List<Widget> _buildTrailingActions(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool isFavorited,
    FavoritesProvider favoritesProvider,
    LocalFavoritesProvider localFavoritesProvider,
  ) {
    switch (trailingActions) {
      case SongTrailingActions.favoriteOnly:
        return [
          _favoriteButton(
            colorScheme,
            isFavorited,
            favoritesProvider,
            localFavoritesProvider,
          ),
        ];
      case SongTrailingActions.favoriteAndMore:
        return [
          _favoriteButton(
            colorScheme,
            isFavorited,
            favoritesProvider,
            localFavoritesProvider,
          ),
          _iconAction(
            colorScheme,
            Icons.more_vert,
            () => _showMoreMenu(context),
            label: '更多',
          ),
        ];
      case SongTrailingActions.detailAndMv:
        return [
          // MV 在前，详情（三个点）在最右：与「更多菜单」全局一致用 more_vert，
          // 且与 MV 按钮顺序对调（见改版计划补充一）。
          // 云盘歌曲无 MV；仅在线非云盘歌曲显示 MV 入口。
          if (song.isOnline && !song.isCloud)
            _iconAction(
              colorScheme,
              Icons.music_video_outlined,
              () => Navigator.of(
                context,
                rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
              ),
              label: '查看 MV',
            ),
          _iconAction(
            colorScheme,
            Icons.more_vert,
            () => _showMoreMenu(context),
            label: '更多',
          ),
        ];
      case SongTrailingActions.full:
        return [
          if (showDuration)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(song.displayDuration, style: textTheme.labelSmall),
            ),
          _favoriteButton(
            colorScheme,
            isFavorited,
            favoritesProvider,
            localFavoritesProvider,
          ),
          _iconAction(
            colorScheme,
            Icons.more_vert,
            () => _showMoreMenu(context),
            label: '更多',
          ),
        ];
    }
  }

  Widget _favoriteButton(
    ColorScheme colorScheme,
    bool isFavorited,
    FavoritesProvider favoritesProvider,
    LocalFavoritesProvider localFavoritesProvider,
  ) {
    return Semantics(
      button: true,
      label: isFavorited ? '取消收藏' : '收藏',
      child: GestureDetector(
        onTap: () => song.isOnline
            ? favoritesProvider.toggleFavorite(song)
            : localFavoritesProvider.toggleFavorite(song.id),
        behavior: HitTestBehavior.opaque,
        // 44×44 触控盒（行高由 52 封面决定，不放宽视觉图标，行不位移）
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(
              isFavorited ? Icons.favorite : Icons.favorite_border,
              size: 18,
              color: isFavorited
                  ? colorScheme.error
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconAction(
    ColorScheme colorScheme,
    IconData icon,
    VoidCallback onTap, {
    required String label,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
          ),
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
