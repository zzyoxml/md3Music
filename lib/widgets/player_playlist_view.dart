import 'package:flutter/gestures.dart'
    show
        DelayedMultiDragGestureRecognizer,
        GestureDisposition,
        MultiDragGestureRecognizer,
        OneSequenceGestureRecognizer,
        PointerCancelEvent,
        PointerDownEvent,
        PointerMoveEvent,
        PointerUpEvent,
        kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/models/song.dart';
import '../core/utils/app_haptics.dart';
import '../providers/player_provider.dart';
import 'player_artwork_image.dart';
import 'playing_spectrum_indicator.dart';

/// 自定义长按延迟 700ms 的 Reorderable 监听器（与 PlayerPlaylistDialog 内实现一致）。
///
/// Flutter 内置的 [ReorderableDelayedDragStartListener] 不支持自定义 delay
/// 参数（默认用 `kLongPressTimeout` = 500ms），通过继承
/// [ReorderableDragStartListener] 并重写 `createRecognizer` 方法实现 700ms，
/// 比默认稍长以减少误触，又不会让用户觉得等待太久。
class _LongPressReorderableDragStartListener
    extends ReorderableDragStartListener {
  const _LongPressReorderableDragStartListener({
    required super.index,
    required super.child,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(
      delay: const Duration(milliseconds: 700),
    );
  }
}

/// 仅认领"向右滑动"手势的识别器（用于右滑删除）。
///
/// 与 Dismissible 不同：Dismissible 的水平拖动识别器无论左滑/右滑都会
/// 赢得手势竞技场，导致外层 TabBarView 收不到水平滑动、无法切换 tab。
/// 本识别器在向右滑动（且横向占优）时认领手势；向左滑动或纵向滚动时
/// 主动拒绝（reject），把手势让给 TabBarView（左滑切 tab）与列表滚动。
class _RightSwipeOnlyRecognizer extends OneSequenceGestureRecognizer {
  _RightSwipeOnlyRecognizer({
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  });

  /// 认领手势后每次移动回调（参数为横向位移 dx）
  final void Function(double dx) onUpdate;

  /// 松手回调（参数为最终横向位移 dx）
  final void Function(double dx) onEnd;

  /// 手势取消回调
  final VoidCallback onCancel;

  int? _pointer;
  Offset _startPosition = Offset.zero;
  bool _accepted = false;

  static const double _touchSlop = kTouchSlop;

  @override
  void addPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer);
    _pointer = event.pointer;
    _startPosition = event.position;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      final dx = event.position.dx - _startPosition.dx;
      final dy = event.position.dy - _startPosition.dy;
      if (!_accepted) {
        if (dx > _touchSlop && dx.abs() > dy.abs()) {
          // 向右滑动且横向占优：认领手势，开始跟手
          _accepted = true;
          resolve(GestureDisposition.accepted);
          onUpdate(dx);
        } else if ((dx < -_touchSlop && dx.abs() > dy.abs()) ||
            (dy.abs() > dx.abs() && dy.abs() > _touchSlop)) {
          // 向左滑动（让位 TabBarView）或纵向滚动（让位列表）：主动拒绝
          _reject();
        }
        // 方向未明（位移小于 slop）：继续跟踪等待后续移动
      } else {
        onUpdate(dx);
      }
    } else if (event is PointerUpEvent) {
      if (_accepted) {
        onEnd(event.position.dx - _startPosition.dx);
      }
      stopTrackingPointer(event.pointer);
      _pointer = null;
      _accepted = false;
    } else if (event is PointerCancelEvent) {
      if (_accepted) {
        onCancel();
      }
      stopTrackingPointer(event.pointer);
      _pointer = null;
      _accepted = false;
    }
  }

  void _reject() {
    final pointer = _pointer;
    if (pointer != null) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(pointer);
    }
    _pointer = null;
    _accepted = false;
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {}

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'right-swipe-only';
}

/// AM 风格播放器的播放列表面板（内嵌于播放器 TabBarView）。
///
/// 功能与 [PlayerPlaylistDialog] 一致：
/// 1. 长按 700ms 拖拽重排（ReorderableListView）
/// 2. 左滑渐变红色 + 40% 阈值震动反馈，松手后删除
/// 3. 打开时自动滚动定位当前播放歌曲
///
/// 与弹窗版差异：
/// - 文字颜色默认参照评论区 AM 风格：正文 Colors.white / 次要 Color(0xB3FFFFFF)
/// - 每个列表项显示专辑封面（[PlayerArtworkImage]）
/// - 无"关闭"按钮（Tab 左右滑动即可切换）
class PlayerPlaylistView extends StatefulWidget {
  /// 是否使用 displayName（剥离 .mp3 等后缀）显示标题
  final bool useDisplayName;

