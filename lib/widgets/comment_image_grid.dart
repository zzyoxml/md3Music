import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

import '../services/kugou_api/kugou_models.dart';

/// 评论图片网格。
///
/// - 单图：按原始宽高比渲染，限制最大高度，避免长图撑爆评论区；
/// - 多图：3 列方格，最多展示 9 张，第 9 张右上角叠加 “+N”；
/// - [imageBuilder] 仅用于测试注入（默认走 [CachedNetworkImage]）。
class CommentImageGrid extends StatelessWidget {
  final List<CommentImage> images;

  /// 点击某张图片，参数为其在 [images] 中的下标。
  final void Function(int index)? onTapImage;

  /// 图片构建器覆盖点（测试用；生产不传）。
  final Widget Function(BuildContext context, CommentImage image)? imageBuilder;

  /// 网格最多展示的图片数量。
  static const int maxVisible = 9;

  /// 单图最大显示高度。
  static const double maxSingleHeight = 220;

  const CommentImageGrid({
    super.key,
    required this.images,
    this.onTapImage,
    this.imageBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    if (images.length == 1) return _buildSingle(context);
    return _buildGrid(context);
  }

  Widget _buildSingle(BuildContext context) {
    final image = images.first;
    return GestureDetector(
      key: const ValueKey('comment-image-0'),
      onTap: () => onTapImage?.call(0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: maxSingleHeight),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: image.aspectRatio.clamp(0.5, 2.0),
            child: _buildImage(context, image),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final shown = images.take(maxVisible).toList();
    final overflow = images.length - shown.length;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      padding: EdgeInsets.zero,
      children: [
        for (var i = 0; i < shown.length; i++)
          GestureDetector(
            key: ValueKey('comment-image-$i'),
            onTap: () => onTapImage?.call(i),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _buildImage(context, shown[i]),
                ),
                if (i == shown.length - 1 && overflow > 0)
                  ColoredBox(
                    color: Colors.black54,
                    child: Center(
                      child: Text(
                        '+$overflow',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildImage(BuildContext context, CommentImage image) {
    final custom = imageBuilder;
    if (custom != null) return custom(context, image);
    return CachedNetworkImage(
      imageUrl: image.url,
      fit: BoxFit.cover,
      memCacheWidth: 320,
      placeholder: (_, _) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      errorWidget: (_, _, _) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.broken_image_outlined,
          size: 20,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
