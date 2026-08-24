import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/comment_display_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/comment_thread.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';

/// 统一的评论面板入口。
///
/// 将歌曲菜单「看评论」与「无法播放」弹窗中的评论入口合并为同一实现：
/// 使用 [DraggableScrollableSheet] 可拖拽调整高度，顶部为标题栏（歌名 + 关闭按钮），
/// 内容区为 [CommentsView]。
void showSongCommentsSheet(BuildContext context, Song song) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) => DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (innerCtx, scrollController) => Column(
        children: [
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(innerCtx).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '评论: ${song.displayName}',
                    style: Theme.of(innerCtx).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(innerCtx).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: CommentsView(
              songHash: song.id,
              albumAudioId: song.albumAudioId,
              artworkUri: song.artworkUri,
            ),
          ),
        ],
      ),
    ),
  );
}

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

/// 评论列表视图。
///
/// 在 FullPlayer 中作为 TabBarView 第三个 Tab 展示。
///
/// - AM 风格（[isAmStyle] = true）：背景为模糊封面 + 黑蒙版，统一白色文字。
/// - MD3 风格（[isAmStyle] = false，默认）：跟随莫奈色主题，用户名用主色调，
///   评论正文和时间戳根据深浅色模式自动适配。
///
/// **功能**：
/// - 歌手评论/歌手评论置顶展示，带徽章标识
/// - 歌曲评论按热度（点赞数）降序排列
/// - 楼层评论（楼中楼），点击"查看N条回复"展开；回复按时间倒序（新的在前），
///   对回复的回复按层级嵌套缩进
/// - 长评论展开/收起（超过 120 字或 3 行）
/// - 点赞数格式化（10000+ → "1w"）
/// - 滚动到底部自动加载下一页
class CommentsView extends StatefulWidget {
  final String songHash;
  final String? albumAudioId;

  /// 封面 URL（保留参数兼容性，不再用于智能反色）。
  final String? artworkUri;

  /// 是否为 AM 风格播放器。true 时使用白色文字方案，false 时跟随主题色。
  final bool isAmStyle;

  const CommentsView({
    super.key,
    required this.songHash,
    this.albumAudioId,
    this.artworkUri,
    this.isAmStyle = false,
  });

  @override
  State<CommentsView> createState() => _CommentsViewState();
}

class _CommentsViewState extends State<CommentsView> {
  /// 楼层评论每页条数。上游硬上限 50，取满可减少翻页次数，
  /// 让楼中楼的父子关系更早在同一批数据里凑齐。
  static const int _floorPageSize = 50;

  final ScrollController _scrollController = ScrollController();
  List<KugouComment> _comments = [];
  List<KugouComment> _hotComments = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = true;

  /// 评论区 id，「最热」接口必需，只能从 /comment/music 的响应里取。
  String _childrenId = '';

  /// 主评论列表是否走「最热」接口。拿不到评论区 id 或该接口失败时为 false，
  /// 此时退回 /comment/music 的默认顺序，翻页也必须继续用同一个接口，
  /// 否则两种排序的分页会混在一起。
  bool _useTopliked = false;

  /// 长评论展开状态
  final Set<String> _expandedContents = {};

  /// 楼层评论状态（按评论 ID 索引）
  final Map<String, _FloorState> _floorStates = {};

  /// 评论项 GlobalKey（按评论 ID 索引），用于收起楼中楼后定位滚动
  final Map<String, GlobalKey> _commentItemKeys = {};

  GlobalKey _keyForComment(String id) =>
      _commentItemKeys.putIfAbsent(id, () => GlobalKey());