  /// 配色模式：true 用 AM 白色文字（为深色背景设计）；
  /// false 用主题莫奈色（为 MD3 风格 tab/浅色背景设计）。
  final bool useAmColors;

  const PlayerPlaylistView({
    super.key,
    this.useDisplayName = true,
    this.useAmColors = true,
  });

  @override
  State<PlayerPlaylistView> createState() => _PlayerPlaylistViewState();
}

class _PlayerPlaylistViewState extends State<PlayerPlaylistView> {
  /// 记录每首歌的震动是否已触发，避免滑动过程中连续触发 heavyImpact。
  /// 当滑动距离回到阈值以下时重置，允许下次越过阈值再次触发。
  final Map<String, bool> _hapticTriggered = {};

  /// 记录每首歌当前右滑的跟手位移；松手回弹时归零。
  final Map<String, double> _dragExtent = {};

  /// 记录每首歌是否处于回弹动画中（跟手时 duration=0，回弹时带动画）。
  final Map<String, bool> _reverting = {};

  static const double _swipeThreshold = 0.4;
  static const Duration _fadeDuration = Duration(milliseconds: 100);

  /// 播放列表滚动控制器
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 进入播放列表面板后自动滚动到当前播放歌曲
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentSong();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动到当前播放的歌曲并居中显示
  void _scrollToCurrentSong() {
    final playerProvider = context.read<PlayerProvider>();
    final currentIndex = playerProvider.currentIndex;
    if (currentIndex < 0 || !_scrollController.hasClients) return;

    // 每个列表项高度约 72px（ListTile 默认高度）
    const itemHeight = 72.0;
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset =
        (currentIndex * itemHeight) - (viewportHeight / 2) + (itemHeight / 2);
    final maxScroll = _scrollController.position.maxScrollExtent;
    final offset = targetOffset.clamp(0.0, maxScroll);

    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.read<PlayerProvider>();
    // Selector 隔离：仅在播放列表内容（歌曲 id 指纹）、当前索引或播放状态变化时
    // 重建面板，避免播放进度每 200ms 的 provider 通知触发整面板重建。
    // 不能直接用 playlist 引用作键：removeFromPlaylist / reorderPlaylist 均为
    // 原地修改（removeAt/insert），List 引用不变，Selector 检测不到变化。
    // isPlaying 纳入 selector：暂停/恢复时让正在播放的频谱波形同步启停。
    return Selector<
      PlayerProvider,
      ({int fingerprint, int currentIndex, bool isPlaying})
    >(
      selector: (_, p) => (
        fingerprint: Object.hashAll(p.playlist.map((s) => s.id)),
        currentIndex: p.currentIndex,
        isPlaying: p.isPlaying,
      ),
      builder: (context, data, _) {
        final playlist = playerProvider.playlist;
        // 配色：AM 白色（深色背景） vs MD 莫奈色（主题色）
        final colorScheme = Theme.of(context).colorScheme;
        final useAm = widget.useAmColors;
        final titleColor = useAm ? Colors.white : colorScheme.onSurface;
        final secondaryColor =
            useAm ? const Color(0xB3FFFFFF) : colorScheme.onSurfaceVariant;
        final clearEnabledColor =
            useAm ? const Color(0xB3FFFFFF) : colorScheme.primary;
        final clearDisabledColor = useAm
            ? const Color(0x40FFFFFF)
            : colorScheme.onSurface.withValues(alpha: 0.38);
        return Column(
          children: [
            // 顶部标题行：标题 + 清空
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '播放列表',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: titleColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: playlist.isEmpty
                        ? null
                        : () => _confirmClearPlaylist(playerProvider),
                    child: Text(
                      '清空',
                      style: TextStyle(
                        color: playlist.isEmpty
                            ? clearDisabledColor
                            : clearEnabledColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 歌曲列表
            Expanded(
              child: playlist.isEmpty
                  ? Center(
                      child: Text(
                        '播放列表为空',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: secondaryColor,
                        ),
                      ),
                    )
                  // 与评论区一致的上下边界 alpha 渐变（ShaderMask + 线性渐变淡入淡出）
                  : ShaderMask(
                      shaderCallback: (Rect bounds) {
                        const double fadeHeight = 24.0;
                        final double fadeRatio =
                            (fadeHeight / bounds.height).clamp(0.0, 0.5);
                        return LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: const [
                            Colors.transparent,
                            Colors.black,
                            Colors.black,
                            Colors.transparent,
                          ],
                          stops: [0.0, fadeRatio, 1.0 - fadeRatio, 1.0],
                        ).createShader(bounds);
                      },
                      blendMode: BlendMode.dstIn,
                      child: ReorderableListView(
                        scrollController: _scrollController,
                        buildDefaultDragHandles: false,
                        // 拖拽中的项只加透明度，不显示默认的底色/阴影
                        proxyDecorator: (child, index, animation) {
                          return AnimatedBuilder(
                            animation: animation,
                            builder: (context, _) =>
                                Opacity(opacity: 0.7, child: child),
                          );
                        },
                        onReorder: (oldIndex, newIndex) {
                          playerProvider.reorderPlaylist(oldIndex, newIndex);
                        },
                        children: [
                          for (int index = 0; index < playlist.length; index++)
                            _buildSwipeItem(
                              key: ValueKey(playlist[index].id),
                              index: index,
                              song: playlist[index],
                              isCurrent: index == data.currentIndex,
                              isPlaying: data.isPlaying,
                              playerProvider: playerProvider,
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 清空播放列表前弹二次确认（配色跟随主题，确认按钮用错误色）。
  Future<void> _confirmClearPlaylist(PlayerProvider playerProvider) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
        title: Text(
          '清空播放列表',
          style: TextStyle(color: colorScheme.onSurface),
        ),
        content: Text(
          '确定要清空播放列表吗？此操作不可撤销。',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              '取消',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              '清空',
              style: TextStyle(color: colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      playerProvider.clearPlaylist();
    }
  }

  /// 删除阈值：滑动约 40% 屏宽触发（与原 Dismissible 的 progress 阈值一致）。
  double get _deleteThreshold =>
      MediaQuery.sizeOf(context).width * _swipeThreshold;

  /// 构建一个可右滑删除 + 长按拖拽的列表项。
  ///
  /// 嵌套层级：RawGestureDetector（右滑删除手势）→ Stack（红底 + 列表项）
  /// → _LongPressReorderableDragStartListener（长按 700ms 触发拖拽）→ ListTile
  ///
  /// 删除手势用自定义识别器 [_RightSwipeOnlyRecognizer]：右滑认领手势并跟手，
  /// 左滑/纵向滑动主动让位（TabBarView 切 tab / 列表滚动），
  /// 避免 Dismissible 无条件拦截水平手势导致无法左右切换 tab。
  Widget _buildSwipeItem({
    required Key key,
    required int index,
    required Song song,
    required bool isCurrent,
    required bool isPlaying,
    required PlayerProvider playerProvider,
  }) {
    final dx = _dragExtent[song.id] ?? 0.0;
    final thresholdReached = dx >= _deleteThreshold;
    final reverting = _reverting[song.id] ?? false;
    // 配色：AM 白色（深色背景） vs MD 莫奈色（主题色）
    final colorScheme = Theme.of(context).colorScheme;
    final useAm = widget.useAmColors;
    final titleColor = useAm ? Colors.white : colorScheme.onSurface;
    final secondaryColor =
        useAm ? const Color(0xB3FFFFFF) : colorScheme.onSurfaceVariant;
    final artworkBg =
        useAm ? Colors.white12 : colorScheme.surfaceContainerHighest;
    final artworkIcon =
        useAm ? Colors.white54 : colorScheme.onSurfaceVariant;
    final spectrumColor = useAm ? Colors.white : colorScheme.primary;
    final deleteBg = useAm ? Colors.redAccent : colorScheme.errorContainer;
    final deleteIconOn = useAm ? Colors.white : colorScheme.onErrorContainer;
    final deleteIconOff = useAm ? Colors.white54 : colorScheme.error;

    // 列表项本体：长按 700ms 拖拽 + 点击切歌
    final item = Material(
      type: MaterialType.transparency,
      child: _LongPressReorderableDragStartListener(
        index: index,
        child: ListTile(
          // 专辑封面
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 44,
              height: 44,
              child: PlayerArtworkImage(
                artworkUri: song.artworkUri,
                fallbackFilePath: song.localPath,
                fit: BoxFit.cover,
                backgroundColor: artworkBg,
                iconColor: artworkIcon,
              ),
            ),
          ),
          title: Text(
            widget.useDisplayName ? song.displayName : song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              // 正文纯色，当前歌曲加粗
              color: titleColor,
              fontWeight: isCurrent ? FontWeight.bold : null,
            ),
          ),
          subtitle: Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: secondaryColor,
            ),
          ),
          // 正在播放的歌曲右侧：歌单同款三柱起伏波形（暂停时 ticker 停止保留最后一帧）
          trailing: isCurrent
              ? PlayingSpectrumIndicator(
                  color: spectrumColor,
                  size: 14,
                  isPlaying: isPlaying,
                )
              : const SizedBox.shrink(),
          onTap: () {
            // 点击切歌（不关闭面板，留在容器）
            playerProvider.playSongAt(index);
          },
        ),
      ),
    );

    return RawGestureDetector(
      key: key,
      gestures: {
        _RightSwipeOnlyRecognizer:
            GestureRecognizerFactoryWithHandlers<_RightSwipeOnlyRecognizer>(
          () => _RightSwipeOnlyRecognizer(
            onUpdate: (v) => _onSwipeUpdate(song.id, v),
            onEnd: (v) => _onSwipeEnd(song.id, v, playerProvider),
            onCancel: () => _onSwipeCancel(song.id),
          ),
          (_) {},
        ),
      },
      child: Stack(
        children: [
          // 红底 + 垃圾桶（越过阈值后 100ms 淡入）
          Positioned.fill(
            child: AnimatedContainer(
              duration: _fadeDuration,
              curve: Curves.easeOut,
              // 阈值前完全透明（不可见），阈值后显示删除底色
              color: thresholdReached ? deleteBg : Colors.transparent,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Icon(
                Icons.delete_outline,
                color: thresholdReached ? deleteIconOn : deleteIconOff,
                size: 28,
              ),
            ),
          ),
          // 列表项跟手位移：跟手时 duration=0 直接跟随，回弹时 200ms 动画复位
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: dx),
            duration: Duration(milliseconds: reverting ? 200 : 0),
            curve: Curves.easeOut,
            builder: (context, v, child) =>
                Transform.translate(offset: Offset(v, 0), child: child),
            child: item,
          ),
        ],
      ),
    );
  }

  /// 右滑跟手更新：记录位移，越过阈值时触发一次震动（红底由阈值驱动自动淡入）。
  void _onSwipeUpdate(String songId, double dx) {
    final clamped = dx < 0 ? 0.0 : dx;
    if (dx >= _deleteThreshold) {
      if (_hapticTriggered[songId] != true) {
        AppHaptics.heavy();
        _hapticTriggered[songId] = true;
      }
    } else {
      _hapticTriggered[songId] = false;
    }
    setState(() {
      _dragExtent[songId] = clamped;
    });
  }

  /// 松手：超过阈值则删除该项，否则回弹复位。
  void _onSwipeEnd(
    String songId,
    double dx,
    PlayerProvider playerProvider,
  ) {
    _hapticTriggered.remove(songId);
    if (dx >= _deleteThreshold) {
      setState(() {
        _dragExtent.remove(songId);
        _reverting.remove(songId);
      });
      // 用 songId 反查实时索引：列表增删/重排后，识别器闭包捕获的旧 index 可能失效
      final idx = playerProvider.playlist.indexWhere((s) => s.id == songId);
      if (idx != -1) {
        // 直接修改 PlayerProvider，ReorderableListView 重建并移除对应 item
        playerProvider.removeFromPlaylist(idx);
      }
    } else {
      _revertSwipe(songId);
    }
  }

  /// 手势取消：直接回弹复位。
  void _onSwipeCancel(String songId) {
    _hapticTriggered.remove(songId);
    _revertSwipe(songId);
  }

  /// 回弹动画复位（200ms easeOut），结束后清理回弹标记。
  void _revertSwipe(String songId) {
    setState(() {
      _reverting[songId] = true;
      _dragExtent[songId] = 0;
    });
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) {
        setState(() => _reverting.remove(songId));
      }
    });
  }
}
