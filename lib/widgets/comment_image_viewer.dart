import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../services/kugou_api/kugou_models.dart';

/// 全屏查看评论图片（PageView 翻页 + 双指缩放）。
///
/// 不引入第三方图片浏览器依赖：PageView + InteractiveViewer 均为 Flutter 原生。
Future<void> showCommentImageViewer(
  BuildContext context, {
  required List<CommentImage> images,
  int initialIndex = 0,
  Widget Function(BuildContext context, CommentImage image)? imageBuilder,
}) {
  if (images.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (dialogContext) => _CommentImageViewer(
      images: images,
      initialIndex: initialIndex.clamp(0, images.length - 1),
      imageBuilder: imageBuilder,
    ),
  );
}

class _CommentImageViewer extends StatefulWidget {
  final List<CommentImage> images;
  final int initialIndex;
  final Widget Function(BuildContext context, CommentImage image)? imageBuilder;

  const _CommentImageViewer({
    required this.images,
    required this.initialIndex,
    this.imageBuilder,
  });

  @override
  State<_CommentImageViewer> createState() => _CommentImageViewerState();
}

class _CommentImageViewerState extends State<_CommentImageViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        PageView.builder(
          controller: _controller,
          itemCount: widget.images.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (context, i) => InteractiveViewer(
            maxScale: 4,
            child: Center(child: _buildImage(context, widget.images[i])),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 0,
          right: 0,
          child: Center(
            child: Text(
              '${_index + 1}/${widget.images.length}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 4,
          right: 8,
          child: IconButton(
            key: const ValueKey('comment-image-viewer-close'),
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }

  Widget _buildImage(BuildContext context, CommentImage image) {
    final custom = widget.imageBuilder;
    if (custom != null) return custom(context, image);
    return CachedNetworkImage(
      imageUrl: image.url,
      fit: BoxFit.contain,
      memCacheWidth: 1080,
      // 加载指示器统一用 m3e_core（与项目其它加载态一致）；黑底上取白色
      placeholder: (_, _) => const Center(
        child: M3ELoadingIndicator(
          constraints: BoxConstraints.tightFor(width: 24, height: 24),
          color: Colors.white,
        ),
      ),
      errorWidget: (_, _, _) => const Icon(
        Icons.broken_image_outlined,
        color: Colors.white54,
        size: 40,
      ),
    );
  }
}
