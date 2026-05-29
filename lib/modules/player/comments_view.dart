import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';

class CommentsView extends StatefulWidget {
  final String songHash;
  final String? albumAudioId;

  const CommentsView({super.key, required this.songHash, this.albumAudioId});

  @override
  State<CommentsView> createState() => _CommentsViewState();
}

class _CommentsViewState extends State<CommentsView> {
  List<KugouComment> _comments = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchComments();
    });
  }

  @override
  void didUpdateWidget(covariant CommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchComments();
      });
    }
  }

  Future<void> _fetchComments() async {
    if (widget.songHash.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.getComments(widget.songHash, albumAudioId: widget.albumAudioId);

    if (mounted) {
      setState(() {
        _isLoading = false;
        final commentList = kugouProvider.comments;
        if (commentList != null && commentList.comments.isNotEmpty) {
          _comments = commentList.comments;
        } else {
          _comments = [];
        }
        _error = kugouProvider.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
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
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                '加载评论失败',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.comment_outlined,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无评论',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _comments.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final comment = _comments[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: colorScheme.surfaceContainerHighest,
                child: Text(
                  comment.username.isNotEmpty ? comment.username[0] : '?',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
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
                        Text(
                          comment.username,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const Spacer(),
                        Text(
                          _formatTime(comment.time),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.6),
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      comment.content,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.thumb_up_outlined,
                          size: 14,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${comment.likes}',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.6),
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
