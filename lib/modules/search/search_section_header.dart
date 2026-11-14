import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';

/// 搜索空态各段的统一段落头:标题 + 右侧动作区,三段(搜索历史 / 热门搜索 /
/// 探索音乐)共用同一解剖结构,消除「一段卡壳、一段裸排、一套小标题」的混乱。
///
/// 节奏约定:标题上 `lg` 下 `sm`(首段顶部的 `lg` 即与搜索栏的间隔),
/// 左 `lg` 对齐页面基准线,右 `sm` 贴住动作按钮;正文内容由各段自带
/// `lg` 水平内边距,与标题左缘严格对齐。
class SearchSectionHeader extends StatelessWidget {
  const SearchSectionHeader({super.key, required this.title, this.actions = const []});

  final String title;

  /// 右侧动作,统一用 [SearchSectionAction] 构建,保证同规格。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              // titleMedium 原生即为 w600,层级靠字号档位表达,不再 copyWith。
              style: Theme.of(context).textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final action in actions) action,
        ],
      ),
    );
  }
}

/// 段落头动作的统一规格:紧凑 TextButton,默认 onSurfaceVariant,
/// 可选图标;破坏性动作([destructive])保持同形状仅换 error 色。
///
/// TV 单停点(TvCardFocus)由调用方按各自的 debugLabel 包裹,
/// 本组件保持纯样式。
class SearchSectionAction extends StatelessWidget {
  const SearchSectionAction({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.destructive = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final foreground = destructive ? cs.error : cs.onSurfaceVariant;
    return TextButton.icon(
      onPressed: onTap,
      icon: icon == null
          ? null
          : Icon(icon, size: 16, color: foreground),
      label: Text(label),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: foreground,
      ),
    );
  }
}
