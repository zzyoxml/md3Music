import 'package:fluttertoast/fluttertoast.dart';

/// 全局 Toast 提示工具（统一替代原 SnackBar 通知）。
///
/// 默认短时长（LENGTH_SHORT ≈ 2s），[long] 为 true 时使用长时长
/// （LENGTH_LONG ≈ 3.5s）。位置统一为屏幕底部居中。
void showToast(String msg, {bool long = false}) {
  Fluttertoast.showToast(
    msg: msg,
    toastLength: long ? Toast.LENGTH_LONG : Toast.LENGTH_SHORT,
    gravity: ToastGravity.BOTTOM,
  );
}
