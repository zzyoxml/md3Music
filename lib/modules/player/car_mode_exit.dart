// 车机模式「退出」动作：顶栏按钮 → 二次确认弹窗 → 关闭车机模式开关。
//
// 抽成顶层函数是因为 MD（FullPlayer）与 AM（AmStyleFullPlayer）是两份独立 State，
// 都要提供同一个退出入口；文案与确认流程共用一份，避免两处各写一遍后逐渐分叉。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../providers/car_mode_provider.dart';

/// 弹出「退出车机模式」二次确认框；用户确认则关闭车机模式并返回 `true`，
/// 取消（或点外部关闭）返回 `false`。
///
/// 为什么走根 Navigator（`useRootNavigator: true`）：车机模式下播放器位于侧边
/// 面板的嵌套 Navigator 内，弹窗若只挂在面板 Navigator 上会被压进面板宽度里
/// （窄条弹窗，既不好看也不够醒目）。走根 Navigator 才能全屏居中遮罩。
Future<bool> confirmExitCarMode(BuildContext context) async {
  // 在第一个 await 之前取好依赖，避免 await 之后再用 BuildContext
  // （use_build_context_synchronously）。
  final carMode = context.read<CarModeProvider>();

  final confirmed = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      title: const Text('退出车机模式'),
      content: const Text('退出后播放器面板不再常驻显示，可随时在「设置 → 车机模式」重新开启。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('退出'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  HapticFeedback.mediumImpact();
  // 关闭开关 → CarModePanel 立即返回 child，整块面板随之卸载。
  await carMode.setEnabled(false);
  return true;
}
