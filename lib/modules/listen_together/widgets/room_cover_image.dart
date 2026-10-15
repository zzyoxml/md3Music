import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

/// 一起听统一封面组件（对齐 EchoMusic Cover.vue 的统一入口模式）：
/// - http(s) 走 CachedNetworkImage（磁盘缓存，与 CoverPrefetchQueue 同池，
///   预取完成后零网络命中）；
/// - 加载中：低透明度音符 Icon（对齐 EchoMusic 骨架屏观感）；
/// - 失败/空 URL：主题色底 + 音符 Icon（项目既有约定，不引入网络兜底图）；
/// - 淡入由 CachedNetworkImage 内建 fadeIn 承担。
class RoomCoverImage extends StatelessWidget {
  final String? url;
  final double iconSize;
  final Color? background;
  final Color? iconColor;
  final BoxFit fit;
  final BorderRadius? customRadius;

  const RoomCoverImage({
    super.key,
    required this.url,
    this.iconSize = 20,
    this.background,
    this.iconColor,
    this.fit = BoxFit.cover,
    this.customRadius,
  });

  Widget _fallback(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: background ?? cs.primaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: iconSize,
        color: iconColor ?? cs.onPrimaryContainer,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = url?.trim() ?? '';
    final cs = Theme.of(context).colorScheme;
    Widget child;
    if (u.isEmpty || !(u.startsWith('http://') || u.startsWith('https://'))) {
      // 空 URL/非网络封面：直接显示兜底（主题色底 + 音符）
      child = _fallback(context);
    } else {
      child = CachedNetworkImage(
        imageUrl: u,
        fit: fit,
        placeholder: (_, _) => Container(
          color: background ?? cs.primaryContainer,
          alignment: Alignment.center,
          child: Icon(
            Icons.music_note,
            size: iconSize,
            color: (iconColor ?? cs.onPrimaryContainer).withValues(alpha: 0.3),
          ),
        ),
        errorWidget: (_, _, _) => _fallback(context),
      );
    }
    // 圆角裁剪统一包裹所有分支：兜底封面（未加载/加载失败）与网络图
    // 形状一致，均为圆角矩形（8px 默认，房间页大图 16px 覆盖）
    return ClipRRect(
      borderRadius: customRadius ?? BorderRadius.circular(8),
      child: child,
    );
  }
}
