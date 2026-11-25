import 'package:material_ui/material_ui.dart';

import '../core/theme/app_dimens.dart';

/// 全站统一的空态 / 错误态展示组件。
///
/// **为什么需要它**：改动前项目里有 8 种互不相同的空态——图标 48/56/64 三档、
/// 取色 4 种（`outline` / `onSurfaceVariant` 全亮 / alpha 0.5 / alpha 0.4）、
/// 主文案三个层级（`bodyLarge` / `titleMedium` / `bodyMedium` 表达同一语义）、
/// 图标到文案间距 12/8/4 三种、CTA 有的有有的没有。同一个 App 里"没有内容"
/// 有八种长相，是"换个页面像换了个 App"的主要来源之一。
///
/// 这里把契约收敛成一套：
/// - 图标：48，取 `onSurfaceVariant`（不再叠 alpha——双层减淡在浅色主题下
///   会掉到可读阈值以下）
/// - 标题：`titleMedium`（16/w600），主色 `onSurface`
/// - 副文案：`bodySmall`（12），`onSurfaceVariant`，可选
/// - 间距：图标→标题 `md`(12)、标题→副文案 `xs`(4)、副文案→CTA `lg`(16)
/// - CTA：可选，由调用方传入（保持各自的回调不变）
///
/// **不做什么**：不改任何回调语义、不接管状态、不做动画。它只负责"长什么样"。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.padding,
  });

  final IconData? icon;
  final String title;

  /// 补充说明（如"点击扫描按钮添加本地音乐"）。为空时不占位。
  final String? subtitle;

  /// 行动按钮（如"重试""扫描音乐"）。为空时不占位。
  final Widget? action;

  /// 外层内衬。默认 `all(xxl)`=32；嵌在小容器里时可传更小的值。
  final EdgeInsetsGeometry? padding;

  /// 行内紧凑变体：图标 40、无副文案位置限制，用于区块内部而非整页。
  const AppEmptyState.inline({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.xl,
    ),
  });

  /// 只有一行文字的极简变体（用于"暂无数据"这类不值当配图标的场合）。
  const AppEmptyState.text({
    super.key,
    required this.title,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.xl,
    ),
  })  : icon = null,
        subtitle = null,
        action = null;

  /// 是否为极简文字变体。
  bool get _isTextOnly => icon == null;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    final titleWidget = Text(
      title,
      textAlign: TextAlign.center,
      style: tt.titleMedium?.copyWith(
        color: cs.onSurface,
        // 标题在空态里不需要抢戏，但仍要高于副文案。
        fontWeight: FontWeight.w600,
      ),
    );

    if (_isTextOnly) {
      return Padding(
        padding: padding ??
            const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xl,
            ),
        child: Center(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    final children = <Widget>[
      Icon(
        icon,
        size: 48,
        // 单层减淡：不再叠 alpha，避免浅色主题下对比度不足。
        color: cs.onSurfaceVariant,
      ),
      const Gap(AppSpacing.md),
      titleWidget,
    ];

    final sub = subtitle;
    if (sub != null && sub.isNotEmpty) {
      children
        ..add(const Gap(AppSpacing.xs))
        ..add(
          Text(
            sub,
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        );
    }

    final act = action;
    if (act != null) {
      children
        ..add(const Gap(AppSpacing.lg))
        ..add(act);
    }

    return Padding(
      padding: padding ??
          const EdgeInsets.all(AppSpacing.xxl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}
