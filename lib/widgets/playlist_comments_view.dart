import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../core/utils/app_toast.dart';
import '../providers/kugou_provider.dart';
import '../providers/comment_display_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';
import '../services/kugou_api/comment_reply_target.dart';
import '../services/kugou_api/comment_send_result.dart';
import '../services/kugou_api/comment_sort.dart';
import '../modules/login/login_page.dart';
import 'comment_composer.dart';
import 'comment_image_grid.dart';
import 'comment_image_viewer.dart';

/// 楼层评论状态
class _FloorState {
  bool expanded = false;
  bool loading = false;
  bool initialized = false;
  List<KugouComment> replies = [];
  int total = 0;
  int page = 1;
  bool hasMore = true;
  String message = '';
}

/// 歌单/专辑评论列表视图。
///
/// 在 PlaylistPage / AlbumDetailPage 中展示评论。
///
/// **功能**：
/// - 歌手评论/歌手评论置顶展示，带徽章标识
/// - 楼层评论（楼中楼），点击"查看N条回复"展开
/// - 长评论展开/收起（超过 120 字）
/// - 点赞数格式化（10000+ → "1w"）
/// - 滚动到底部自动加载下一页
class PlaylistCommentsView extends StatefulWidget {
  final String specialId;

  /// 评论类型：'playlist' 或 'album'
  final String commentType;

  /// 外部传入的 ScrollController（如 DraggableScrollableSheet），
  /// 传入后评论列表使用该 controller，使外部可控制滚动。
  final ScrollController? scrollController;

  const PlaylistCommentsView({
    super.key,
    required this.specialId,
    this.commentType = 'playlist',
    this.scrollController,
  });

  @override
  State<PlaylistCommentsView> createState() => _PlaylistCommentsViewState();
}

class _PlaylistCommentsViewState extends State<PlaylistCommentsView> {
  List<KugouComment> _comments = [];
  List<KugouComment> _hotComments = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = true;
  ScrollController? _internalScrollController;

  /// 长评论展开状态
  final Set<String> _expandedContents = {};

  /// 楼层评论状态（按评论 ID 索引）
  final Map<String, _FloorState> _floorStates = {};

  /// 当前回复目标（非空即输入框处于回复模式）。
  CommentReplyTarget? _replyTarget;

  /// 评论排序方式（默认最热）。切换后重新拉取第一页。
  CommentSortMode _sortMode = CommentSortMode.hottest;

  /// 分段按钮/分区标题当前**展示**的排序。淡出期间保持旧值，
  /// 与新数据一起淡入时才切到新模式，避免「按钮先切好、列表后跟上」的割裂感。
  CommentSortMode _displayedSortMode = CommentSortMode.hottest;

  /// 切换排序时的淡出/淡入时长。
  static const Duration _sortFadeDuration = Duration(milliseconds: 200);

  /// 正在切换排序（旧列表淡出、新数据拉取中）。
  bool _switchingSort = false;

  /// 评论发送在途：禁用输入框，防止连点造成重复公开评论。
  bool _sendingComment = false;

  /// 评论项 GlobalKey（按评论 ID 索引），用于收起楼中楼后定位滚动
  final Map<String, GlobalKey> _commentItemKeys = {};

  GlobalKey _keyForComment(String id) =>
      _commentItemKeys.putIfAbsent(id, () => GlobalKey());

  /// 收起滚动操作序号：每次收起自增，异步滚动前校验，只允许最新一次生效，
  /// 避免多个收起操作并发时滚动互相干扰。
  int _collapseScrollSeq = 0;

  ScrollController get _scrollController =>
      widget.scrollController ?? _internalScrollController!;

