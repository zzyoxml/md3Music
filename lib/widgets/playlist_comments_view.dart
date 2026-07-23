import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/kugou_provider.dart';
import '../services/kugou_api/kugou_models.dart';

/// 歌单评论列表视图。
///
/// 在 PlaylistPage 中展示歌单的评论，支持加载更多。
class PlaylistCommentsView extends StatefulWidget {
  final String specialId;

  const PlaylistCommentsView({
    super.key,
    required this.specialId,
  });

  @override
  State<PlaylistCommentsView> createState() => _PlaylistCommentsViewState();
}

class _PlaylistCommentsViewState extends State<PlaylistCommentsView> {
  List<KugouComment> _comments = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = true;
  final ScrollController _scrollController = ScrollController();

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
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PlaylistCommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.specialId != widget.specialId) {
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
    if (widget.specialId.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final kugouProvider = context.read<KugouProvider>();
    final result = await kugouProvider.getPlaylistComments(
      widget.specialId,
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
    if (_isLoadingMore || !_hasMore) return;

    setState(() => _isLoadingMore = true);

    final kugouProvider = context.read<KugouProvider>();
    final result = await kugouProvider.getPlaylistComments(
      widget.specialId,
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
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading && _comments.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null && _comments.isEmpty) {
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
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _fetchComments,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_comments.isEmpty) {
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
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _comments.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.1),
      ),
      itemBuilder: (context, index) {
        if (index == _comments.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _isLoadingMore
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: _loadMore,
                      child: const Text('加载更多'),
                    ),
            ),
          );
        }
        return _buildCommentItem(_comments[index], colorScheme);
      },
    );
  }

  Widget _buildCommentItem(KugouComment comment, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: colorScheme.primary.withValues(alpha: 0.15),
            child: Text(
              comment.username.isNotEmpty ? comment.username[0] : '?',
              style: TextStyle(
                color: colorScheme.primary,
                fontSize: 13,
              ),
            ),
          ),
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
                        style: TextStyle(
                          color: colorScheme.primary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatTime(comment.time),
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  comment.content,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
