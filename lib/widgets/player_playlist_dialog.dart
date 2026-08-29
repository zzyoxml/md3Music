import 'package:flutter/gestures.dart'
    show DelayedMultiDragGestureRecognizer, MultiDragGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/models/song.dart';
import '../core/layout/responsive_layout.dart';
import '../core/utils/app_haptics.dart';
import '../providers/player_provider.dart';

/// 自定义长按延迟 700ms 的 Reorderable 监听器。
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

/// 播放器播放列表对话框。
///
/// 支持：
/// 1. 长按 700ms 拖拽重排（Flutter 内置 ReorderableListView）
/// 2. 左滑渐变红色 + 40% 阈值震动反馈，松手后删除
///
/// 横屏自适应：横屏时显示在屏幕右半边（不遮挡左侧全屏播放器），
/// 竖屏时居中显示 300x500。
///
/// 抽离自 full_player.dart 与 full_player_am.dart 的 _showPlaylist 方法，
/// 两版逻辑完全一致，仅标题字段（title vs displayName）不同。
class PlayerPlaylistDialog extends StatefulWidget {
  /// 是否使用 displayName（AM 风格）vs title（MD3 风格）
  final bool useDisplayName;

  const PlayerPlaylistDialog({super.key, this.useDisplayName = false});

  @override
  State<PlayerPlaylistDialog> createState() => _PlayerPlaylistDialogState();
}

class _PlayerPlaylistDialogState extends State<PlayerPlaylistDialog> {
  /// 记录每首歌的震动是否已触发，避免滑动过程中连续触发 heavyImpact。
  /// 当滑动进度回到 < 40% 时重置，允许下次越过阈值再次触发。
  final Map<String, bool> _hapticTriggered = {};

  /// 记录每首歌红色背景是否已显示（用于 100ms 淡入动画）。
  /// < 40% 时重置回 false，> 40% 时置 true。
  final Map<String, bool> _redBgVisible = {};

  static const double _swipeThreshold = 0.4;
  static const Duration _fadeDuration = Duration(milliseconds: 100);

  /// 播放列表滚动控制器
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 打开对话框后自动滚动到当前播放歌曲
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
    final targetOffset = (currentIndex * itemHeight) - (viewportHeight / 2) + (itemHeight / 2);
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
    final size = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    final isPad = isPadLayout(context);
    final isLandscape = size.width > size.height;

    final double width;
    final double height;
    final EdgeInsets margin;

    if (isPad) {
      // Pad: 60% 宽高，居中
      width = size.width * 0.6;
      height = size.height * 0.6;
      margin = EdgeInsets.zero;
    } else if (isLandscape) {
      // 手机横屏：宽 50%，高 90%，靠右，右边距 10%
      width = size.width * 0.5;
      height = size.height * 0.9;
      margin = EdgeInsets.only(right: size.width * 0.1);
    } else {
      // 手机竖屏：宽 80%，高 70%，居中
      width = size.width * 0.8;
      height = size.height * 0.7;
      margin = EdgeInsets.zero;
    }