  @override
  void initState() {
    super.initState();
    if (widget.scrollController == null) {
      _internalScrollController = ScrollController();
    }
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchComments();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _internalScrollController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PlaylistCommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.specialId != widget.specialId) {
      _currentPage = 1;
      _hasMore = true;
      _comments.clear();
      _hotComments.clear();
      _expandedContents.clear();
      _floorStates.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchComments();
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _fetchComments({bool silent = false}) async {
    if (widget.specialId.isEmpty) return;

    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    final kugouProvider = context.read<KugouProvider>();
    KugouCommentList? result;
    if (widget.commentType == 'album') {
      result = await kugouProvider.getAlbumComments(widget.specialId, page: 1);
    } else {
      result = await kugouProvider.getPlaylistComments(
        widget.specialId,
        page: 1,
      );
    }

    // 静默刷新失败（拿不到数据）时保留现有列表，不切错误页
    if (silent && result == null) return;

    if (mounted) {
      setState(() {
        _isLoading = false;
        if (result != null) {
          _comments = result.comments;
          _hotComments = result.hotComments;
          _currentPage = 1;
          _hasMore = result.comments.length >= 20;
        } else {
          _comments = [];
          _hotComments = [];
          _hasMore = false;
        }
        _error = kugouProvider.error;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _isLoading) return;

    setState(() => _isLoadingMore = true);

    final kugouProvider = context.read<KugouProvider>();
    KugouCommentList? result;
    if (widget.commentType == 'album') {
      result = await kugouProvider.getAlbumComments(
        widget.specialId,
        page: _currentPage + 1,
      );
    } else {
      result = await kugouProvider.getPlaylistComments(
        widget.specialId,
        page: _currentPage + 1,
      );
    }

    if (mounted) {
      setState(() {
        _isLoadingMore = false;
        if (result != null && result.comments.isNotEmpty) {
          _comments.addAll(result.comments);
          _currentPage++;
          _hasMore = result.comments.length >= 20;
        } else {
          _hasMore = false;
        }
      });
    }
  }

  // ---- 长评论展开/收起 ----

  bool _needsTruncate(String content) {
    return content.length > 120;
  }

  void _toggleContent(String id) {
    setState(() {
      if (_expandedContents.contains(id)) {
        _expandedContents.remove(id);
      } else {
        _expandedContents.add(id);
      }
    });
  }

  // ---- 楼层评论 ----

  _FloorState _getFloorState(String commentId) {
    return _floorStates.putIfAbsent(commentId, () => _FloorState());
  }

  Future<void> _fetchFloorReplies(
    KugouComment comment, {
    bool reset = false,
    bool silent = false,
  }) async {
    final state = _getFloorState(comment.id);
    if (state.loading) return;
    if (!state.hasMore && !reset) return;

    if (reset) {
      state.page = 1;
      state.replies = [];
      state.hasMore = true;
      state.message = '';
    }

    if (!silent) setState(() => state.loading = true);

    final specialId = comment.specialId ?? '';
    final tid = comment.tid ?? comment.id;

    if (specialId.isEmpty || tid.isEmpty) {
      state.message = '楼层评论暂不可用';
      state.hasMore = false;
      if (mounted) setState(() => state.loading = false);
      return;
    }

    try {
      final api = KugouApiClient();
      final result = await api.getFloorComments(
        specialId: specialId,
        tid: tid,
        mixSongId: comment.mixSongId,
        code: comment.code,
        page: state.page,
      );

      if (result != null) {
        final replies = result.comments;
        state.replies = reset ? replies : [...state.replies, ...replies];
        state.total = result.total;
        state.hasMore = state.total > 0
            ? state.replies.length < state.total
            : replies.length >= 30;
        if (state.hasMore) state.page++;
        if (state.replies.isEmpty) {
          state.message = '暂无回复';
        }
      } else {
        state.message = '楼层评论暂不可用';
        state.hasMore = false;
      }
    } catch (_) {
      state.message = '加载失败，点击重试';
    } finally {
      state.initialized = true;
      if (mounted) {
        if (!silent) setState(() => state.loading = false);
      }
    }
  }

  void _toggleFloor(KugouComment comment) {
    final state = _getFloorState(comment.id);
    final wasExpanded = state.expanded;
    // 收起前记录评论项顶部相对视口的位置与滚动偏移，供收起后精确定位。
    // 此时楼中楼仍在展开、评论项通常未被懒加载回收，位置可可靠读取。
    // 用局部变量随本次收起一起传递，避免多个评论项收起时相互覆盖。
    final double? recorded = wasExpanded
        ? _commentTopInViewport(comment.id)
        : null;
    final double? beforeOffset =
        wasExpanded && _scrollController.hasClients
        ? _scrollController.offset
        : null;
    final int seq = wasExpanded ? ++_collapseScrollSeq : _collapseScrollSeq;
    setState(() {
      if (!state.expanded) {
        state.expanded = true;
        if (!state.initialized) {
          _fetchFloorReplies(comment, reset: true);
        }
      } else {
        state.expanded = false;
      }
    });
    // 收起楼中楼后，若楼主评论已超出视口则自然滚动回其位置
    if (wasExpanded && !state.expanded) {
      _scrollToCommentAfterCollapse(comment.id, seq, recorded, beforeOffset);
    }
  }

  Future<bool> _submitComment(String text) async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (mounted) await _promptLogin();
      return false;
    }

    final target = _replyTarget;
    setState(() => _sendingComment = true);
    try {
      final CommentSendResult result;
      if (target == null) {
        result = widget.commentType == 'album'
            ? await api.sendAlbumComment(id: widget.specialId, content: text)
            : await api.sendPlaylistComment(id: widget.specialId, content: text);
      } else {
        final args = buildFloorReplyArgs(
          target,
          fallbackSpecialId: widget.specialId,
        );
        result = await api.sendFloorReply(
          specialId: args.specialId,
          tid: args.tid,
          content: text,
          resourceType: widget.commentType,
          code: target.top.code,
          pid: args.pid,
          replyUserName: args.replyUserName,
          replyContent: args.replyContent,
        );
      }

      if (!mounted) return result.ok;
      if (result.ok) {
        setState(() => _replyTarget = null);
        if (target == null) {
          await _fetchComments(silent: true);
        } else {
          _getFloorState(target.top.id).expanded = true;
          await _fetchFloorReplies(target.top, reset: true, silent: true);
        }
        if (mounted) showToast('评论已提交，审核通过后展示');
      } else {
        showToast(result.message, long: true);
      }
      return result.ok;
    } finally {
      if (mounted) setState(() => _sendingComment = false);
    }
  }

  /// 未登录时引导登录（与 channel_page 的既有交互保持一致）。
  Future<void> _promptLogin() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请先登录'),
        content: const Text('发表评论需要登录账号，是否前往登录？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('去登录')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (mounted) setState(() {});
  }

  /// 计算评论项顶部相对视口顶部的偏移（负数表示在视口上方）。
  double? _commentTopInViewport(String commentId) {
    final rb = _keyForComment(commentId).currentContext?.findRenderObject();
    if (rb is! RenderBox || !rb.attached) return null;
    final viewport = RenderAbstractViewport.of(rb) as RenderBox;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    return rb.localToGlobal(Offset.zero).dy - viewportTop;
  }

  /// 收起楼中楼后把视口自然滚动回楼主评论位置。
  ///
  /// 用收起前记录的评论项顶部位置计算目标滚动偏移（不依赖评论项是否仍
  /// 在 widget 树中），等待 [AnimatedSize] 收缩动画结束、布局稳定后滚动，
  /// 滚动后再校准，确保评论项顶部对齐视口顶部。
  /// [seq] 为本次收起操作的序号，异步期间若又有新的收起操作则放弃本次，
  /// 避免多个收起并发滚动互相干扰。
  Future<void> _scrollToCommentAfterCollapse(
    String commentId,
    int seq,
    double? recorded,
    double? beforeOffset,
  ) async {
    // 等待 AnimatedSize 收缩动画结束、布局稳定
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || seq != _collapseScrollSeq) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || seq != _collapseScrollSeq) return;
    final controller = _scrollController;
    if (!controller.hasClients) return;
    if (recorded == null || beforeOffset == null) return;
    // 评论项顶部已在视口内则不滚动
    if (recorded >= 0) return;
    // 评论项顶部在滚动内容中的位置（收起前后不变）
    final target = (beforeOffset + recorded)
        .clamp(0.0, controller.position.maxScrollExtent);
    // 滚动 + 校准：一次滚动可能因列表高度收缩没完全到位，滚动后再测量校准
    for (int attempt = 0; attempt < 3; attempt++) {
      if (seq != _collapseScrollSeq) return;
      if ((target - controller.offset).abs() < 1.0) break;
      await controller.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
  }

