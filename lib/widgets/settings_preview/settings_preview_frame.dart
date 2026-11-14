import 'package:flutter/material.dart';

/// 设置页功能可视化演示卡的统一外框。
///
/// 五张演示卡（歌词效果 / 播放页背景 / 音乐频谱 / 封面与动态 / 导航与布局）
/// 共用本外框，保证同一页内多张卡的整体节奏一致。
///
/// 为什么是「卡片内嵌标题 + 底部说明」而不是裸图：
/// 演示卡要回答「这是什么效果」与「该动哪个开关」两个问题，缺标题用户
/// 不知道在看什么，缺底部说明则控件改了画面却不告诉你改了哪一项。
///
/// 高度不做任何硬约束：由调用方给定 [height]（默认 150），五张卡按内容
/// 各自取不同高度，但最大不超过 200，避免把控件挤出首屏。
class SettingsPreviewFrame extends StatelessWidget {
  /// 卡片标题（如「歌词效果预览」）。null 时整行不占位。
  final String? title;

  /// 标题下方的说明（如「当前：Apple Music 风格」）。null 时不占位。
  final String? subtitle;

  /// 卡片底部的补充说明（如「拖动下方滑块实时生效」）。null 时不占位。
  final String? footnote;

  /// 演示区内容。
  final Widget child;

  /// 演示区高度。
  final double height;

  /// 演示区背景色；默认取主题 surfaceContainerHighest，调用方可覆盖
  /// （如歌词卡要更暗的底衬托白色歌词）。
  final Color? background;

  const SettingsPreviewFrame({
    super.key,
    this.title,
    this.subtitle,
    this.footnote,
    required this.child,
    this.height = 150,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          // 演示区：高度按调用方给定值，但父级空间不足时**由它让步**——
          // Flexible + 下限保护，标题/说明行永不被裁。这样卡片放进窄容器
          // （小屏 / 测试里的 SizedBox）也不会 RenderFlex overflow。
          Flexible(
            child: Container(
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: background ?? colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: child,
            ),
          ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                footnote!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
