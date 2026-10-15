import 'package:flutter/material.dart';

/// TV 构建的退出确认对话框（防遥控器误触）：焦点默认落在「取消」上，
/// OK 键 = 取消；方向键右移 + OK = 退出。返回 true 表示用户确认退出。
///
/// 独立于 kTvBuild（纯组件），TV 分支在 `app.dart._onBackPressedForExit`
/// 内按 `kTvBuild` 调用；widget 测试直接 pump 本组件。
Future<bool> showTvExitConfirmDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('退出 MD3Music？'),
      content: const Text('退出后将回到桌面，后台播放与本地服务保持运行。'),
      actions: [
        TextButton(
          // 焦点默认落「取消」：遥控器 OK 误触不会直接退出
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('退出'),
        ),
      ],
    ),
  );
  return result ?? false;
}