  // ---- 工具方法 ----

  String _formatLike(int value) {
    if (value < 10000) return value.toString();
    final fixed = (value / 10000).toStringAsFixed(value >= 100000 ? 0 : 1);
    return '${fixed.replaceAll(RegExp(r'\.0$'), '')}w';
  }

  String? _fixAvatarUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  String _formatTime(int timestamp) {
    if (timestamp == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}.$month.$day';
  }

  /// 切换排序：旧的先淡出，数据换好后再淡入，避免整块生硬地消失又出现。
  Future<void> _onSortModeChanged(CommentSortMode mode) async {
    if (mode == _sortMode || _switchingSort) return;
    setState(() {
      _sortMode = mode;
      _switchingSort = true;
    });
    await Future.delayed(_sortFadeDuration);
    if (!mounted) return;
    _currentPage = 1;
    _hasMore = true;
    _comments.clear();
    _hotComments.clear();
    await _fetchComments(silent: true);
    if (!mounted) return;
    // 数据就绪后同一帧切按钮高亮与标题，与新列表一起淡入
    setState(() {
      _displayedSortMode = mode;
      _switchingSort = false;
    });
  }

  /// 排序选择器（m3e_core 分段按钮）。
  Widget _buildSortSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: M3EToggleButtonGroup(
        actions: const [
          M3EToggleButtonGroupAction(label: Text('最热')),
          M3EToggleButtonGroupAction(label: Text('最新')),
          M3EToggleButtonGroupAction(label: Text('最早')),
        ],
        size: M3EButtonSize.xs,
        density: M3EButtonGroupDensity.compact,
        selectedIndex: _displayedSortMode.index,
        onSelectedIndexChanged: (index) {
          if (index == null) return;
          _onSortModeChanged(CommentSortMode.values[index]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 排序选择器常驻在外层：切换排序时列表淡出淡入，入口控件不跟着消失。
    return Column(
      children: [
        _buildSortSelector(),
        Expanded(
          child: AnimatedOpacity(
            opacity: _switchingSort ? 0 : 1,
            duration: _sortFadeDuration,
            curve: Curves.easeOut,
            child: _buildBody(),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final display = context.watch<CommentDisplayProvider>();
    final commentFontSize = display.commentFontSize;
    final replyFontSize = display.commentReplyFontSize;

    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading && _comments.isEmpty && _hotComments.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: M3ELoadingIndicator(),
        ),
      );
    }

    if (_error != null && _comments.isEmpty && _hotComments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 40,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                '加载评论失败',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: _fetchComments, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_comments.isEmpty && _hotComments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.comment_outlined,
                size: 40,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                '暂无评论',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 构建显示列表：歌手评论 + 最新评论。
    // 主列表里也可能带 isStar 的歌手评论，而「歌手评论」栏只来自
    // star_cmts/hot_list，不一定包含它（可能为空）。统一把主列表里的歌手
    // 评论补进「歌手评论」栏（按 id 去重），并从主列表移除。
    final hotFromComments = _comments.where((c) => c.isStar).toList();
    // 歌单/专辑的 cmtlist 上游是加权混排，排序全部在客户端做
    final regularComments = sortCommentsForDisplay(
      _comments.where((c) => !c.isStar).toList(),
      _sortMode,
    );
    final mainSectionLabel = switch (_displayedSortMode) {
      CommentSortMode.hottest => '最热评论',
      CommentSortMode.timeDesc => '最新评论',
      CommentSortMode.timeAsc => '最早评论',
    };
    final starFromHot = _hotComments.where((c) => c.isStar).toSet();
    final singerComments = <KugouComment>[
      ..._hotComments,
      for (final c in hotFromComments)
        if (!starFromHot.any((s) => s.id == c.id)) c,
    ];

    final displayItems = <_CommentDisplayItem>[];

    if (singerComments.isNotEmpty) {
      displayItems.add(_CommentDisplayItem.header('歌手评论'));
      for (final c in singerComments) {
        displayItems.add(_CommentDisplayItem.comment(c));
      }
    }
    if (regularComments.isNotEmpty) {
      displayItems.add(_CommentDisplayItem.header(mainSectionLabel));
      for (final c in regularComments) {
        displayItems.add(_CommentDisplayItem.comment(c));
      }
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: displayItems.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == displayItems.length) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _isLoadingMore
                        ? const M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24))
                        : TextButton(onPressed: _loadMore, child: const Text('加载更多')),
                  ),
                );
              }