    return Center(
      child: Padding(
        padding: margin,
        child: Material(
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          color: theme.colorScheme.surface,
          surfaceTintColor: theme.colorScheme.surfaceTint,
          elevation: 6,
          child: SizedBox(
            width: width,
            height: height,
            child: _buildDialogBody(),
          ),
        ),
      ),
    );
  }

  /// 内部内容：标题 + 列表 + 底部操作栏
  ///
  /// 外部由 build() 用 Center + Material + SizedBox 包裹（统一 28 圆角 + 居中），
  /// 本方法只负责布局 Column，不再控制圆角/尺寸。
  Widget _buildDialogBody() {
    final playerProvider = context.watch<PlayerProvider>();
    final playlist = playerProvider.playlist;
    final theme = Theme.of(context);

    return Column(
      children: [
        // 顶部标题栏
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text('播放列表', style: theme.textTheme.titleLarge),
        ),
        // 歌曲列表
        Expanded(
          child: playlist.isEmpty
              ? Center(
                  child: Text(
                    '播放列表为空',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ReorderableListView(
                  scrollController: _scrollController,
                  buildDefaultDragHandles: false,
                  onReorder: (oldIndex, newIndex) {
                    playerProvider.reorderPlaylist(oldIndex, newIndex);
                  },
                  children: [
                    for (int index = 0; index < playlist.length; index++)
                      _buildDismissibleItem(
                        key: ValueKey(playlist[index].id),
                        index: index,
                        song: playlist[index],
                        isCurrent: index == playerProvider.currentIndex,
                        playerProvider: playerProvider,
                        theme: theme,
                      ),
                  ],
                ),
        ),
        // 底部操作栏
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: playlist.isEmpty
                    ? null
                    : () {
                        playerProvider.clearPlaylist();
                        Navigator.pop(context);
                      },
                child: const Text('清空'),
              ),
              // 操作提示文字：字号小一点，颜色淡一点
              Text(
                '长按拖拽 · 左滑删除',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建一个可左滑删除 + 长按拖拽的列表项。
  ///
  /// 嵌套层级：Dismissible（左滑删除）→ _LongPressReorderableDragStartListener
  /// （长按 700ms 触发拖拽）→ ListTile
  Widget _buildDismissibleItem({
    required Key key,
    required int index,
    required Song song,
    required bool isCurrent,
    required PlayerProvider playerProvider,
    required ThemeData theme,
  }) {
    return Dismissible(
      key: key,
      direction: DismissDirection.endToStart, // 仅左滑（手势从右往左）
      // 横屏下适当延长 dismiss 动画，让用户能看清缩起过程
      resizeDuration: const Duration(milliseconds: 300),
      dismissThresholds: const {DismissDirection.endToStart: _swipeThreshold},
      background: _buildSwipeBackground(
        theme,
        visible: _redBgVisible[song.id] ?? false,
      ),
      onUpdate: (details) {
        // details.progress ∈ [0, 1]，_swipeThreshold 即用户设定的阈值
        if (details.progress >= _swipeThreshold) {
          // 越过阈值：触发震动 + 淡入红色背景（100ms）
          if (_hapticTriggered[song.id] != true) {
            AppHaptics.heavy();
            _hapticTriggered[song.id] = true;
          }
          if (_redBgVisible[song.id] != true) {
            setState(() {
              _redBgVisible[song.id] = true;
            });
          }
        } else {
          // 进度回到阈值以下：允许下次越过时再次震动 + 隐藏红色背景
          if (_hapticTriggered[song.id] != false) {
            _hapticTriggered[song.id] = false;
          }
          if (_redBgVisible[song.id] != false) {
            setState(() {
              _redBgVisible[song.id] = false;
            });
          }
        }
      },
      confirmDismiss: (direction) async {
        // 松手时 Dismissible 已根据阈值决定是否 dismiss
        // 返回 true 让它执行 dismiss 动画
        return true;
      },
      onDismissed: (direction) {
        _hapticTriggered.remove(song.id);
        _redBgVisible.remove(song.id);
        // onDismissed 在 Dismissible 自身的缩起动画完成后回调，
        // 此时直接修改 PlayerProvider 即可，ReorderableListView 会
        // 重建并移除对应 item，不会打断已完成的动画。
        if (mounted) {
          playerProvider.removeFromPlaylist(index);
        }
      },
      child: Material(
        type: MaterialType.transparency,
        // 自定义子类：长按 700ms 后触发拖拽（比默认 500ms 稍长，减少误触）
        child: _LongPressReorderableDragStartListener(
          index: index,
          child: ListTile(
            leading: isCurrent
                ? Icon(Icons.play_arrow, color: theme.colorScheme.primary)
                : Text('${index + 1}'),
            title: Center(
              child: Text(
                widget.useDisplayName ? song.displayName : song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: isCurrent ? FontWeight.bold : null,
                  color: isCurrent ? theme.colorScheme.primary : null,
                ),
              ),
            ),
            subtitle: Center(
              child: Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            onTap: () {
              playerProvider.playSongAt(index);
              Navigator.pop(context);
            },
          ),
        ),
      ),
    );
  }

  /// 左滑背景：垃圾桶图标始终显示，红色背景仅在越过 40% 阈值后从右往左淡入。
  ///
  /// 拆分为两层：
  /// - 背景色：AnimatedContainer 颜色随可见状态变化
  /// - 图标：始终显示
  Widget _buildSwipeBackground(ThemeData theme, {required bool visible}) {
    return AnimatedContainer(
      duration: _fadeDuration,
      curve: Curves.easeOut,
      // 阈值前完全透明（不可见），阈值后显示 errorContainer 色
      color: visible ? theme.colorScheme.errorContainer : Colors.transparent,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(
        // 垃圾桶图标：始终显示
        Icons.delete_outline,
        // 阈值前用 error 色（深红），阈值后用 onErrorContainer（与红底对比）
        color: visible
            ? theme.colorScheme.onErrorContainer
            : theme.colorScheme.error,
        size: 28,
      ),
    );
  }
}
