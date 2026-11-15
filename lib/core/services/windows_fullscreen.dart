import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows 桌面「无边框窗口全屏」的 Dart 侧门面。
///
/// ## 为什么需要它
///
/// Android 的沉浸靠 `SystemChrome.setEnabledSystemUIMode(immersiveSticky)`，
/// 但那是**移动端 embedder 概念**：Windows 桌面 embedder 没有对应实现，调用后
/// 窗口仍是普通带框窗口、任务栏照常可见。所以 Zen 在 Windows 上「不能完全进入
/// 全屏」——真全屏必须落到原生窗口样式（见 `windows/runner/flutter_window.cpp`
/// 的 `SetFullscreen`）。
///
/// ## 快照模型
///
/// Zen 会临时把窗口变全屏，但用户可能在进 Zen 之前就已经手动全屏（F11）过。
/// 因此 [enterZen] 先记下「进入前是否已经全屏」，[exitZen] 只恢复自己那次改变：
/// 进 Zen 前已全屏 → 退出 Zen 仍保持全屏。这样两个入口互不吞掉对方的状态。
///
/// ## 平台口径
///
/// 一律用 `defaultTargetPlatform` 而非 `Platform.isWindows`：后者在 Windows
/// 宿主上跑 `flutter test` 时也为 true，会把宿主平台泄漏进本应跑 Android 语义的
/// 测试（与 `core/utils/app_toast.dart` 同一教训）。
class WindowsFullscreen {
  WindowsFullscreen._();

  static const MethodChannel _channel = MethodChannel('md3music/window_tray');

  /// 当前是否桌面 Windows（唯一支持本能力的平台）。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 原生全屏状态的 Dart 镜像（标题栏据此把「最大化」换成「退出全屏」）。
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Zen 进入前的全屏状态；null = 当前没有由 Zen 持有的全屏。
  static bool? _zenSnapshot;

  /// 直接设置窗口全屏（F11 / 标题栏用）。
  static Future<void> setActive(bool value) async {
    if (!supported) return;
    try {
      final result = await _channel.invokeMethod<bool>('setFullscreen', {
        'value': value,
      });
      if (result != null) active.value = result;
    } on MissingPluginException {
      // widget 测试没有原生 runner；实际运行须使用同一构建中的 Dart 与 runner。
    } on PlatformException catch (error) {
      debugPrint('WindowsFullscreen.setActive($value) failed: $error');
    }
  }

  /// 切换窗口全屏。
  static Future<void> toggle() async {
    if (!supported) return;
    try {
      final result = await _channel.invokeMethod<bool>('toggleFullscreen');
      if (result != null) active.value = result;
    } on MissingPluginException {
      // 同上：无原生 runner 时静默降级。
    } on PlatformException catch (error) {
      debugPrint('WindowsFullscreen.toggle failed: $error');
    }
  }

  /// 用原生真实状态校正镜像（启动、以及外部改变窗口后）。
  static Future<void> sync() async {
    if (!supported) return;
    try {
      final result = await _channel.invokeMethod<bool>('isFullscreen');
      if (result != null) active.value = result;
    } on MissingPluginException {
      // 同上。
    } on PlatformException catch (error) {
      debugPrint('WindowsFullscreen.sync failed: $error');
    }
  }

  /// 进入 Zen：需要时把窗口切到全屏，并记住进入前的状态。
  ///
  /// 不 await：全屏与 Zen 的 400ms 转场要在同一帧起跑，否则会先看到 chrome
  /// 淡出、随后窗口才跳成全屏，读起来像两段动作。
  static void enterZen() {
    if (!supported) return;
    // 幂等：快照非空就说明已经为这次 Zen 记过账（重复调用多发生在
    // 「进 Zen 又立刻 peek 回来」这类同帧序列里），不再重复发通道调用。
    if (_zenSnapshot != null) return;
    _zenSnapshot = active.value;
    if (!active.value) {
      // ignore: discarded_futures
      setActive(true);
    }
  }

  /// 退出 Zen：只恢复「Zen 自己那次」全屏改变。
  ///
  /// 必须在调用方的 `_zenMode` 守卫**之前**调用（peek 期间 `_zenMode` 已是
  /// false，放守卫后面会漏掉恢复）。
  static void exitZen() {
    if (!supported) return;
    final snapshot = _zenSnapshot;
    _zenSnapshot = null;
    if (snapshot == false && active.value) {
      // ignore: discarded_futures
      setActive(false);
    }
  }
}

/// 安装 Windows 全局 F11 处理器，返回卸载函数。
///
/// [toggleZen] 由播放页注册（见 `modules/player/player_zen_bridge.dart`）：
/// 返回 true = 本次 F11 已切换 Zen，不再动窗口全屏；返回 false = 不在播放页
/// （或播放页此刻不接管），退化为切换窗口全屏（Windows 通用习惯）。
///
/// 只在 `KeyDownEvent` 响应：`KeyRepeatEvent` 会让按住 F11 时反复进出 Zen。
/// 挂在 `HardwareKeyboard` 上而不是某个 `Focus`：桌面端焦点可能停在任意控件，
/// 全屏快捷键不该被焦点位置左右（`ShortcutService` 已有同款先例）。
VoidCallback installWindowsF11Handler({
  required bool Function() toggleZen,
}) {
  if (!WindowsFullscreen.supported) return () {};
  bool handle(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.f11) return false;
    if (!toggleZen()) {
      // ignore: discarded_futures
      WindowsFullscreen.toggle();
    }
    return true;
  }

  HardwareKeyboard.instance.addHandler(handle);
  return () => HardwareKeyboard.instance.removeHandler(handle);
}
