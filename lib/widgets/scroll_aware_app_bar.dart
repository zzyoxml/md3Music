import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/layout/page_title_alignment.dart';
import '../providers/theme_provider.dart';

const double _kTitleTrailingGap = 8.0;

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

  /// 紧跟在标题右边的一枚组件（如发现页的问候胶囊），跟着标题左对齐。
  ///
  /// 宽度由它自己的内容决定，上限是标题区剩下的宽度——[AppBar] 的标题区不含
  /// actions 那一段，中间还留着 [NavigationToolbar.kMiddleSpacing]，所以它再长
  /// 也碰不到第一枚图标按钮。
  final Widget? titleTrailing;

  /// 为 true 时背景不做滚动透明度渐变：未启用自定义背景时恒为不透明
  /// surface；启用自定义背景时完全透明（与主题 appBarTheme 一致），
  /// 让顶部与页面主体的壁纸透出透明度上下一致（参照「我的收藏」页）。
  ///
  /// 用于有全局背景图/滚动时内容透出会导致标题文字与背景重叠变色的页面
  /// （如发现页顶部）。
  final bool opaque;

  /// 页面在底部导航栏中的 tab id（取值见 [kAllAvailableTabs]），用于按
  /// [centerPageTitle] 判定标题对齐：tab 可直达的一级页面左对齐，二级页面居中。
  ///
  /// 从来不作为 tab 出现的页面（各类详情页/列表页）不传，标题自动居中。
  final String? tabId;

  const ScrollAwareAppBar({
    super.key,
    required this.title,
    this.actions,
    this.scrollController,
    this.fadeRange = 80,
    this.leading,
    this.titleTrailing,
    this.opaque = false,
    this.tabId,
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
    final useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;

    // 背景从透明渐变到 surface：仅插值 alpha（透明度），保持 surface 色相。
    // 不能用 Color.lerp(Colors.transparent, surface, t)：transparent 是
    // alpha=0 的黑色，逐通道插值会让中间态变成半透明灰（顶栏先变暗再变正常）。
    // opaque 语义：未启用背景时恒为不透明 surface（文字区稳定不变色）；
    // 启用背景时完全透明，壁纸透出与页面主体透明度上下一致
    // （此前为 surface alpha 0.2 半透明色带，用户要求改为完全透明）。
    final backgroundColor = widget.opaque
        ? (useBackgroundImage
            ? Colors.transparent
            : colorScheme.surface)
        : colorScheme.surface.withValues(alpha: t);

    return AppBar(
      backgroundColor: backgroundColor,
      elevation: 0,
      scrolledUnderElevation: 0, // 关闭 Material 3 自带突变变色
      surfaceTintColor: Colors.transparent, // 关闭 surfaceTint 着色
      foregroundColor: colorScheme.onSurface,
      leading: widget.leading,
      // 标题始终显示（用户反馈：初始就应可见，不依赖滚动）
      title: _buildTitle(textTheme),
      actions: widget.actions,
      // 统一对齐规则：底部导航栏可直达的一级页面左对齐，二级页面居中
      centerTitle: centerPageTitle(context, tabId: widget.tabId),
    );
  }

  Widget _buildTitle(TextTheme textTheme) {
    final titleText = Text(
      widget.title,
      style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    );
    final trailing = widget.titleTrailing;
    if (trailing == null) return titleText;
    return Row(
      children: [
        titleText,
        const SizedBox(width: _kTitleTrailingGap),
        Flexible(child: trailing),
      ],
    );
  }
}
