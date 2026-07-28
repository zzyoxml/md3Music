import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/theme/motion_constants.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';

/// 底部常驻迷你播放条。
///
/// 点击调用 [fullPlayerRoute] push 路由，由路由自带 300ms 入场动画。
///
/// 自身 opacity = `1 - playerExpansion`，由全局 [playerExpansion] Notifier 驱动，
/// FullPlayer 淡入时 mini bar 同步淡出，避免视觉打架。
///
/// 支持水平滑动切歌：封面+歌曲信息跟随手指实时平移，松手达阈值触发切歌并
/// AnimatedSwitcher 滑入滑出过渡，未达阈值回弹归位。右侧按钮不参与滑动。
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  // 拖动期间内容水平偏移（px），实时跟随手指
  double _dragOffset = 0.0;
  // 切歌方向：1=下一首(向左滑)，-1=上一首(向右滑)；驱动 AnimatedSwitcher 进出场方向
  int _switchDirection = 1;
  // 回弹归位动画控制器
  late final AnimationController _snapController;
  Animation<double>? _snapAnim;

  // 拖动触发阈值
  static const double _velocityThreshold = 400.0; // px/s
  static const double _distanceRatio = 0.25; // 屏宽比例

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    // 取消正在进行的回弹动画，接管为手动拖动
    _snapController.stop();
    _dragOffset = 0.0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset += details.delta.dx;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final distanceThreshold = screenWidth * _distanceRatio;

    final playerProvider = context.read<PlayerProvider>();

    if (_dragOffset < -distanceThreshold || velocity < -_velocityThreshold) {
      // 向左滑 → 下一首
      _switchDirection = 1;
      _dragOffset = 0.0;
      playerProvider.next();
      setState(() {});
    } else if (_dragOffset > distanceThreshold ||
        velocity > _velocityThreshold) {
      // 向右滑 → 上一首
      _switchDirection = -1;
      _dragOffset = 0.0;
      playerProvider.previous();
      setState(() {});
    } else {
      // 未达阈值，回弹归位
      _animateSnapBack();
    }
  }

  /// 把 [_dragOffset] 从当前值动画回 0，实现松手回弹。
  void _animateSnapBack() {
    final start = _dragOffset;
    _snapAnim = Tween<double>(begin: start, end: 0.0).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOut),
    )..addListener(() {
        if (mounted) {
          setState(() {
            _dragOffset = _snapAnim!.value;
          });
        }
      });
    _snapController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final currentSong = playerProvider.currentSong;

    if (currentSong == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final duration = playerProvider.duration ?? Duration.zero;
    final position = playerProvider.position;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, expansion, child) {
        // opacity 与展开进度线性绑定：expansion=0 时完全可见，expansion=1 时完全隐藏
        // IgnorePointer 防止淡出过程中拦截下层手势
        final opacity = (1.0 - expansion).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: expansion > 0.5,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: GestureDetector(
        // 点击展开 FullPlayer
        onTap: () => Navigator.of(context).push(fullPlayerRoute(context)),
        onHorizontalDragStart: _onHorizontalDragStart,
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        behavior: HitTestBehavior.opaque,
        child: _buildContent(
            context, playerProvider, currentSong, colorScheme, progress),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    double progress,
  ) {
    return Container(
      // Container 在外提供整体背景色：
      // 使用 surfaceContainerHigh 比 NavigationBar 的 surface 更深，
      // 形成明确的层级关系（mini player 浮于内容之上，NavigationBar 之下）
      // 颜色会自然填充 SafeArea 在底部留出的系统手势条区域
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
      ),
      child: SafeArea(
        // 仅吸收底部系统手势条/Home Indicator 高度
        top: false,
        bottom: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: colorScheme.surfaceContainerHighest,
              color: colorScheme.primary,
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  // —— 滑动区：封面 + 歌曲信息，跟随手指平移 + 切歌过渡 ——
                  Expanded(
                    child: ClipRect(
                      // 裁剪溢出，防止滑动时侵入右侧按钮区
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        switchInCurve: M3ExpressiveMotion.expressiveEasing,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) {
                          // isEntering 判定：新 child 的 key == 当前歌曲 id
                          final isEntering =
                              child.key == ValueKey(currentSong.id);
                          // 进入：沿切歌方向滑入（向左滑切下一首 → 新内容从右边进入）
                          // 离场：朝切歌方向的反方向滑出（旧内容向左边退出）
                          final dir = isEntering
                              ? _switchDirection
                              : -_switchDirection;
                          return SlideTransition(
                            position: Tween<Offset>(
                              begin: Offset(dir * 0.5, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(currentSong.id),
                          child: Transform.translate(
                            // 拖动期间跟随手指；切歌触发后立即归 0 由 AnimatedSwitcher 接管
                            offset: Offset(_dragOffset, 0),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: SmartArtworkImage(
                                      artworkUri: currentSong.artworkUri,
                                      fallbackFilePath: currentSong.localPath,
                                      size: 44,
                                      borderRadius: 6,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        currentSong.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium,
                                      ),
                                      Text(
                                        currentSong.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                                color: colorScheme
                                                    .onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // —— 固定区：右侧按钮不参与滑动 ——
                  IconButton(
                    icon: Icon(
                      playerProvider.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () {
                      if (playerProvider.isPlaying) {
                        playerProvider.pause();
                      } else {
                        playerProvider.resume();
                      }
                    },
                  ),
                  IconButton(
                    tooltip: DesktopLyricService.instance.enabled
                        ? '关闭桌面歌词'
                        : '开启桌面歌词',
                    icon: Icon(
                      DesktopLyricService.instance.enabled
                          ? Icons.lyrics
                          : Icons.lyrics_outlined,
                      color: DesktopLyricService.instance.enabled
                          ? colorScheme.primary
                          : null,
                    ),
                    onPressed: () async {
                      await DesktopLyricService.instance.toggle();
                      if (context.mounted) {
                        (context as Element).markNeedsBuild();
                        // 同步通知栏"桌面歌词"按钮状态
                        final player = context.read<PlayerProvider>();
                        final song = player.currentSong;
                        // 收藏状态需实时查询，避免暂停时显示为未收藏
                        bool isFavorited = false;
                        if (song != null) {
                          try {
                            isFavorited = context
                                .read<FavoritesProvider>()
                                .isFavorite(song.id);
                          } catch (_) {}
                        }
                        await MediaNotificationService.updateNotification(
                          // 用 displayName 剥离 .mp3 等后缀，避免标题显示文件名
                          title: song?.displayName ?? '',
                          artist: song?.artist ?? '',
                          artUrl: song?.artworkUri,
                          isPlaying: player.isPlaying,
                          position: player.position,
                          duration: player.duration ?? Duration.zero,
                          desktopLyricEnabled:
                              DesktopLyricService.instance.enabled,
                          isFavorited: isFavorited,
                        );
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () {
                      playerProvider.next();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
