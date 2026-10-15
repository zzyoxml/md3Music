import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/utils/app_haptics.dart';
import '../data/models/song.dart';
import '../modules/player/playlist_swipe.dart';
import '../providers/player_provider.dart';
import 'm3e_sort_sheet.dart';
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

  /// 滑页手势的三段上报（原始指针判定，见 playlist_swipe.dart）。
  ///
  /// 面板每行卡片都注册了水平拖拽（滑动删除），外层 TabBarView 收不到事件，
  /// 所以判定在面板内完成，并**逐帧**上报进度，让页面跟手，而不是过了阈值才跳。
  /// 全部为空时不启用该判定（独立使用本面板时无副作用）。
  /// 进入跟手阶段时回调一次（在第一次上报进度**之前**）：宿主在这里记下
  /// 「从哪一页开始拖」，好让补间途中被重新抓住时不跳回第 0 页。
  final VoidCallback? onSwipeStart;

  /// 拖动中：已滑过的比例（0~1，1 = 整页宽度）。越过 touch slop 的那一次移动
  /// 被丢弃（与 Scrollable 的 `_pastTouchSlop` 同口径），避免手指刚一动就跳一截。
  final ValueChanged<double>? onSwipeProgress;

  /// 松手：水平速度（逻辑像素/秒，向左为负）与面板宽度，供宿主算吸附到哪一页。
  final void Function(double velocity, double panelWidth)? onSwipeRelease;

  /// 滚动位置的归属（宿主持有）。面板会被 PageView 销毁重建，控制器与
  /// 「偏移属于哪首歌」必须活在面板之外，否则切回来就是顶部。
  final PlaylistScrollAnchor scrollAnchor;

  const PlayerPlaylistView({
    super.key,
    required this.scrollAnchor,
    this.useDisplayName = true,
    this.useAmColors = true,
    this.onSwipeStart,
    this.onSwipeProgress,
    this.onSwipeRelease,
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

/// 播放列表滚动位置的**归属**：由播放页 State 持有，面板只借用它。
///
/// 为什么不能在面板内部 new 控制器：面板挂在 `PlayerTabPager`（`PageView` +
/// `children`，cacheExtent=0）上，切到歌词/评论页签时**整棵子树被销毁**
/// （`player_tab_pager.dart` 里自己就写着这条）。控制器随 State 一起消失，
/// 重建时滚动位置自然归零 —— 用户看到的就是「切走再回来回到顶部」。
///
/// 为什么不能用 `TrackingScrollController`（听起来正是为「同一路由里多个懒建
/// 滚动视图」准备的）：SDK `scroll_controller.dart` 的 `detach()` 里有
/// `if (_positionToListener.isEmpty) _lastUpdatedOffset = null;` —— **最后一个
/// client 摘掉时记录就清零**，而本例恰恰是「唯一的那个列表被连子树销毁」。
/// 实测：手指滚到 880，重建回来是 0。所以偏移要自己记账，并赶在**新 position
/// 创建之前**通过 `ScrollController(initialScrollOffset:)` 交回去（这个值只能在
/// 构造时给）—— 于是列表出生就在原偏移，不需要事后再 jumpTo，也就不会闪一帧顶部。
///
/// [positionedForSongId] 记的是「这份偏移是为哪首歌取得的」。面板每次重建都会
/// 「滚到当前播放曲」，那条自动定位会把刚恢复回来的位置直接盖掉（当前曲靠前时
/// 目标还被 clamp 成 0，看起来更是回到顶部）。有了它就能把两种语义分开：
/// **同一首歌内切走再回来保持原位；歌变了才跟到新曲**。
class PlaylistScrollAnchor {
  PlaylistScrollAnchor() {
    _controller = _make(0);
  }

  late ScrollController _controller;
  double? _savedOffset;

  /// 面板借用的控制器。身份只在「没有任何 client」的安全时刻被换掉（见
  /// [attachForNewPanel]），所以面板存续期间 Scrollable 不会看到控制器变卦。
  ScrollController get controller => _controller;

  /// 已定位过的那首歌 id；null = 还没定位过（面板第一次出现）。
  String? positionedForSongId;

  ScrollController _make(double initialOffset) => ScrollController(
    initialScrollOffset: initialOffset,
    // 摘掉的那一刻 position.pixels 仍可读：就地记账，交给下一任面板出生时用。
    onDetach: (position) => _savedOffset = position.pixels,
  );

  /// 面板 `initState` 调用：把上一任面板留下的偏移装进一个新控制器。
  void attachForNewPanel() {
    final saved = _savedOffset;
    // 有 client 说明上一任还活着（本不该发生：三个布局分支同一时刻只建一个），
    // 此时绝不换控制器。
    if (saved == null || _controller.hasClients) return;
    _controller.dispose();
    _controller = _make(saved);
  }

  void dispose() => _controller.dispose();
}

class _PlayerPlaylistViewState extends State<PlayerPlaylistView> {
  /// 滚动控制器来自宿主持有的 [PlaylistScrollAnchor]：本 State 会被 PageView
  /// 连子树一起销毁，所以控制器与「为哪首歌定位过」都不能存在这里。
  ScrollController get _scrollController => widget.scrollAnchor.controller;

  /// 编辑模式（多选 + 拖拽重排）
  bool _editMode = false;

  /// 编辑模式下已勾选的歌曲 id
  final Set<String> _selectedIds = {};

  /// 当前排序维度与升降序（与歌单页同一套交互：重复点同项切换升降）
  PlaylistSortBy _sortBy = PlaylistSortBy.queue;
  bool _sortAscending = true;

  // ── 「从右往左滑 → 下一个 tab」的跟手跟踪 ──
  //
  // 阈值全部走 playlist_swipe.dart 的纯函数（可单测），这里只保留面板自己的
  // 状态。判定顺序：先纵向上限（把手势让给列表），再做一次方向判定，
  // 之后不再回头——与手势竞技场「一次定方向」的语义一致。
  /// 面板宽度（LayoutBuilder 记录），用于把位移换算成页面进度。
  double _panelWidth = 0;

  /// 正在跟踪的指针 id（多指按下时置空，避免与双指手势冲突）
  int? _swipePointer;

  /// 本次跟踪的起点（全局坐标）
  Offset _swipeOrigin = Offset.zero;

  /// 本次指针序列已放弃（多指 / 纵向超限）：不再上报
  bool _swipeConsumed = false;

  /// 已越过 touch slop：越过的那一次移动要丢弃
  bool _swipePastSlop = false;

  /// 已进入跟手阶段：此后不再重新做方向判定
  bool _swipeTracking = false;

  /// 本次指针序列的速度采样器。
  ///
  /// PointerEvent 本身**不携带速度**（Flutter 的 gestures/events.dart 里没有
  /// velocity 字段，速度只存在于 DragEndDetails / LongPressEndDetails），
  /// 所以这里自己按 Scrollable / LongPressGestureRecognizer 的同款做法用
  /// [VelocityTracker] 累积「时间戳 + 坐标」，松手时反推速度。
  VelocityTracker? _swipeVelocityTracker;

  @override
  void initState() {
    super.initState();
    // 把上一任面板（被 PageView 销毁的那棵子树）留下的偏移装进新控制器：
    // 必须赶在 Scrollable 创建 position 之前，所以放在 initState 而不是 postFrame。
    widget.scrollAnchor.attachForNewPanel();
  }

  @override
  void dispose() {
    // 控制器属于宿主的 [PlaylistScrollAnchor]，不由本 State 释放。
    super.dispose();
  }

  bool get _swipeEnabled => widget.onSwipeProgress != null;

  void _handleSwipePointerDown(PointerDownEvent event) {
    if (!_swipeEnabled) return;
    if (_swipePointer != null) {
      // 多指按下（缩放等）：放弃本次判定
      _swipePointer = null;
      _swipeConsumed = true;
      _swipeVelocityTracker = null;
      return;
    }
    _swipePointer = event.pointer;
    _swipeOrigin = event.position;
    _swipeConsumed = false;
    _swipePastSlop = false;
    _swipeTracking = false;
    _swipeVelocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _handleSwipePointerMove(PointerMoveEvent event) {
    if (!_swipeEnabled || _swipeConsumed) return;
    if (event.pointer != _swipePointer) return;

    final offset = event.position - _swipeOrigin;

    // 采样速度：轻扫的动能全在这段位移里，松手时用它决定是否翻页
    _swipeVelocityTracker?.addPosition(event.timeStamp, event.position);

    // 已经在跟手：1:1 跟随，不再回头做方向判定（纵向漂移交给列表自己的识别器）
    if (_swipeTracking) {
      widget.onSwipeProgress!(
        playlistSwipeProgressFromDx(offset.dx, _panelWidth),
      );
      return;
    }

    // 「先纵向后横向」一律放弃：纵向一旦超限就把手势让给列表滚动 / 长按拖拽重排
    if (playlistSwipeCrossAxisExceeded(offset.dy)) {
      _swipeConsumed = true;
      return;
    }
    // 只认「从右往左」：右滑留给列表的滑动删除
    if (!playlistSwipeIsForwardHorizontal(offset.dx, offset.dy)) return;
    // 越过 touch slop 的那一次移动丢弃（Scrollable 同口径），避免起手就跳一截
    if (!_swipePastSlop) {
      _swipePastSlop = true;
      return;
    }

    _swipeTracking = true;
    widget.onSwipeStart?.call();
    widget.onSwipeProgress!(
      playlistSwipeProgressFromDx(offset.dx, _panelWidth),
    );
  }

  void _handleSwipePointerEnd(PointerEvent event) {
    if (event.pointer != _swipePointer) return;
    _swipePointer = null;
    _swipeConsumed = false;
    _swipePastSlop = false;
    final wasTracking = _swipeTracking;
    _swipeTracking = false;
    // 取消（系统手势打断）没有可信速度，按 0 处理：纯按位置吸附。
    // PointerEvent 不带 velocity，只能取本次指针序列攒下的采样反推。
    final velocity = event is PointerUpEvent
        ? (_swipeVelocityTracker?.getVelocityEstimate()?.pixelsPerSecond.dx ??
              0.0)
        : 0.0;
    _swipeVelocityTracker = null;
    if (!wasTracking) return;
    widget.onSwipeRelease?.call(velocity, _panelWidth);
  }

  /// 滚动到当前播放的歌曲并居中显示。
  ///
  /// 行高**实测**，不再猜 72：高度统一的列表里
  /// `maxScrollExtent + viewportDimension == 内容总高 == itemCount × itemExtent`，
  /// 除一下就是真实行高，「显示大小」缩放、编辑模式的行内差异都自动跟上。
  /// 旧实现写死 72（ListTile 默认高），误差随下标**线性累积** —— 真机行高只要
  /// 差 6dp，到第 50 首就已经偏出去 300dp，落点根本不是当前那一行。
  void _scrollToCurrentSong() {
    final playerProvider = context.read<PlayerProvider>();
    final currentIndex = playerProvider.currentIndex;
    final count = playerProvider.playlist.length;
    if (currentIndex < 0 ||
        currentIndex >= count ||
        !_scrollController.hasClients) {
      return;
    }

    final position = _scrollController.position;
    final viewportHeight = position.viewportDimension;
    // 实测行高：内容总高 ÷ 项数。列表无 padding、无分隔、所有项等高，
    // 此时 maxScrollExtent + viewportDimension == count × itemHeight，
    // 除一下即真实行高（内容不足一屏时 maxScrollExtent 为 0，目标偏移
    // 会被下面 clamp 回 0，算出的 itemHeight 偏差不影响结果）。
    final itemHeight = (position.maxScrollExtent + viewportHeight) / count;
    final targetOffset =
        currentIndex * itemHeight - (viewportHeight / 2) + (itemHeight / 2);
    final offset = targetOffset.clamp(0.0, position.maxScrollExtent);

    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 长按某一项：进入编辑模式并选中它（与歌单页一致）
  void _enterEditMode(String songId) {
    AppHaptics.heavy(HapticCategory.listItem);
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

  /// 排序菜单选中某项：同项再点切换升降序（repeated），换项则回到升序
  void _onSortSelected(
    PlaylistSortBy value,
    PlayerProvider playerProvider, {
    required bool repeated,
  }) {
    setState(() {
      if (repeated) {
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
        // 「歌变了才跟到新曲；同一首歌内切走再回来保持原位」。
        // 判据用歌曲 id 而不是 currentIndex：重排/删行会让下标漂移，但正在放的
        // 还是那首歌，就不该把用户从他的位置上拉走。
        // 旧版是在 initState 里无条件定位的，而本 State 每次切页签回来都是新建的
        // —— 那条定位正好把刚恢复回来的偏移盖掉（当前曲靠前时目标还被 clamp 成 0，
        // 看起来就是「回到顶部」）。
        // 动作排到下一帧：此刻正在 build，直接动 ScrollPosition 属于构建期副作用。
        final currentId =
            data.currentIndex >= 0 && data.currentIndex < playlist.length
            ? playlist[data.currentIndex].id
            : null;
        if (currentId != null &&
            currentId != widget.scrollAnchor.positionedForSongId) {
          widget.scrollAnchor.positionedForSongId = currentId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToCurrentSong();
          });
        }
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
        // 用不参与手势竞技场的 Listener（原始指针事件）自行判定「从右往左滑切页」：
        // 队列每行的卡片都注册了 onHorizontalDrag*（m3e_core
        // m3e_dismissible_card_controller.dart 的 _buildActiveCard），它在
        // `direction != none` 时**无论滑动方向**都会抢下水平拖拽竞技场，外层
        // TabBarView 的水平滑动因此永远收不到事件 —— 所以不能用外层
        // GestureDetector / 也不能指望 TabBarView 自己翻页。
        // style.direction 只在卡片内部钳制位移（没有传给识别器做方向过滤），
        // 因此「从左往右＝滑动删除」这段手势保持原样，左滑切页单独在这里判定。
        return Listener(
          onPointerDown: _handleSwipePointerDown,
          onPointerMove: _handleSwipePointerMove,
          onPointerUp: _handleSwipePointerEnd,
          onPointerCancel: _handleSwipePointerEnd,
          // LayoutBuilder 只量一次宽度写进字段（不 setState，故不会引起重建）：
          // 滑页进度 = 左滑位移 / 一页宽度。
          child: LayoutBuilder(
            builder: (context, constraints) {
              _panelWidth = constraints.maxWidth;
              return Column(
                children: [
                  _editMode
                      ? _buildEditHeader(playerProvider, playlist, colors)
                      : _buildNormalHeader(playerProvider, playlist, colors),
                  Expanded(
                    child: _buildList(playerProvider, playlist, data, colors),
                  ),
                ],
              );
            },
          ),
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
          // 本页约定不弹气泡说明，读屏标签走 Semantics 而非 tooltip
          Semantics(
            label: '编辑',
            child: IconButton(
              icon: const Icon(Icons.edit_outlined),
              color: enabled ? colors.action : colors.disabled,
              onPressed: enabled
                  ? () => setState(() => _editMode = true)
                  : null,
            ),
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
          Semantics(
            label: '关闭',
            child: IconButton(
              icon: const Icon(Icons.close),
              color: colors.title,
              onPressed: _exitEditMode,
            ),
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

  /// 排序按钮：播放顺序 / 标题 / 时长，点一下 M3E 下拉面板就近展开；
  /// 再次点当前项翻转升/降序（与其它页面同一套交互）。
  ///
  /// 用 TooltipVisibility 关掉按钮说明气泡：播放器详情页统一不弹按钮说明。
  /// IconTheme / IgnorePointer 保留原 PopupMenuButton 的两点语义：
  /// 图标取色（常态 colors.action、队列为空置灰）与队列为空时不可点。
  Widget _buildSortMenu(
    PlayerProvider playerProvider,
    bool enabled,
    _PanelColors colors,
  ) {
    return IconTheme(
      data: IconThemeData(color: enabled ? colors.action : colors.disabled),
      child: IgnorePointer(
        ignoring: !enabled,
        child: TooltipVisibility(
          visible: false,
          child: M3ESortButton<PlaylistSortBy>(
            tooltip: '排序',
            icon: Icons.swap_vert,
            current: _sortBy,
            options: const [
              (value: PlaylistSortBy.queue, label: '播放顺序'),
              (value: PlaylistSortBy.title, label: '标题'),
              (value: PlaylistSortBy.duration, label: '时长'),
            ],
            onPicked: (value, repeated) =>
                _onSortSelected(value, playerProvider, repeated: repeated),
          ),
        ),
      ),
    );
  }

  /// 歌曲列表：与评论区一致的上下边界 alpha 渐变；
  /// 拖拽把手只在编辑模式出现（buildDefaultDragHandles=false）。
  ///
  /// 用 m3e_core 的 [M3EReorderableDismissibleList] 取代 ReorderableListView：
  /// 保留长按拖拽重排与「从左向右」滑动删除（反向不响应，避免误触）；
  /// 编辑模式下不接受滑动删除，批量删除走编辑模式「全选 → 删除」。
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
      child: M3EReorderableDismissibleList(
        itemCount: playlist.length,
        scrollController: _scrollController,
        // key 由 M3E 内部用 KeyedSubtree 套用，保证重排 / 滑删后列表项状态稳定
        keyBuilder: (index) => ValueKey(playlist[index].id),
        // 关闭 M3E 自带的把手图标：本项目在编辑模式用行内自定义把手
        buildDefaultDragHandles: false,
        // 队列项自带 ListTile 底色与波纹，因此去掉 M3E 卡片的背景 / 圆角 / 间距 /
        // 内边距，避免出现双层圆角与双重背景
        style: const M3EDismissibleCardStyle(
          outerRadius: 0,
          innerRadius: 0,
          gap: 0,
          padding: EdgeInsets.zero,
          color: Colors.transparent,
          // 只允许「从左向右」滑动删除：反向（从右向左）不响应，避免误触。
          // startToEnd = 从左向右；endToStart = 从右向左；none = 完全禁用。
          // 注意不能靠「不传 onDismiss」来禁用——上游是
          // `onDismissCallback?.call(...) ?? true`，不传回调等于默认放行。
          direction: DismissDirection.startToEnd,
        ),
        // 浮层：原 proxyDecorator 只做半透明、不加底色与阴影，这里等价处理
        dragElevation: 0,
        dragPlaceholderColor: Colors.transparent,
        onDismiss: (index, direction) async {
          // 编辑模式（多选）下不接受滑动删除：返回 false 让 M3E 回弹，
          // 避免与「点整行切换勾选」的手势语义冲突
          if (_editMode) return false;
          // 删除当前播放歌曲的索引校正由 removeFromPlaylist 内部负责
          await playerProvider.removeFromPlaylist(index);
          return true;
        },
        onReorder: (oldIndex, newIndex) {
          // M3E 的 newIndex 语义与 ReorderableListView 完全一致（均以「移除前」
          // 的插入位传参，源码里 to > from 时补 +1），因此直接沿用原调用，
          // 由 reorderPlaylist 内部继续做 `if (oldIndex < newIndex) newIndex -= 1`
          playerProvider.reorderPlaylist(oldIndex, newIndex);
        },
        itemBuilder: (context, index) => _buildItem(
          index: index,
          song: playlist[index],
          isCurrent: index == data.currentIndex,
          isPlaying: data.isPlaying,
          playerProvider: playerProvider,
          colors: colors,
        ),
        emptyBuilder: (context) => Center(
          child: Text(
            '播放列表为空',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.secondary),
          ),
        ),
      ),
    );
  }

  /// 单个列表项。
  ///
  /// 常态：封面 + 标题/艺人 + 正在播放的频谱标识；点击切歌，长按进编辑模式。
  /// 编辑模式：封面左侧插入圆形复选框（封面保持可见）、右侧换成拖拽把手；
  /// 点击整行切换勾选。
  Widget _buildItem({
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
    return _HoldToEditDetector(
      // 编辑模式下由 M3E 的整项长按拖拽负责重排，不再重复处理长按
      enabled: !_editMode,
      onHold: () => _enterEditMode(song.id),
      child: Material(
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
          trailing: _buildTrailing(isCurrent, isPlaying, colors),
          onTap: () {
            if (_editMode) {
              _toggleSelection(song.id);
            } else {
              // 点击切歌（不关闭面板，留在容器）
              playerProvider.playSongAt(index);
            }
          },
        ),
      ),
    );
  }

  /// 行尾：编辑模式给拖拽把手，常态给「正在播放」的三柱波形
  Widget _buildTrailing(bool isCurrent, bool isPlaying, _PanelColors colors) {
    if (_editMode) {
      // M3E 的重排手势挂在整项上（长按后拖动），无法从自定义把手接入，
      // 因此把手保留为编辑模式的视觉标识，实际拖拽由整项长按触发
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(Icons.drag_handle, color: colors.handle),
      );
    }
    if (isCurrent) {
      // 歌单同款三柱起伏波形（暂停时 ticker 停止保留最后一帧）
      // 波形是「正在播放」的唯一视觉信号，读屏下补文字标签
      return Semantics(
        label: '正在播放',
        child: PlayingSpectrumIndicator(
          color: colors.spectrum,
          size: 14,
          isPlaying: isPlaying,
        ),
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

/// 「长按进入编辑模式」的长按检测。
///
/// [M3EReorderableDismissibleList] 的整项重排手势是 200ms 延迟的
/// [DelayedMultiDragGestureRecognizer]：按住 200ms 未移动它会直接
/// `resolve(accepted)` 夺走手势竞技场（见 Flutter `multidrag.dart` 的
/// `_DelayedPointerState._delayPassed`），使得同一竞技场里的
/// `ListTile.onLongPress` 永远不会触发。这里用不参与竞技场的 [Listener]
/// 自行计时长按，保持原有的「长按进入编辑模式」行为。
///
/// tv: 长按进入编辑模式（含拖拽重排）不适用——纯指针按住/拖拽手势，
/// TV 上无按键等价；播放队列行本身是 ListTile（原生可聚焦，OK=切歌），
/// 阅读与切歌主路径不受影响。
class _HoldToEditDetector extends StatefulWidget {
  const _HoldToEditDetector({
    required this.enabled,
    required this.onHold,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onHold;
  final Widget child;

  @override
  State<_HoldToEditDetector> createState() => _HoldToEditDetectorState();
}

class _HoldToEditDetectorState extends State<_HoldToEditDetector> {
  /// 与 Flutter 的 kLongPressTimeout / kTouchSlop 取值保持一致
  static const Duration _holdDuration = Duration(milliseconds: 500);
  static const double _slop = 18.0;

  Timer? _timer;
  Offset _origin = Offset.zero;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (!widget.enabled) return;
        _origin = event.position;
        _cancel();
        _timer = Timer(_holdDuration, () {
          if (mounted) widget.onHold();
        });
      },
      // 位移超过 touch slop 说明是拖拽 / 滚动，不再算长按
      onPointerMove: (event) {
        if (_timer == null) return;
        if ((event.position - _origin).distance > _slop) _cancel();
      },
      onPointerUp: (_) => _cancel(),
      onPointerCancel: (_) => _cancel(),
      child: widget.child,
    );
  }
}
