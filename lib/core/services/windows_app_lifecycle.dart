import 'package:flutter/services.dart';

import 'diagnostic_logger.dart';

/// Windows「真退出」握手尾步：释放 WinRT 播放器并通知原生销毁窗口。
///
/// Windows 托盘可用时，`SystemNavigator.pop` 只会隐藏窗口而留下进程；
/// 必须走 `finishExit` 原生握手，更新器才能等到应用进程真正结束后替换文件。
Future<void> finishWindowsAppExit() async {
  try {
    await const MethodChannel('com.ryanheise.just_audio.methods')
        .invokeMethod<void>('disposeAllPlayers', <String, dynamic>{});
  } catch (error, stack) {
    DiagnosticLogger.instance.e('退出时释放 Windows 播放器失败: $error\n$stack');
  }
  await const MethodChannel('md3music/window_tray').invokeMethod<void>(
    'finishExit',
  );
}
