import 'package:flutter/services.dart';

/// 系统输出切换（Android 14+ 的「输出切换器」）的 Dart 侧门面。
///
/// 小米 HyperOS / MIUI 把这个系统面板实现成「妙播」（`miui.systemui`），
/// 所以一次调用就等于「唤起妙播」：不用私有 Intent，也不跳蓝牙设置
/// （设置页管的是配对，不是"现在从哪放"）。
///
/// **失败即降级**：非 Android、TV/老壳没注册插件、系统 < 14 ——
/// 一律 false/null，由调用方隐藏入口或提示一句，绝不留点了没反应的按钮。
class MediaOutputService {
  MediaOutputService._();

  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/media_output',
  );

  /// Android 14（API 34）起才有 `MediaRouter2.showSystemOutputSwitcher()`。
  static Future<bool> isSwitcherSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSwitcherSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 唤起系统输出切换器。false = 系统没弹（后台调用 / 版本过低 / ROM 拒绝）。
  static Future<bool> showSystemOutputSwitcher() async {
    try {
      return await _channel.invokeMethod<bool>('showSystemOutputSwitcher') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
