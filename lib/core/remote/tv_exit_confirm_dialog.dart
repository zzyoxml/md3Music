import 'package:flutter/material.dart';

/// TV 返回键菜单的三选一结果。
enum TvExitAction {
  /// 关闭菜单，留在 App 内。
  cancel,

  /// 回到桌面，音乐与本地 Rust 服务继续运行（挂后台）。
  background,

  /// 关闭音乐与本地 Rust 服务并退出 App。
  exitApp,
}

/// TV 构建的返回确认菜单（防遥控器误触）：焦点默认落在「取消」上，
/// OK 键 = 取消；方向键右移 + OK = 后台播放；再右移 + OK = 退出 App。
///
/// 独立于 kTvBuild（纯组件），TV 分支在 `app.dart._onBackPressedForExit`
/// 内按 `kTvBuild` 调用；widget 测试直接 pump 本组件。
///
/// 三种结果的落地方向见 [TvExitAction]：`background` 走 `moveTaskToBack`
/// 挂后台（音乐与本地服务保持运行）；`exitApp` 停止播放、移除媒体通知并
/// 关停本地 Rust 服务后结束任务。
Future<TvExitAction> showTvExitConfirmDialog(BuildContext context) async {
  final result = await showDialog<TvExitAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('退出 MD3Music？'),
      content: const Text(
        '后台播放：回到桌面，音乐与本地服务继续运行。\n'
        '退出 App：关闭音乐与本地服务并退出。',
      ),
      actions: [
        TextButton(
          // 焦点默认落「取消」：遥控器 OK 误触不会直接退出
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(TvExitAction.cancel),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(TvExitAction.background),
          child: const Text('后台播放'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(TvExitAction.exitApp),
          child: const Text('退出 App'),
        ),
      ],
    ),
  );
  return result ?? TvExitAction.cancel;
}