  /// 收起滚动操作序号：每次收起自增，异步滚动前校验，只允许最新一次生效，
  /// 避免多个收起操作并发时滚动互相干扰。
  int _collapseScrollSeq = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchComments();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash) {
      _currentPage = 1;
      _hasMore = true;
      _childrenId = '';
      _useTopliked = false;
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

  Future<void> _fetchComments() async {
    if (widget.songHash.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final kugouProvider = context.read<KugouProvider>();
    final result = await kugouProvider.getComments(
      widget.songHash,
      albumAudioId: widget.albumAudioId,
      page: 1,
    );

    // 这一次 /comment/music 请求同时提供两样只有它才有的东西：歌手评论/精彩评论，
    // 以及「最热」接口必需的评论区 id。拿到 id 后再取按点赞降序的全局排名。
    final childrenId = result?.childrenId ?? '';
    final hot = childrenId.isEmpty
        ? null
        : await KugouApiClient().getToplikedComments(childrenId, page: 1);

    if (mounted) {
      setState(() {
        _isLoading = false;
        _childrenId = childrenId;
        // 「最热」拿不到时退回 cmtlist 的默认顺序，而不是对单页假排序：
        // 单页只是 4000+ 条里任意的 30 条，按点赞重排它并不等于热度排序。
        _useTopliked = hot != null && hot.comments.isNotEmpty;
        if (result != null) {
          _comments = _useTopliked
              ? sortCommentsByHotness(hot!.comments)
              : result.comments;
          _hotComments = result.hotComments;
          _currentPage = 1;
          _hasMore = _comments.length >= 20;
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
    final page = _currentPage + 1;
    final result = _useTopliked
        ? await KugouApiClient().getToplikedComments(_childrenId, page: page)
        : await kugouProvider.getComments(
            widget.songHash,
            albumAudioId: widget.albumAudioId,
            page: page,
          );

    if (mounted) {
      setState(() {
        _isLoadingMore = false;
        if (result != null && result.comments.isNotEmpty) {
          // 「最热」接口跨页整体降序，逐页稳定重排只修正页内的个别倒挂
          // （高热度歌曲的排名快照会滞后于实时点赞数），不会打乱已读的顺序。
          _comments.addAll(
            _useTopliked
                ? sortCommentsByHotness(result.comments)
                : result.comments,
          );
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

    setState(() => state.loading = true);

    final specialId = comment.specialId ?? '';
    final tid = comment.tid ?? comment.id;
    final mixSongId = comment.mixSongId ?? widget.albumAudioId;

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
        mixSongId: mixSongId?.isNotEmpty == true ? mixSongId : null,
        code: comment.code,
        page: state.page,
        pagesize: _floorPageSize,
      );

      if (result != null) {
        final replies = result.comments;
        state.replies = reset ? replies : [...state.replies, ...replies];
        if (result.total > 0) state.total = result.total;
        // 不足一页即到底（翻过末页时上游连 list 字段都不返回）。
        // 只按 total 判断是不够的：被删除或风控过滤的回复取不到，
        // 那样「加载更多回复」会永远停不下来。
        state.hasMore = replies.length >= _floorPageSize &&
            (state.total <= 0 || state.replies.length < state.total);
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
      if (mounted) setState(() => state.loading = false);
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
    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final diff = now.difference(date);

    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${date.month}月${date.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final display = context.watch<CommentDisplayProvider>();
    final commentFontSize = display.commentFontSize;
    final replyFontSize = display.commentReplyFontSize;

    final Color primaryTextColor;
    final Color secondaryTextColor;
    final Color usernameColor;

    if (widget.isAmStyle) {
      primaryTextColor = Colors.white;
      secondaryTextColor = const Color(0xB3FFFFFF);
      usernameColor = const Color(0xB3FFFFFF);
    } else {
      final colorScheme = Theme.of(context).colorScheme;
      primaryTextColor = colorScheme.onSurface;
      secondaryTextColor = colorScheme.onSurfaceVariant;
      usernameColor = colorScheme.primary;
    }

    // loading 指示器颜色：AM 风格保持白色，MD3 风格跟随莫奈色（primary）。
    final indicatorColor = widget.isAmStyle
        ? primaryTextColor
        : Theme.of(context).colorScheme.primary;

    if (_isLoading) {
      return Center(child: M3ELoadingIndicator(color: indicatorColor));
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: secondaryTextColor),
              const SizedBox(height: 12),
              Text(
                '加载评论失败',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: secondaryTextColor),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _fetchComments,
                style: TextButton.styleFrom(foregroundColor: primaryTextColor),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_comments.isEmpty && _hotComments.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.comment_outlined, size: 48, color: secondaryTextColor),
            const SizedBox(height: 12),
            Text(
              '暂无评论',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: secondaryTextColor),
            ),
          ],
        ),
      );
    }

    // 构建显示列表：歌手评论 + 全部评论
    final displayItems = <_CommentDisplayItem>[];

    if (_hotComments.isNotEmpty) {
      displayItems.add(_CommentDisplayItem.header('歌手评论'));
      for (final c in _hotComments) {
        displayItems.add(_CommentDisplayItem.comment(c));
      }
      if (_comments.isNotEmpty) {
        displayItems.add(
          _CommentDisplayItem.header(_useTopliked ? '最热评论' : '最新评论'),
        );
      }
    }
    for (final c in _comments) {
      displayItems.add(_CommentDisplayItem.comment(c));
    }

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
                    ? M3ELoadingIndicator(
                        constraints: BoxConstraints.tightFor(width: 24, height: 24),
                        color: indicatorColor)
                    : TextButton(
                        onPressed: _loadMore,
                        style: TextButton.styleFrom(
                          foregroundColor: primaryTextColor,
                        ),
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }

          final item = displayItems[index];
          if (item.isHeader) {
            return _buildSectionHeader(item.headerTitle!, primaryTextColor);
          }
          return _buildCommentItem(
            item.comment!,
            primaryTextColor,
            secondaryTextColor,
            usernameColor,
            commentFontSize,
            replyFontSize,
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildCommentItem(
    KugouComment comment,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
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
          _buildAvatar(comment, usernameColor),
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
                              color: usernameColor,
                              fontWeight: FontWeight.w500,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (comment.isStar) ...[
                      const SizedBox(width: 6),
                      _buildBadge('歌手', usernameColor),
                    ],
                    if (comment.isHot) ...[
                      const SizedBox(width: 6),
                      _buildBadge('热门', usernameColor),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      _formatTime(comment.time),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: secondaryTextColor.withValues(alpha: 0.6),
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
                  child: _buildContent(
                    comment,
                    primaryTextColor,
                    secondaryTextColor,
                    commentFontSize,
                  ),
                ),
                // 点赞 + 回复
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (comment.likes > 0) ...[
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 12,
                        color: secondaryTextColor.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatLike(comment.likes),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: secondaryTextColor.withValues(alpha: 0.5),
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
                                color: usernameColor,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              floorState?.expanded == true
                                  ? '收起回复'
                                  : '查看${comment.replyCount}条回复',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: usernameColor),
                            ),
                          ],
                        ),
                      ),
                    ],
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
                                lineColor: secondaryTextColor.withValues(
                                  alpha: 0.28,
                                ),
                                iconColor: usernameColor,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildFloorReplies(
                                  comment,
                                  floorState!,
                                  primaryTextColor,
                                  secondaryTextColor,
                                  usernameColor,
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
    Color primaryTextColor,
    Color secondaryTextColor,
    double fontSize,
  ) {
    final content = comment.content;
    if (!_needsTruncate(content) || _expandedContents.contains(comment.id)) {
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: content,
              style: TextStyle(
                color: primaryTextColor,
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
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: secondaryTextColor),
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
            style: TextStyle(
              color: primaryTextColor,
              height: 1.4,
              fontSize: fontSize,
            ),
          ),
          WidgetSpan(
            child: GestureDetector(
              onTap: () => _toggleContent(comment.id),
              child: Text(
                '展开',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: secondaryTextColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
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
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double replyFontSize,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: secondaryTextColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 回复列表：按 pid 嵌套，同层按时间倒序（新的在前）
          for (final node in buildReplyTree(state.replies))
            _buildFloorReplyItem(
              node,
              primaryTextColor,
              secondaryTextColor,
              usernameColor,
              replyFontSize,
            ),
          // 加载中
          if (state.loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: M3ELoadingIndicator(
                    constraints: BoxConstraints.tightFor(width: 16, height: 16),
                    color: usernameColor),
              ),
            ),
          // 空状态
          if (!state.loading && state.initialized && state.replies.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  state.message.isNotEmpty ? state.message : '暂无回复',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: secondaryTextColor),
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
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: usernameColor),
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
                    color: secondaryTextColor.withValues(alpha: 0.5),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 楼中楼嵌套的每级缩进量与最大缩进级数。
  ///
  /// 层级很深时继续缩进会把正文挤成窄条，超过 [_maxReplyIndentDepth] 级后
  /// 不再增加缩进，只靠排列顺序体现从属关系。
  static const double _replyIndentPerDepth = 16.0;
  static const int _maxReplyIndentDepth = 4;

  Widget _buildFloorReplyItem(
    CommentReplyNode node,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double fontSize,
  ) {
    final reply = node.reply;
    // 嵌套渲染后被回复的那条就在上方，引用后缀是重复信息；父级不在已加载数据
    // 里（孤儿）时保留原文，否则看不出在回复谁。
    final content = node.isOrphan
        ? reply.content
        : stripReplyQuote(reply.content);
    return Padding(
      padding: EdgeInsets.only(
        top: 6,
        bottom: 6,
        left:
            node.depth.clamp(0, _maxReplyIndentDepth) * _replyIndentPerDepth,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSmallAvatar(reply, usernameColor),
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
                          color: usernameColor,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatTime(reply.time),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: secondaryTextColor.withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  content,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: primaryTextColor,
                    height: 1.3,
                    fontSize: fontSize,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(KugouComment comment, Color usernameColor) {
    final avatarUrl = _fixAvatarUrl(comment.avatar);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 18,
        backgroundColor: usernameColor.withValues(alpha: 0.15),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: avatarUrl,
            memCacheWidth: 108,
            memCacheHeight: 108,
            width: 36,
            height: 36,
            fit: BoxFit.cover,
            placeholder: (_, _) => _buildTextAvatar(comment, usernameColor),
            errorWidget: (_, _, _) => _buildTextAvatar(comment, usernameColor),
          ),
        ),
      );
    }
    return _buildTextAvatar(comment, usernameColor);
  }

  Widget _buildSmallAvatar(KugouComment comment, Color usernameColor) {
    final avatarUrl = _fixAvatarUrl(comment.avatar);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 12,
        backgroundColor: usernameColor.withValues(alpha: 0.15),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: avatarUrl,
            memCacheWidth: 72,
            memCacheHeight: 72,
            width: 24,
            height: 24,
            fit: BoxFit.cover,
            placeholder: (_, _) =>
                _buildSmallTextAvatar(comment, usernameColor),
            errorWidget: (_, _, _) =>
                _buildSmallTextAvatar(comment, usernameColor),
          ),
        ),
      );
    }
    return _buildSmallTextAvatar(comment, usernameColor);
  }

  Widget _buildTextAvatar(KugouComment comment, Color usernameColor) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: usernameColor.withValues(alpha: 0.15),
      child: Text(
        comment.username.isNotEmpty ? comment.username[0] : '?',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: usernameColor),
      ),
    );
  }

  Widget _buildSmallTextAvatar(KugouComment comment, Color usernameColor) {
    return CircleAvatar(
      radius: 12,
      backgroundColor: usernameColor.withValues(alpha: 0.15),
      child: Text(
        comment.username.isNotEmpty ? comment.username[0] : '?',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: usernameColor, fontSize: 11),
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
