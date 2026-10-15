import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';

/// 全局 Toast 提示工具（统一替代原 SnackBar 通知）。
///
/// 默认短时长（LENGTH_SHORT ≈ 2s），[long] 为 true 时使用长时长
/// （LENGTH_LONG ≈ 3.5s）。位置统一为屏幕底部居中。
///
/// **平台降级**：`fluttertoast` 只实现了 Android / iOS / Web，Windows 上调用会抛
/// `MissingPluginException`，导致所有提示静默消失——用户只看到"点了没反应"，
/// 完全无从判断是权限、路径还是别的什么错了。Windows 端改用原生消息框兜底，
/// 保证反馈始终可见。
void showToast(String msg, {bool long = false}) {
  if (_useNativeMessageBox) {
    // 不 await：保持 showToast 的 void 签名与既有调用点一致。
    unawaited(_showNativeMessageBox(msg, long: long));
    return;
  }
  Fluttertoast.showToast(
    msg: msg,
    toastLength: long ? Toast.LENGTH_LONG : Toast.LENGTH_SHORT,
    gravity: ToastGravity.BOTTOM,
  );
}

/// 是否走原生消息框兜底（fluttertoast 无实现的平台）。
///
/// 用 `defaultTargetPlatform` 而非 `Platform.isWindows`：后者读的是**宿主**系统，
/// 在 Windows 上跑 `flutter test` 时同样为 true（测试目标平台其实是 android），
/// 会让所有 toast 断言取不到消息。`defaultTargetPlatform` 在测试里默认 android、
/// 真机 Windows 桌面才是 windows，与"按运行平台降级"的语义一致。
bool get _useNativeMessageBox {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows;
}

/// Windows 原生消息框兜底实现。
Future<void> _showNativeMessageBox(String msg, {required bool long}) async {
  const channel = MethodChannel('md3music/desktop_message');
  try {
    await channel.invokeMethod<void>('show', {
      'message': msg,
      'title': 'MD3Music',
      // long 时带信息图标，短提示不带，避免打断感。
      'infoIcon': long,
    });
  } catch (e) {
    // 原生侧也不可用时，至少不要把异常抛给调用点（showToast 是 void 工具）。
    debugPrint('[showToast] 原生消息框失败: $e');
  }
}