import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../providers/comment_display_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3e_loading_indicator.dart';

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
/// - 楼层评论（楼中楼），点击"查看N条回复"展开
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
  final ScrollController _scrollController = ScrollController();
  List<KugouComment> _comments = [];
  List<KugouComment> _hotComments = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = true;

  /// 长评论展开状态
  final Set<String> _expandedContents = {};

  /// 楼层评论状态（按评论 ID 索引）
  final Map<String, _FloorState> _floorStates = {};

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
    final result = await kugouProvider.getComments(
      widget.songHash,
      albumAudioId: widget.albumAudioId,
      page: _currentPage + 1,
    );

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
      if (mounted) setState(() => state.loading = false);
    }
  }

  void _toggleFloor(KugouComment comment) {
    final state = _getFloorState(comment.id);
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

    if (_isLoading) {
      return Center(child: MD3ELoadingIndicator(color: primaryTextColor));
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
        displayItems.add(_CommentDisplayItem.header('最新评论'));
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
                    ? MD3ELoadingIndicator(size: 24, color: primaryTextColor)
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
                      ? _buildFloorReplies(
                          comment,
                          floorState!,
                          primaryTextColor,
                          secondaryTextColor,
                          usernameColor,
                          replyFontSize,
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
          // 回复列表
          for (final reply in state.replies)
            _buildFloorReplyItem(
              reply,
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
                child: MD3ELoadingIndicator(size: 16, color: usernameColor),
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

  Widget _buildFloorReplyItem(
    KugouComment reply,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
    double fontSize,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
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
                  reply.content,
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
