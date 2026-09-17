import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils/app_haptics.dart';
import '../data/models/song.dart';
import '../providers/player_provider.dart';
import 'player_artwork_image.dart';
import 'playing_spectrum_indicator.dart';

/// 播放器内嵌的播放列表（队列）面板。
///
/// 编辑 / 删除 / 排序与「歌单详情页」共用同一套心智模型：
/// - 常态：点击切歌；长按进入编辑模式并选中该项
/// - 编辑模式：顶栏「✕ / 已选 N 首 / 全选 / 删除」，封面位替换为圆形复选框，
///   右侧出现把手用于拖拽重排（多选视觉与 SongListItem 一致）
/// - 排序：播放顺序 / 标题 / 时长，重复点同一项切换升降序；队列的顺序就是
///   播放顺序，因此排序会真实重排队列（见 [PlayerProvider.sortPlaylist]）
///
/// 清空整个队列＝编辑模式里「全选 → 删除」，因此头部不再单独放清空按钮。
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

/// 面板配色：AM 皮肤（深色背景上的白色系）与 MD3 皮肤（主题莫奈色）两套。
class _PanelColors {
  _PanelColors(ColorScheme cs, bool useAm)
    : title = useAm ? Colors.white : cs.onSurface,
      secondary = useAm ? const Color(0xB3FFFFFF) : cs.onSurfaceVariant,
      action = useAm ? Colors.white : cs.primary,
      disabled = useAm
          ? const Color(0x40FFFFFF)
          : cs.onSurface.withValues(alpha: 0.38),
      danger = useAm ? Colors.redAccent : cs.error,
      selectedRow = useAm
          ? Colors.white.withValues(alpha: 0.12)
          : cs.primaryContainer.withValues(alpha: 0.3),
      checkFill = useAm ? Colors.white : cs.primary,
      checkMark = useAm ? Colors.black : cs.onPrimary,
      checkBorder = useAm
          ? const Color(0x73FFFFFF)
          : cs.outline.withValues(alpha: 0.5),
      artworkBg = useAm ? Colors.white12 : cs.surfaceContainerHighest,
      artworkIcon = useAm ? Colors.white54 : cs.onSurfaceVariant,
      spectrum = useAm ? Colors.white : cs.primary,
      handle = useAm ? const Color(0x73FFFFFF) : cs.onSurfaceVariant;

  final Color title;
  final Color secondary;
  final Color action;
  final Color disabled;
  final Color danger;
  final Color selectedRow;
  final Color checkFill;
  final Color checkMark;
  final Color checkBorder;
  final Color artworkBg;
  final Color artworkIcon;
  final Color spectrum;
  final Color handle;
}

class _PlayerPlaylistViewState extends State<PlayerPlaylistView> {
  /// 播放列表滚动控制器
  final ScrollController _scrollController = ScrollController();

  /// 编辑模式（多选 + 拖拽重排）
  bool _editMode = false;

  /// 编辑模式下已勾选的歌曲 id
  final Set<String> _selectedIds = {};

  /// 当前排序维度与升降序（与歌单页同一套交互：重复点同项切换升降）
  PlaylistSortBy _sortBy = PlaylistSortBy.queue;
  bool _sortAscending = true;

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

  /// 长按某一项：进入编辑模式并选中它（与歌单页一致）
  void _enterEditMode(String songId) {
    AppHaptics.heavy();
    setState(() {
      _editMode = true;
      _selectedIds
        ..clear()
        ..add(songId);
    });
  }

  void _exitEditMode() {
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String songId) {
    setState(() {
      if (!_selectedIds.remove(songId)) _selectedIds.add(songId);
    });
  }

  /// 全选 / 取消全选
  void _toggleSelectAll(List<Song> playlist) {
    setState(() {
      if (_selectedIds.length == playlist.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(playlist.map((s) => s.id));
      }
    });
  }

  /// 排序菜单选中某项：同项再点切换升降序，换项则回到升序
  void _onSortSelected(PlaylistSortBy value, PlayerProvider playerProvider) {
    setState(() {
      if (_sortBy == value) {
        _sortAscending = !_sortAscending;
      } else {
        _sortBy = value;
        _sortAscending = true;
      }
    });
    playerProvider.sortPlaylist(_sortBy, ascending: _sortAscending);
  }

