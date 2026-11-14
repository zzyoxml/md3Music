/// Windows 桌面 F11 → Zen 的桥。
///
/// `_zenMode` 是两套播放页 State 的私有状态，只有页内能改；而 F11 的按键处理
/// 挂在全局 `HardwareKeyboard`（见 `core/services/windows_fullscreen.dart`），
/// 拿不到那个 State。这里沿用 `TvPlayerBackFallback` 的同一套模式：播放页注册
/// 一个「切换 Zen」回调，全局层倒序询问最上层那个。
///
/// 用列表而非单引用：拖拽覆盖层实例与路由实例可能短暂并存，取**最后注册**的
/// = 视觉最上层（与 `TvPlayerBackFallback` / `TvPlayerPlayFocusBridge` 同口径）。
class PlayerZenBridge {
  PlayerZenBridge._();

  static final PlayerZenBridge instance = PlayerZenBridge._();

  final List<bool Function()> _handlers = <bool Function()>[];

  void register(bool Function() handler) {
    if (!_handlers.contains(handler)) _handlers.add(handler);
  }

  void unregister(bool Function() handler) {
    _handlers.remove(handler);
  }

  /// 询问最上层的播放页切换 Zen。
  ///
  /// 返回 true = 已切换（本次按键被播放页消费）；false = 没有播放页在接管，
  /// 调用方退化为窗口全屏切换。
  bool toggleZen() {
    for (final bool Function() handler in _handlers.reversed) {
      if (handler()) return true;
    }
    return false;
  }

  /// 当前是否有播放页注册（诊断用）。
  bool get hasHandlers => _handlers.isNotEmpty;
}
