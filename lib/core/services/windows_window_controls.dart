import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform_capabilities.dart' show isWindowsDesktop;

/// 自绘最大化键的指针状态（原生 → Dart）。
///
/// Win11 snap layouts 要求 `WM_NCHITTEST` 对该按钮返回 `HTMAXBUTTON`，
/// 该点随之变成父窗口非客户区，Flutter 子窗口收不到这里的指针事件（与
/// `windows-desktop.md` W16 的让位机制同源）；悬停/按压高亮只能由原生把
/// 状态经 `onCaptionMaxPointerState` 回传驱动。
class WindowsCaptionPointerState {
  const WindowsCaptionPointerState({this.hovered = false, this.pressed = false});

  final bool hovered;
  final bool pressed;

  @override
  bool operator ==(Object other) =>
      other is WindowsCaptionPointerState &&
      other.hovered == hovered &&
      other.pressed == pressed;

  @override
  int get hashCode => Object.hash(hovered, pressed);
}

/// Windows 主窗口操作（拖动 / 最小化 / 最大化 / 关闭）。
///
/// 与 [WindowsWindowFrame] 的标题栏三键共用 `md3music/window_tray` 通道。
/// 播放页在 Windows 上没有标题栏，顶栏拖动与「更多」菜单里的窗口项都走这里，
/// 保证只有一套平台调用与异常兜底。
class WindowsWindowControls {
  WindowsWindowControls._();

  static const MethodChannel _channel = MethodChannel('md3music/window_tray');

  /// 交给原生 `HTCAPTION` 进入系统窗口拖动；全屏时原生侧会忽略。
  static Future<void> startDrag() => _invoke('startDrag');

  static Future<void> minimize() => _invoke('minimize');

  /// 最大化 / 还原；全屏时原生侧语义为退出全屏。
  static Future<void> toggleMaximize() => _invoke('toggleMaximize');

  /// 复用 WM_CLOSE：有托盘时隐藏到托盘，不绕过既有退出逻辑。
  static Future<void> closeWindow() => _invoke('closeWindow');

  /// 自绘最大化键的悬停/按压状态。三键行订阅它驱动高亮。
  static final ValueNotifier<WindowsCaptionPointerState> maxButtonPointer =
      ValueNotifier<WindowsCaptionPointerState>(
          const WindowsCaptionPointerState());

  /// 当前接管 snap 命中的行 id（'' = 无人接管）。**接管态的唯一事实源**
  /// 是原生这条广播（`onCaptionMaxTakeover`），不是上报返回值：原生是单槽、
  /// 后来者覆盖，被覆盖的行必须自己退回纯 Flutter 命中路径，否则「原生对该点
  /// 返回 HTCLIENT、Flutter 收得到事件」会与「Dart 以为自己在接管」错位。
  static final ValueNotifier<String> maxButtonOwner =
      ValueNotifier<String>('');

  /// 登记最大化键矩形（窗口坐标、逻辑像素 → 客户区物理像素）。
  /// [id] = 本行实例的稳定标识；返回原生是否接受（全屏中 / 参数无效为 false，
  /// 接管态仍以 [maxButtonOwner] 广播为准）。
  static Future<bool> reportMaxButtonRect(
      String id, Rect logicalRect, double devicePixelRatio) async {
    if (!isWindowsDesktop) return false;
    try {
      final accepted = await _channel
          .invokeMethod<bool>('setCaptionMaxButtonRect', <String, Object>{
        'id': id,
        'left': (logicalRect.left * devicePixelRatio).round(),
        'top': (logicalRect.top * devicePixelRatio).round(),
        'right': (logicalRect.right * devicePixelRatio).round(),
        'bottom': (logicalRect.bottom * devicePixelRatio).round(),
      });
      return accepted == true;
    } on MissingPluginException {
      // Widget 测试没有原生 runner；实际运行须使用同一构建中的 Dart 与 runner。
    } on PlatformException catch (error) {
      debugPrint('Windows window control setCaptionMaxButtonRect failed: $error');
    }
    return false;
  }

  /// 撤销本行登记（id 不匹配时原生侧为空操作，迟到的撤销也安全）。
  static Future<void> clearMaxButtonRect(String id) async {
    if (!isWindowsDesktop) return;
    try {
      await _channel.invokeMethod<bool>(
          'clearCaptionMaxButtonRect', <String, Object>{'id': id});
    } on MissingPluginException {
      // 同上：无原生实现时静默降级。
    } on PlatformException catch (error) {
      debugPrint(
          'Windows window control clearCaptionMaxButtonRect failed: $error');
    }
  }

  /// 分发 `md3music/window_tray` 通道中由本服务消费的入站调用；返回是否命中。
  static bool handleNativeCall(MethodCall call) {
    switch (call.method) {
      case 'onCaptionMaxPointerState':
        final args = call.arguments;
        if (args is Map) {
          maxButtonPointer.value = WindowsCaptionPointerState(
            hovered: args['hovered'] == true,
            pressed: args['pressed'] == true,
          );
        }
        return true;
      case 'onCaptionMaxTakeover':
        maxButtonOwner.value = (call.arguments is String)
            ? call.arguments as String
            : '';
        return true;
    }
    return false;
  }

  static Future<void> _invoke(String method) async {
    if (!isWindowsDesktop) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Widget 测试 / 非同一构建的 runner 没有原生实现。
    } on PlatformException catch (error) {
      debugPrint('Windows window control $method failed: $error');
    }
  }
}
