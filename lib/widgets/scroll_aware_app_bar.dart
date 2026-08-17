import 'package:flutter/material.dart';

/// 通用滚动感知 AppBar。
///
/// 顶栏背景色从透明渐变到 surface：
/// - 滚动 offset 0 → [fadeRange]（默认 80px）范围背景从透明 → surface
/// - 标题 opacity 同步从 0 → 1（避免初始就有标题文字时遮挡内容）
/// - actions 始终可见
///
/// 用法：
/// ```dart
/// final _scrollController = ScrollController();
/// Scaffold(
///   appBar: ScrollAwareAppBar(
///     title: '我的收藏',
///     scrollController: _scrollController,
///     actions: [...],
///   ),
///   body: ListView(
///     controller: _scrollController,
///     children: [...],
///   ),
/// )
/// ```
///
/// **原理**：通过传入的 [ScrollController] 监听滚动 offset，调用方需要
/// 把同一个 controller 传给 ListView / CustomScrollView。
class ScrollAwareAppBar extends StatefulWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  final ScrollController? scrollController;
  final double fadeRange;
  final Widget? leading;

  const ScrollAwareAppBar({
    super.key,
    required this.title,
    this.actions,
    this.scrollController,
    this.fadeRange = 80,
    this.leading,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<ScrollAwareAppBar> createState() => _ScrollAwareAppBarState();
}

class _ScrollAwareAppBarState extends State<ScrollAwareAppBar> {
  double _scrollOffset = 0;

  void _onScroll() {
    if (!mounted) return;
    final offset = widget.scrollController?.offset ?? 0;
    if ((offset - _scrollOffset).abs() > 0.5) {
      setState(() => _scrollOffset = offset);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.scrollController?.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollAwareAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_onScroll);
      widget.scrollController?.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollController?.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final t = (_scrollOffset / widget.fadeRange).clamp(0.0, 1.0);

    // 背景从透明渐变到 surface：仅插值 alpha（透明度），保持 surface 色相。
    // 不能用 Color.lerp(Colors.transparent, surface, t)：transparent 是
    // alpha=0 的黑色，逐通道插值会让中间态变成半透明灰（顶栏先变暗再变正常）。
    final backgroundColor = colorScheme.surface.withValues(alpha: t);

    return AppBar(
      backgroundColor: backgroundColor,
      elevation: 0,
      scrolledUnderElevation: 0, // 关闭 Material 3 自带突变变色
      surfaceTintColor: Colors.transparent, // 关闭 surfaceTint 着色
      foregroundColor: colorScheme.onSurface,
      leading: widget.leading,
      // 标题始终显示（用户反馈：初始就应可见，不依赖滚动）
      title: Text(
        widget.title,
        style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      actions: widget.actions,
      centerTitle: false,
    );
  }
}