  /// 删除选中歌曲前弹二次确认（与歌单页的批量删除同口径）。
  Future<void> _confirmDeleteSelected(PlayerProvider playerProvider) async {
    final count = _selectedIds.length;
    if (count == 0) return;
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
        title: Text('删除歌曲', style: TextStyle(color: colorScheme.onSurface)),
        content: Text(
          '确定从播放列表中删除选中的 $count 首歌曲吗？',
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
            child: Text('删除', style: TextStyle(color: colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await playerProvider.removeManyFromPlaylist(Set.of(_selectedIds));
    if (mounted) _exitEditMode();
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
        final colors = _PanelColors(
          Theme.of(context).colorScheme,
          widget.useAmColors,
        );
        // 队列被清空后自动退出编辑模式，避免顶栏停留在「已选 N 首」
        if (_editMode && playlist.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _editMode) _exitEditMode();
          });
        }
        return Column(
          children: [
            _editMode
                ? _buildEditHeader(playerProvider, playlist, colors)
                : _buildNormalHeader(playerProvider, playlist, colors),
            Expanded(
              child: playlist.isEmpty
                  ? Center(
                      child: Text(
                        '播放列表为空',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.secondary,
                        ),
                      ),
                    )
                  : _buildList(playerProvider, playlist, data, colors),
            ),
          ],
        );
      },
    );
  }

  /// 常态头部：标题 + 排序 + 编辑
  Widget _buildNormalHeader(
    PlayerProvider playerProvider,
    List<Song> playlist,
    _PanelColors colors,
  ) {
    final enabled = playlist.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '播放列表',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.title,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _buildSortMenu(playerProvider, enabled, colors),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            color: enabled ? colors.action : colors.disabled,
            onPressed: enabled ? () => setState(() => _editMode = true) : null,
          ),
        ],
      ),
    );
  }

  /// 编辑模式头部：关闭 / 已选 N 首 / 全选 / 删除（与歌单页多选顶栏一致）
  Widget _buildEditHeader(
    PlayerProvider playerProvider,
    List<Song> playlist,
    _PanelColors colors,
  ) {
    final allSelected =
        playlist.isNotEmpty && _selectedIds.length == playlist.length;
    final hasSelection = _selectedIds.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            color: colors.title,
            onPressed: _exitEditMode,
          ),
          Expanded(
            child: Text(
              '已选 ${_selectedIds.length} 首',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.title,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _toggleSelectAll(playlist),
            child: Text(
              allSelected ? '取消全选' : '全选',
              style: TextStyle(color: colors.action),
            ),
          ),
          TextButton(
            onPressed: hasSelection
                ? () => _confirmDeleteSelected(playerProvider)
                : null,
            child: Text(
              '删除',
              style: TextStyle(
                color: hasSelection ? colors.danger : colors.disabled,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 排序菜单：播放顺序 / 标题 / 时长，当前项右侧显示升降箭头。
  /// 用 TooltipVisibility 关掉 PopupMenuButton 的默认「显示菜单」气泡：
  /// 播放器详情页统一不弹按钮说明，长按只走长按动作。
  Widget _buildSortMenu(
    PlayerProvider playerProvider,
    bool enabled,
    _PanelColors colors,
  ) {
    return TooltipVisibility(
      visible: false,
      child: PopupMenuButton<PlaylistSortBy>(
        enabled: enabled,
        icon: Icon(
          Icons.swap_vert,
          color: enabled ? colors.action : colors.disabled,
        ),
        onSelected: (value) => _onSortSelected(value, playerProvider),
        itemBuilder: (context) => [
          _sortMenuItem(PlaylistSortBy.queue, '播放顺序'),
          _sortMenuItem(PlaylistSortBy.title, '标题'),
          _sortMenuItem(PlaylistSortBy.duration, '时长'),
        ],
      ),
    );
  }

  PopupMenuItem<PlaylistSortBy> _sortMenuItem(
    PlaylistSortBy value,
    String label,
  ) {
    final checked = _sortBy == value;
    return CheckedPopupMenuItem<PlaylistSortBy>(
      value: value,
      checked: checked,
      child: Row(
        children: [
          Text(label),
          // 「播放顺序」就是队列当前顺序，没有升降之分，因此不显示箭头
          if (checked && value != PlaylistSortBy.queue) ...[
            const SizedBox(width: 4),
            Icon(
              _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 16,
            ),
          ],
        ],
      ),
    );
  }

  /// 歌曲列表：与评论区一致的上下边界 alpha 渐变；
  /// 拖拽把手只在编辑模式出现（buildDefaultDragHandles=false）。
  Widget _buildList(
    PlayerProvider playerProvider,
    List<Song> playlist,
    ({int fingerprint, int currentIndex, bool isPlaying}) data,
    _PanelColors colors,
  ) {
    return ShaderMask(
      shaderCallback: (Rect bounds) {
        const double fadeHeight = 24.0;
        final double fadeRatio = (fadeHeight / bounds.height).clamp(0.0, 0.5);
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
            builder: (context, _) => Opacity(opacity: 0.7, child: child),
          );
        },
        onReorder: (oldIndex, newIndex) {
          playerProvider.reorderPlaylist(oldIndex, newIndex);
        },
        children: [
          for (int index = 0; index < playlist.length; index++)
            _buildItem(
              key: ValueKey(playlist[index].id),
              index: index,
              song: playlist[index],
              isCurrent: index == data.currentIndex,
              isPlaying: data.isPlaying,
              playerProvider: playerProvider,
              colors: colors,
            ),
        ],
      ),
    );
  }

  /// 单个列表项。
  ///
  /// 常态：封面 + 标题/艺人 + 正在播放的频谱标识；点击切歌，长按进编辑模式。
  /// 编辑模式：封面左侧插入圆形复选框（封面保持可见）、右侧换成拖拽把手；
  /// 点击整行切换勾选。
  Widget _buildItem({
    required Key key,
    required int index,
    required Song song,
    required bool isCurrent,
    required bool isPlaying,
    required PlayerProvider playerProvider,
    required _PanelColors colors,
  }) {
    final selected = _selectedIds.contains(song.id);
    final artwork = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 44,
        height: 44,
        child: PlayerArtworkImage(
          artworkUri: song.artworkUri,
          fallbackFilePath: song.localPath,
          fit: BoxFit.cover,
          backgroundColor: colors.artworkBg,
          iconColor: colors.artworkIcon,
        ),
      ),
    );
    return Material(
      key: key,
      type: MaterialType.transparency,
      child: ListTile(
        // 勾选高亮用 tileColor 而不是外层 ColoredBox：
        // ListTile 的底色与水波纹画在最近的 Material 上，外层套色会盖住它们
        tileColor: _editMode && selected ? colors.selectedRow : null,
        // 编辑模式下复选框与封面并排，而不是取代封面
        leading: _editMode
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildCheckbox(selected, colors),
                  const SizedBox(width: 8),
                  artwork,
                ],
              )
            : artwork,
        title: Text(
          widget.useDisplayName ? song.displayName : song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            // 正文纯色，当前歌曲加粗
            color: colors.title,
            fontWeight: isCurrent ? FontWeight.bold : null,
          ),
        ),
        subtitle: Text(
          song.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.secondary),
        ),
        trailing: _buildTrailing(index, isCurrent, isPlaying, colors),
        onTap: () {
          if (_editMode) {
            _toggleSelection(song.id);
          } else {
            // 点击切歌（不关闭面板，留在容器）
            playerProvider.playSongAt(index);
          }
        },
        onLongPress: _editMode ? null : () => _enterEditMode(song.id),
      ),
    );
  }

  /// 行尾：编辑模式给拖拽把手，常态给「正在播放」的三柱波形
  Widget _buildTrailing(
    int index,
    bool isCurrent,
    bool isPlaying,
    _PanelColors colors,
  ) {
    if (_editMode) {
      return ReorderableDragStartListener(
        index: index,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(Icons.drag_handle, color: colors.handle),
        ),
      );
    }
    if (isCurrent) {
      // 歌单同款三柱起伏波形（暂停时 ticker 停止保留最后一帧）
      return PlayingSpectrumIndicator(
        color: colors.spectrum,
        size: 14,
        isPlaying: isPlaying,
      );
    }
    return const SizedBox.shrink();
  }

  /// 编辑模式的圆形复选框（放在封面左侧，不遮挡封面）
  Widget _buildCheckbox(bool selected, _PanelColors colors) {
    return SizedBox(
      width: 24,
      height: 24,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: selected
            ? DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.checkFill,
                ),
                child: Icon(Icons.check, color: colors.checkMark, size: 16),
              )
            : DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.checkBorder, width: 2),
                ),
              ),
      ),
    );
  }
}
