import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../layout/ime_collapse.dart';

/// tv: 把「输入框是否持焦」转发给原生 IME 代理 View 的桥（组件本身不门控，
/// 调用方按 kTvBuild 接线；非 TV 设备上原生未注册 channel，调用静默失败）。
///
/// ## 为什么需要
///
/// 部分 Android TV（`config_preventImeStartupUnlessTextEditor=true` 的低内存
/// 机型）拒绝给「不自报为文本编辑器」的视图绑定输入法会话。Flutter 的
/// `FlutterView` 不上报 `onCheckIsTextEditor()`（Flutter issue #177360，官方
/// 修复 PR #193074 尚未合并），结果：**输入法能弹出但没有会话**，遥控器的
/// 方向键/OK 一个都到不了输入法，用户无法选字。
///
/// 原生侧（`TvImeProxyView`，`com.md3music.md3music/ime_proxy`）用一个自报
/// 文本编辑器的代理 View 补上这个信号，但代理**恒开**会让 IME 误以为整窗
/// 都在文本编辑（back / 媒体键语义跑偏），所以必须由 Dart 精确告知时机：
/// 输入框持焦 → active=true；失焦 → active=false。
///
/// 判据复用 [kTextInputFocused]（[hasFocusedTextInput] 的产出，见
/// `ime_collapse.dart` 的真机说明：TV 上拿 viewInsets 判键盘不可靠，焦点态
/// 才是唯一稳定信号）。本组件自己 `attach` 一次 tracker：TV 布局上不保证
/// 树里常驻 [ImeCollapse]（其 build 在 TV 直接透传，但 tracker 只在 initState
/// 挂），不挂这一下 notifier 就永远不翻转。
///
/// ## 失败口径
///
/// channel 调用失败（非 TV 构建、原生未注册）一律吞掉：本桥是增强，不是
/// 依赖——失败时输入法行为退回修改前，不影响输入与导航。
class TvImeProxyBridge extends StatefulWidget {
  const TvImeProxyBridge({super.key, required this.child});

  final Widget child;

  @override
  State<TvImeProxyBridge> createState() => _TvImeProxyBridgeState();
}

class _TvImeProxyBridgeState extends State<TvImeProxyBridge> {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/ime_proxy',
  );

  /// 已发给原生的状态（去重，避免每次焦点抖动都 restartInput）。
  bool? _lastSent;

  @override
  void initState() {
    super.initState();
    TextInputFocusTracker.attach();
    kTextInputFocused.addListener(_onInputFocusChanged);
    _push(kTextInputFocused.value);
  }

  @override
  void dispose() {
    kTextInputFocused.removeListener(_onInputFocusChanged);
    // 收尾把代理关掉：页面销毁时若残留 active=true，IME 会以为还在文本编辑。
    _push(false);
    TextInputFocusTracker.detach();
    super.dispose();
  }

  void _onInputFocusChanged() => _push(kTextInputFocused.value);

  void _push(bool active) {
    if (_lastSent == active) return;
    _lastSent = active;
    // ignore: discarded_futures
    _channel
        .invokeMethod<void>('setActive', <String, bool>{'active': active})
        // 非 TV 构建 / 原生未注册 / 引擎尚未 attach：增强失败即退回原行为。
        .catchError((Object _) {
          _lastSent = null;
        });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
