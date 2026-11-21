import 'package:material_ui/material_ui.dart';

/// 自定义背景开启时，避免容器变换转场用实色 surface 覆盖全局壁纸。
Color wallpaperAwareTransitionColor(BuildContext context, Color fallback) =>
    Theme.of(context).scaffoldBackgroundColor == Colors.transparent
        ? Colors.transparent
        : fallback;

// M3E 容器变换转场（m3_expressive openContainerTransform 的适配版）。
//
// 为什么不直接用包内 openContainerTransform：它把 openColor 硬编码为
// `Theme.of(context)`（flutter/material 的 Theme），而本项目主题树是
// material_ui fork——包内取色会退化为 Flutter fallback 亮色（暗色模式
// 闪白），且函数签名不暴露 openColor/scrimColor。本适配复刻其路由 morph
// 逻辑（时长/曲线/内容淡入阈值一致），颜色全部由调用方显式给出。

/// 从 [sourceKey] 对应的控件矩形 morph 展开到全屏并压入 [pageBuilder] 页面。
///
/// 路由压入 `Navigator.of(context)`（**最近层** Navigator）：底栏收起与悬浮
/// 胶囊下移的联动由 shell 的内层路由侦测驱动，morph 必须走内层才能触发它；
/// 原本走根 Navigator 的入口（如听歌识曲）接入时也要一并改为内层压入。
Future<void> m3eOpenContainerTransform({
  required BuildContext context,
  required GlobalKey sourceKey,
  required Color closedColor,
  required Color openColor,
  required BorderRadius closedRadius,
  required WidgetBuilder pageBuilder,
  Color scrimColor = Colors.black,
  VoidCallback? onReturn,
}) async {
  final box = sourceKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return;
  final origin = box.localToGlobal(Offset.zero);
  final sourceRect = origin & box.size;
  final screenSize = MediaQuery.sizeOf(context);

  await Navigator.of(context).push(
    _M3EContainerTransformRoute(
      sourceRect: sourceRect,
      screenSize: screenSize,
      closedColor: closedColor,
      openColor: openColor,
      closedRadius: closedRadius,
      scrimColor: scrimColor,
      pageBuilder: pageBuilder,
    ),
  );
  onReturn?.call();
}

class _M3EContainerTransformRoute<T> extends PageRoute<T> {
  final Rect sourceRect;
  final Size screenSize;
  final Color closedColor;
  final Color openColor;
  final BorderRadius closedRadius;
  final Color scrimColor;
  final WidgetBuilder pageBuilder;

  _M3EContainerTransformRoute({
    required this.sourceRect,
    required this.screenSize,
    required this.closedColor,
    required this.openColor,
    required this.closedRadius,
    required this.scrimColor,
    required this.pageBuilder,
  });

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      pageBuilder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.025),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: RepaintBoundary(child: child),
      ),
    );
  }
}
