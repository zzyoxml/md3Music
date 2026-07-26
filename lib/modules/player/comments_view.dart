import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';

/// 评论列表视图。
///
/// 在 FullPlayer 中作为 TabBarView 第三个 Tab 展示。
///
/// - AM 风格（[isAmStyle] = true）：背景为模糊封面 + 黑蒙版，统一白色文字。
/// - MD3 风格（[isAmStyle] = false，默认）：跟随莫奈色主题，用户名用主色调，
///   评论正文和时间戳根据深浅色模式自动适配。
///
/// **分页加载**：滚动到底部自动加载下一页评论。
///
/// **mask alpha 渐变**：列表顶部/底部各 24px 范围用 ShaderMask + BlendMode.dstIn
/// 实现 alpha 渐变（比歌词页更窄），让滚动内容从背景柔和淡入、淡出到背景，
/// 避免列表硬切边。
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
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = true;

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
        if (result != null && result.comments.isNotEmpty) {
          _comments = result.comments;
          _currentPage = 1;
          _hasMore = result.comments.length >= 20;
        } else {
          _comments = [];
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

  @override
  Widget build(BuildContext context) {
    // 根据风格和主题计算颜色
    final Color primaryTextColor;
    final Color secondaryTextColor;
    final Color usernameColor;

    if (widget.isAmStyle) {
      // AM 风格：固定白色文字
      primaryTextColor = Colors.white;
      secondaryTextColor = const Color(0xB3FFFFFF);
      usernameColor = const Color(0xB3FFFFFF);
    } else {
      // MD3 风格：跟随莫奈色主题
      final colorScheme = Theme.of(context).colorScheme;
      primaryTextColor = colorScheme.onSurface;
      secondaryTextColor = colorScheme.onSurfaceVariant;
      usernameColor = colorScheme.primary;
    }

    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: primaryTextColor),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: secondaryTextColor,
              ),
              const SizedBox(height: 12),
              Text(
                '加载评论失败',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: secondaryTextColor,
                ),
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

    if (_comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.comment_outlined,
              size: 48,
              color: secondaryTextColor,
            ),
            const SizedBox(height: 12),
            Text(
              '暂无评论',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: secondaryTextColor,
              ),
            ),
          ],
        ),
      );
    }

    // 用 ShaderMask + BlendMode.dstIn 实现上下 alpha 渐变：
    // 顶部 24px alpha 0→1，底部 24px alpha 1→0，
    // 比 lyrics 视图更窄，让评论从背景柔和淡入、淡出到背景。
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
          stops: [
            0.0,
            fadeRatio,
            1.0 - fadeRatio,
            1.0,
          ],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _comments.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, _) => Divider(
          height: 1,
          color: secondaryTextColor.withValues(alpha: 0.2),
        ),
        itemBuilder: (context, index) {
          if (index == _comments.length) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _isLoadingMore
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: primaryTextColor,
                        ),
                      )
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
          final comment = _comments[index];
          return _buildCommentItem(
            comment,
            primaryTextColor,
            secondaryTextColor,
            usernameColor,
          );
        },
      ),
    );
  }

  Widget _buildCommentItem(
    KugouComment comment,
    Color primaryTextColor,
    Color secondaryTextColor,
    Color usernameColor,
  ) {
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.username,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: usernameColor,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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
                Text(
                  comment.content,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: primaryTextColor,
                    height: 1.4,
                  ),
                ),
                if (comment.likes > 0) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 12,
                        color: secondaryTextColor.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${comment.likes}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: secondaryTextColor.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建评论用户头像。
  /// 优先使用 API 返回的头像 URL，加载失败或无头像时回退到首字母圆形头像。
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

  Widget _buildTextAvatar(KugouComment comment, Color usernameColor) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: usernameColor.withValues(alpha: 0.15),
      child: Text(
        comment.username.isNotEmpty ? comment.username[0] : '?',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: usernameColor,
        ),
      ),
    );
  }

  /// 修复头像 URL：http → https
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
}
