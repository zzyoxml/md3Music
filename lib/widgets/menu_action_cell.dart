import 'package:flutter/material.dart';

/// 播放器更多菜单中的宫格动作单元：上方 icon、下方文字。
/// 用于将均衡器 / 定时关闭 / 投屏 等横向排列在同一行（MD3E 容器分组）。
class MenuActionCell extends StatelessWidget {
  const MenuActionCell({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  /// 单元图标。
  final IconData icon;

  /// 单元下方文字。
  final String label;

  /// 激活态：为 true 时 icon 与文字用主题色 primary 高亮。
  final bool active;

  /// 点击回调（调用方负责先关闭当前弹层再执行动作）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = active ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: textTheme.labelMedium?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
