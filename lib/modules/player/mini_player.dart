import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/theme/motion_constants.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';

/// 全局开关：MiniPlayer 是否支持水平滑动切歌（设置页可切换，默认开启）。
/// 用全局 ValueNotifier 而非 State 局部状态，保证各页面 MiniPlayer 实例
/// 在设置变更后实时响应。
final ValueNotifier<bool> miniPlayerSwipeSwitchEnabled =
    ValueNotifier<bool>(true);

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
    // 从本地持久化读取「滑动切歌」开关，覆盖默认值（默认开启）
    _loadSwipeSwitchSetting();
  }

  /// 读取本地「MiniPlayer 滑动切歌」设置并同步到全局开关
  Future<void> _loadSwipeSwitchSetting() async {
    final enabled = await SettingsRepository().getMiniPlayerSwipeSwitchEnabled();
    miniPlayerSwipeSwitchEnabled.value = enabled;
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    // 上滑展开已识别时屏蔽水平切歌，避免斜向滑动同时触发两种手势
    if (_dragActivated) return;
    // 取消正在进行的回弹动画，接管为手动拖动
    _snapController.stop();
    _dragOffset = 0.0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dragActivated) return;
    setState(() {
      _dragOffset += details.delta.dx;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_dragActivated) return;
    final velocity = details.primaryVelocity ?? 0;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final distanceThreshold = screenWidth * _distanceRatio;

    final playerProvider = context.read<PlayerProvider>();

    if (_dragOffset < -distanceThreshold || velocity < -_velocityThreshold) {
      // 向左滑 → 下一首
      _switchDirection = 1;
      _dragOffset = 0.0;
      AppHaptics.click();
      playerProvider.next();
      setState(() {});
    } else if (_dragOffset > distanceThreshold ||
        velocity > _velocityThreshold) {
      // 向右滑 → 上一首
      _switchDirection = -1;
      _dragOffset = 0.0;
      AppHaptics.click();
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

  // ── 上滑展开 FullPlayer ──
  // 关键约束：手势期间绝不 push 路由（实测 push 会立即切断整个事件流，
  // 跟手失效）。跟手显示由 Navigator 之上的覆盖层（playerExpansion 驱动）
  // 承担；松手后手势已结束，再 push 路由并让路由从当前进度继续展开。

  /// 当前跟踪的 pointer（nil = 无拖拽）
  int? _activePointer;
  // 起点位置（用于判定垂直上滑与累计距离）
  double _downY = 0.0;
  double _downX = 0.0;
  // 上滑累计距离 / 是否已确认展开手势 / 完整展开距离（MiniPlayer 顶端 Y）
  double _dragDistance = 0.0;
  bool _dragActivated = false;
  double _miniTopY = 0.0;
  // 速度/加速度估计：按事件时间戳差分（向上为正）
  double? _lastVelocity;
  double? _lastY;
  Duration? _lastSampleTime;
  double _lastAcceleration = 0.0;

  void _onRawDown(PointerDownEvent e) {
    if (_activePointer != null) return; // 已在跟踪其他手指
    _activePointer = e.pointer;
    _downY = e.position.dy;
    _downX = e.position.dx;
    _dragDistance = 0.0;
    _dragActivated = false; // 新手势开始，重置上滑守卫
    _lastVelocity = null;
    _lastY = e.position.dy;
    _lastSampleTime = e.timeStamp;
    _lastAcceleration = 0.0;
    // 预测量 MiniPlayer 顶端全局 Y（= FullPlayer 展开起点）
    final box = context.findRenderObject() as RenderBox?;
    _miniTopY = box?.localToGlobal(Offset.zero).dy ?? 0.0;
  }

  void _onRawMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    final deltaY = _downY - e.position.dy; // 向上为正
    final deltaX = (e.position.dx - _downX).abs();
    if (!_dragActivated) {
      // 确认是垂直上滑：位移超过 touch slop 且垂直占主导（否则交给点击/水平切歌）
      if (deltaY < kTouchSlop || deltaY <= deltaX) return;
      _dragActivated = true;
      playerDragOriginTop = _miniTopY;
      playerDragActive.value = true; // 显示跟手覆盖层
    }
    _dragDistance = deltaY.clamp(0.0, double.infinity);
    // 速度/加速度估计：按事件时间戳差分
    final ts = e.timeStamp;
    if (_lastSampleTime != null && _lastY != null) {
      final dt = (ts - _lastSampleTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        final v = (_lastY! - e.position.dy) / dt; // px/s，向上为正
        if (_lastVelocity != null) {
          _lastAcceleration = (v - _lastVelocity!) / dt;
        }
        _lastVelocity = v;
      }
    }
    _lastY = e.position.dy;
    _lastSampleTime = ts;
    // 驱动跟手覆盖层：位置进度 = 上滑距离 / 完整展开距离
    if (_miniTopY > 0.0) {
      playerExpansion.value = (_dragDistance / _miniTopY).clamp(0.0, 1.0);
    }
  }

  void _onRawUp(PointerUpEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    // 注意：不在此重置 _dragActivated——up 之后竞技场 sweep 仍会触发
    // onHorizontalDragEnd，必须保持上滑守卫，直到下一次手势开始（_onRawDown）
    if (!_dragActivated) return;
    final expand = shouldExpandPlayer(
      dragDistance: _dragDistance,
      screenHeight: MediaQuery.sizeOf(context).height,
      velocity: _lastVelocity ?? 0.0,
      acceleration: _lastAcceleration,
    );
    if (expand) {
      _expandPlayerFromDrag();
    } else {
      // 未达阈值：收起覆盖层，回到 MiniPlayer
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
    }
  }

  void _onRawCancel(PointerCancelEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    // 手势被系统打断：收起覆盖层（同样保持守卫到下一次 down）
    if (_dragActivated) {
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
    }
  }

  /// 松手判定展开：push 拖拽路由并让路由从当前进度继续展开。
  /// 此时手势已结束（up 已处理），push 不再影响事件流。
  ///
  /// 交接要点（避免松手闪烁）：
  /// - 覆盖层在 Navigator 之上，路由渲染需要一帧；先 push 路由并停在当前
  ///   进度（不立即动画），等路由渲染完成后再隐藏覆盖层并启动展开动画，
  ///   保证「覆盖层 → 路由」无缝衔接
  /// - 不重置 playerExpansion（覆盖层销毁后由路由 build 同步接管进度），
  ///   避免 MiniPlayer 瞬间恢复全亮造成闪烁
  void _expandPlayerFromDrag() {
    final progress = playerExpansion.value;
    if (_miniTopY <= 0.0 || progress <= 0.0) {
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
      return;
    }
    final route = fullPlayerRoute(
      context,
      dragOriginTop: _miniTopY,
      screenHeight: MediaQuery.sizeOf(context).height,
    );
    Navigator.of(context).push(route);
    route.controller.stop();
    route.controller.value = progress; // 路由从当前手指位置开始显示
    // 等待路由渲染（2 帧）后：隐藏覆盖层并启动展开动画
    var frames = 0;
    void tick() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        frames++;
        if (frames >= 2) {
          playerDragActive.value = false;
          route.settleToFull();
        } else {
          tick();
        }
      });
    }

    tick();
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final currentSong = playerProvider.currentSong;

    if (currentSong == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final duration = playerProvider.duration ?? Duration.zero;
    // 公开版偏好：启用自定义背景时，MiniPlayer 用半透明背景透出背景图
    final useBackgroundImage = context.watch<ThemeProvider>().useBackgroundImage;

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
      child: ValueListenableBuilder<bool>(
        // 滑动切歌开关关闭时，不注册水平拖动回调，仅保留点击展开
        valueListenable: miniPlayerSwipeSwitchEnabled,
        builder: (context, swipeEnabled, _) => Listener(
          // 上滑展开：手势期间不 push（push 会切断事件流），
          // 由 Navigator 之上的覆盖层跟手显示，松手后再 push 路由
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onRawDown,
          onPointerMove: _onRawMove,
          onPointerUp: _onRawUp,
          onPointerCancel: _onRawCancel,
          child: GestureDetector(
            // 点击展开 FullPlayer（栈顶已有播放器路由时不重复 push）
            onTap: () {
              // 上滑展开识别后（含 up 后 sweep 阶段）不响应点击
              if (_dragActivated) return;
              if (activePlayerRoute?.isCurrent ?? false) return;
              Navigator.of(context).push(fullPlayerRoute(context));
            },
            // 水平滑动切歌（受设置开关控制）
            onHorizontalDragStart:
                swipeEnabled ? _onHorizontalDragStart : null,
            onHorizontalDragUpdate:
                swipeEnabled ? _onHorizontalDragUpdate : null,
            onHorizontalDragEnd: swipeEnabled ? _onHorizontalDragEnd : null,
            behavior: HitTestBehavior.opaque,
            // P0: 进度只订阅 positionNotifier（高频 200ms），
            // 不再因 positionStream 触发整个 MiniPlayer 重建（封面/标题不变）
            child: ValueListenableBuilder<Duration>(
              valueListenable: playerProvider.positionNotifier,
              builder: (context, position, _) {
                final progress = duration.inMilliseconds > 0
                    ? position.inMilliseconds / duration.inMilliseconds
                    : 0.0;
                return _buildContent(context, playerProvider, currentSong,
                    colorScheme, progress, useBackgroundImage);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    double progress,
    bool useBackgroundImage,
  ) {
    return Container(
      // Container 在外提供整体背景色：
      // 默认使用 surfaceContainerHigh 比 NavigationBar 的 surface 更深，
      // 形成明确的层级关系（mini player 浮于内容之上，NavigationBar 之下）
      // 启用自定义背景时改用半透明 surface，透出底层背景图。
      // 颜色会自然填充 SafeArea 在底部留出的系统手势条区域
      decoration: BoxDecoration(
        color: useBackgroundImage
            ? colorScheme.surface.withValues(alpha: 0.2)
            : colorScheme.surfaceContainerHigh,
      ),
      child: SafeArea(
        // 仅吸收底部系统手势条/Home Indicator 高度
        top: false,
        bottom: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            M3ELinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: colorScheme.surfaceContainerHighest,
              color: colorScheme.primary,
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
                                      songId: currentSong.id,
                                      size: 44,
                                      borderRadius: 6,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
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
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      playerProvider.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () {
                      AppHaptics.click();
                      if (playerProvider.isPlaying) {
                        playerProvider.pause();
                      } else {
                        playerProvider.resume();
                      }
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
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
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.skip_next),
                    onPressed: () {
                      AppHaptics.click();
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