              final item = displayItems[index];
              if (item.isHeader) {
                return _buildSectionHeader(item.headerTitle!, colorScheme);
              }
              return _buildCommentItem(
                item.comment!,
                colorScheme,
                commentFontSize,
                replyFontSize,
              );
            },
          ),
        ),
        CommentComposer(
          sending: _sendingComment,
          // 本组件只出现在 DraggableScrollableSheet 弹层里（歌单页 / 专辑页），
          // 弹层不会随键盘上移 → 输入框必须自己避让，否则被输入法遮挡
          avoidKeyboard: true,
          replyToName: _replyTarget?.displayName,
          onCancelReply: () => setState(() => _replyTarget = null),
          onSubmit: _submitComment,
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildCommentItem(
    KugouComment comment,
    ColorScheme colorScheme,
    double commentFontSize,
    double replyFontSize,
  ) {
    final floorState = _floorStates[comment.id];
    return Padding(
      key: _keyForComment(comment.id),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(comment, colorScheme),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 用户名 + 徽章 + 时间
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.username,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (comment.isStar) ...[
                      const SizedBox(width: 6),
                      _buildBadge('歌手', colorScheme),
                    ],
                    if (comment.isHot) ...[
                      const SizedBox(width: 6),
                      _buildBadge('热门', colorScheme),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      _formatTime(comment.time),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 评论内容（长评论展开/收起，带动画）
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topLeft,
                  child: _buildContent(comment, colorScheme, commentFontSize),
                ),
                if (comment.images.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  CommentImageGrid(
                    images: comment.images,
                    onTapImage: (index) => showCommentImageViewer(
                      context,
                      images: comment.images,
                      initialIndex: index,
                    ),
                  ),
                ],
                // 点赞 + 回复
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (comment.likes > 0) ...[
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 12,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatLike(comment.likes),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ],
                    // 回复按钮
                    if (comment.replyCount > 0) ...[
                      const SizedBox(width: 16),
                      GestureDetector(
                        onTap: () => _toggleFloor(comment),
                        child: Row(
                          children: [
                            AnimatedRotation(
                              turns: floorState?.expanded == true ? 0.5 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.expand_more,
                                size: 14,
                                color: colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              floorState?.expanded == true
                                  ? '收起回复'
                                  : '查看${comment.replyCount}条回复',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colorScheme.primary),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _replyTarget = CommentReplyTarget(top: comment));
                      },
                      child: Row(
                        children: [
                          Icon(Icons.reply, size: 14, color: colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            '回复',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: colorScheme.primary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // 楼层评论（带展开动画）
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topLeft,
                  child: floorState?.expanded == true
                      // 左侧竖条收纳按钮 + 楼中楼内容
                      ? IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildFloorCollapseHandle(
                                onTap: () => _toggleFloor(comment),
                                lineColor: colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.28),
                                iconColor: colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildFloorReplies(
                                  comment,
                                  floorState!,
                                  colorScheme,
                                  replyFontSize,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    KugouComment comment,
    ColorScheme colorScheme,
    double fontSize,
  ) {
    final content = comment.content;
    if (!_needsTruncate(content) || _expandedContents.contains(comment.id)) {
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: content,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                height: 1.4,
                fontSize: fontSize,
              ),
            ),
            if (_needsTruncate(content) &&
                _expandedContents.contains(comment.id))
              WidgetSpan(
                child: GestureDetector(
                  onTap: () => _toggleContent(comment.id),
                  child: Text(
                    ' 收起',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '${content.substring(0, 120)}...',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              height: 1.4,
              fontSize: fontSize,
            ),
          ),
          WidgetSpan(
            child: GestureDetector(
              onTap: () => _toggleContent(comment.id),
              child: Text(
                '展开',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String text, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colorScheme.primary,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 楼中楼左侧的竖条收纳按钮。
  ///
  /// 一条与楼中楼等高的竖线 + 底部向上箭头，整条可点击收起楼中楼，
  /// 方便在楼中楼较长时无需滚回顶部即可收纳。仅在展开楼中楼时渲染。
  Widget _buildFloorCollapseHandle({
    required VoidCallback onTap,
    required Color lineColor,
    required Color iconColor,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 20,
        child: Column(
          children: [
            // 顶部圆点：与右侧楼中楼矩形顶部（margin top 10）对齐
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: lineColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            // 竖线：从圆点下方延伸到楼中楼底部
            Expanded(
              child: Container(
                width: 2,
                margin: const EdgeInsets.only(top: 3),
                decoration: BoxDecoration(
                  color: lineColor,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
            // 底部收纳图标
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(
                Icons.keyboard_arrow_up,
                size: 16,
                color: iconColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloorReplies(
    KugouComment comment,
    _FloorState state,
    ColorScheme colorScheme,
    double replyFontSize,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 回复列表
          for (final reply in state.replies)
            _buildFloorReplyItem(comment, reply, colorScheme, replyFontSize, comment.username),
          // 加载中
          if (state.loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: M3ELoadingIndicator(
                  constraints: BoxConstraints.tightFor(width: 16, height: 16),
                  color: colorScheme.primary,
                ),
              ),
            ),
          // 空状态
          if (!state.loading && state.initialized && state.replies.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  state.message.isNotEmpty ? state.message : '暂无回复',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          // 加载更多
          if (state.hasMore && !state.loading && state.replies.isNotEmpty)
            Center(
              child: GestureDetector(
                onTap: () => _fetchFloorReplies(comment),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    state.message.contains('失败') ? '加载失败，点击重试' : '加载更多回复',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          // 全部加载完
          if (!state.hasMore && !state.loading && state.replies.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '已加载全部回复',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 清理楼中楼回复的引用后缀。
  ///
  /// 酷狗楼中楼回复内容形如「回复正文//@被回复用户名:被回复内容」。
  /// 仅当被回复用户是楼主（[ownerName]）时去掉引用后缀、只显示回复正文；
  /// 楼中楼用户互相回复时保留引用，便于看出回复对象。
  String _cleanFloorReplyContent(String content, String ownerName) {
    final idx = content.lastIndexOf('//@');
    if (idx <= 0) return content;
    final ref = content.substring(idx + 3);
    final colon = ref.indexOf(':');
    if (colon <= 0) return content;
    if (ref.substring(0, colon).trim() != ownerName) return content;
    final text = content.substring(0, idx).trim();
    return text.isEmpty ? content : text;
  }

  Widget _buildFloorReplyItem(
    KugouComment top,
    KugouComment reply,
    ColorScheme colorScheme,
    double fontSize,
    String ownerName,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSmallAvatar(reply, colorScheme),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        reply.username,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatTime(reply.time),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _cleanFloorReplyContent(reply.content, ownerName),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface,
                    height: 1.3,
                    fontSize: fontSize,
                  ),
                ),
                if (reply.images.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  CommentImageGrid(
                    images: reply.images,
                    onTapImage: (index) => showCommentImageViewer(
                      context,
                      images: reply.images,
                      initialIndex: index,
                    ),
                  ),
                ],
                // 楼中楼：回复某条具体回复（pid=该回复，is_t=0）
                const SizedBox(height: 2),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _replyTarget =
                        CommentReplyTarget(top: top, reply: reply));
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.reply, size: 12, color: colorScheme.primary),
                      const SizedBox(width: 3),
                      Text(
                        '回复',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.primary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建评论用户头像。
  /// 优先使用 API 返回的头像 URL，加载失败或无头像时回退到首字母圆形头像。
  Widget _buildAvatar(KugouComment comment, ColorScheme colorScheme) {
    final avatarUrl = _fixAvatarUrl(comment.avatar);

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 18,
        backgroundColor: colorScheme.primary.withValues(alpha: 0.15),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: avatarUrl,
            memCacheWidth: 108,
            memCacheHeight: 108,
            width: 36,
            height: 36,
            fit: BoxFit.cover,
            placeholder: (_, _) => _buildTextAvatar(comment, colorScheme),
            errorWidget: (_, _, _) => _buildTextAvatar(comment, colorScheme),
          ),
        ),
      );
    }

    return _buildTextAvatar(comment, colorScheme);
  }

  Widget _buildSmallAvatar(KugouComment comment, ColorScheme colorScheme) {
    final avatarUrl = _fixAvatarUrl(comment.avatar);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 12,
        backgroundColor: colorScheme.primary.withValues(alpha: 0.15),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: avatarUrl,
            memCacheWidth: 72,
            memCacheHeight: 72,
            width: 24,
            height: 24,
            fit: BoxFit.cover,
            placeholder: (_, _) => _buildSmallTextAvatar(comment, colorScheme),
            errorWidget: (_, _, _) =>
                _buildSmallTextAvatar(comment, colorScheme),
          ),
        ),
      );
    }
    return _buildSmallTextAvatar(comment, colorScheme);
  }

  Widget _buildTextAvatar(KugouComment comment, ColorScheme colorScheme) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: colorScheme.primary.withValues(alpha: 0.15),
      child: Text(
        comment.username.isNotEmpty ? comment.username[0] : '?',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
      ),
    );
  }

  Widget _buildSmallTextAvatar(KugouComment comment, ColorScheme colorScheme) {
    return CircleAvatar(
      radius: 12,
      backgroundColor: colorScheme.primary.withValues(alpha: 0.15),
      child: Text(
        comment.username.isNotEmpty ? comment.username[0] : '?',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colorScheme.primary,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// 显示列表项（header 或 comment）
class _CommentDisplayItem {
  final String? headerTitle;
  final KugouComment? comment;

  bool get isHeader => headerTitle != null;

  _CommentDisplayItem.header(this.headerTitle) : comment = null;
  _CommentDisplayItem.comment(this.comment) : headerTitle = null;
}
