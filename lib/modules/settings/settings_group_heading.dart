import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';

/// 设置分类与详情页共用的分组标题，不额外制造独立卡片。
class SettingsGroupHeading extends StatelessWidget {
  const SettingsGroupHeading(
    this.title, {
    super.key,
    this.first = false,
  });

  final String title;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分隔线画成 **full-bleed**：原实现把它放在 16dp 水平内衬里面，
        // 读起来像「一行短横线」而不是分组线——分组语义靠线条贯穿整宽表达。
        if (!first)
          Divider(
            height: 1,
            thickness: 1,
            color: colors.outlineVariant.withValues(alpha: 0.5),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            first ? AppSpacing.lg : AppSpacing.xl,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Semantics(
            header: true,
            child: Text(
              title,
              // 原来是 titleMedium(16/w600)，与下面行标题 bodyLarge(16/w600)
              // 字号字重完全相同、只差颜色——层级几乎为零。分组标题降到
              // labelLarge(14/w600) 并用 primary 色，靠「更小但更醒目」区分，
              // 行标题才立得住。
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 分区内的子组标签：层级低于 [SettingsGroupHeading]、高于普通设置行。
///
/// 用于按钮组等非 ListTile 控件的组标题（如「网络音质」「失去音频焦点时」）。
/// 不加分隔线、不用 primary 色，避免像段标题一样过度切割分区。
class SettingsSubGroupLabel extends StatelessWidget {
  const SettingsSubGroupLabel(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
