import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

import '../core/services/image_gallery_saver.dart';
import '../services/kugou_api/kugou_models.dart';

/// 评论图片网格。
///
/// - 单图：按原始宽高比渲染，限制最大高度，避免长图撑爆评论区；
/// - 多图：3 列方格，最多展示 9 张，第 9 张右上角叠加 “+N”；
/// - 点击回传**下标 + 该格在屏幕上的矩形**，全屏查看器据此把大图「甩回」原位；
/// - 长按默认保存到系统相册（可用 [saveHandler] 覆盖，测试即用此注入假实现）；
/// - [imageBuilder] 仅用于测试注入（默认走 [CachedNetworkImage]）。
class CommentImageGrid extends StatelessWidget {
  final List<CommentImage> images;

  /// 点击某张图片，回传其在 [images] 中的下标与它在屏幕上的矩形。
  final void Function(int index, Rect? originRect)? onTapImage;

  /// 长按某张图片的下标；不传时走 [saveHandler]（默认保存到相册）。
  final void Function(int index)? onLongPressImage;

  /// 图片构建器覆盖点（测试用；生产不传）。
  final Widget Function(BuildContext context, CommentImage image)? imageBuilder;

  /// 保存图片的覆盖点（测试注入假实现；生产留空 → 真的存进相册）。
  static Future<bool> Function(BuildContext context, String url)? saveHandler;

  /// 网格最多展示的图片数量。
  static const int maxVisible = 9;

  /// 单图最大显示高度。
  static const double maxSingleHeight = 220;

  const CommentImageGrid({
    super.key,
    required this.images,
    this.onTapImage,
    this.onLongPressImage,
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
    return _tile(
      context,
      0,
      ConstrainedBox(
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
          _tile(
            context,
            i,
            Stack(
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

  /// 统一的小图交互包装：点击带上屏幕矩形，长按走保存。
  // tv: 不适用（评论小图点开/长按保存是纯手势交互，TV 上评论卡单停点
  // 已覆盖阅读主路径，图片九宫格不单独接入 D-pad 停点）
  Widget _tile(BuildContext context, int index, Widget child) {
    return Builder(
      builder: (tileContext) => GestureDetector(
        key: ValueKey('comment-image-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onTapImage?.call(index, _rectOf(tileContext)),
        onLongPress: () => _handleLongPress(context, index),
        child: child,
      ),
    );
  }

  /// 该格在屏幕上的矩形（供全屏查看器做「甩回小图」的落点）。
  Rect? _rectOf(BuildContext tileContext) {
    final box = tileContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _handleLongPress(BuildContext context, int index) async {
    final custom = onLongPressImage;
    if (custom != null) {
      custom(index);
      return;
    }
    if (index < 0 || index >= images.length) return;
    final handler = saveHandler ?? ImageGallerySaver.saveImageToGalleryWithFeedback;
    await handler(context, images[index].url);
  }
}
