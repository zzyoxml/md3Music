import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../layout/ime_collapse.dart';

/// tv: TV 输入法保活守卫（TV 构建专用；组件本身不门控，调用方按 kTvBuild 接线）。
///
/// ## 修什么
///
/// 焦点进入单行输入框后遥控器弹起系统输入法，**一按方向键键盘就消失**。链路：
/// 方向键在输入框内不在叶子消费（同 `tv_key_repeat.dart` 的放行口径），冒泡到
/// `Dpad` 根部 `Shortcuts`；dpad 3.1.1 `_directionAllowed`（root.dart:407-430）
/// 对**单行框 up/down 恒判「移出字段」**（left/right 在光标贴边时同样逃逸）→
/// TextField 失焦 → Flutter 隐藏文本输入会话 → **IME 收起**。
///
/// 本层在「主焦点是可编辑控件」时把四个方向键就地消费（handled，不做任何事），
/// 键盘保持弹出；退出输入框靠 **BACK**（dpad 在输入框持焦时 back 自动 stand
/// down，先由系统收键盘）。选字/候选键位移动交给输入法窗口本身——按键能否真的
/// 到达 IME 由原生 `TvImeProxyView`（`com.md3music.md3music/ime_proxy`）决定，
/// 本守卫只保证 Flutter 侧不再把键盘顶掉。
///
/// ## 接线位置（与 TvKeyRepeatLayer 同一约束）
///
/// 包在 `Dpad` **之内**、`TvKeyRepeatLayer` **之外**（见 `app.dart::_tvContentScope`）：
/// 按键沿 primaryFocus 向上冒泡，本层在 dpad 根部 `Shortcuts` 之前拿到方向键。
///
/// ## 已知取舍
///
/// - 输入框内方向键不再移动光标（IME 会话未绑定的设备上光标移动本来也不解决
///   「选不了字」；键盘先保住才谈得上修 IME 链路）。
/// - IME 会话正常绑定、按键在 ImeInputStage 就被系统投给输入法时，本层收不到
///   按键，自然惰化，无副作用。
class TvImeGuard extends StatelessWidget {
  const TvImeGuard({super.key, required this.child});

  final Widget child;

  /// 会被 dpad 判为「逃逸出输入框」的四个方向键。
  /// 注意不能用 `const Set`：`LogicalKeyboardKey` 覆写了 `==`/`hashCode`，
  /// const 集合会报 const_set_element_not_primitive_equality。
  static final Set<LogicalKeyboardKey> _arrows = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_arrows.contains(event.logicalKey)) return KeyEventResult.ignored;
    // 输入框失焦后放行：dpad 正常导航（含 TvKeyRepeatLayer 的连发）。
    if (!hasFocusedTextInput()) return KeyEventResult.ignored;
    // 只吃 down/repeat；up 不消费（无 activator 匹配 up，不会触发任何动作）。
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // canRequestFocus=false + skipTraversal=true：本节点不是焦点停点，只挂在
    // 按键传播路径上（同 TvKeyRepeatLayer 接线口径；skipTraversal 只作用本节点）。
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKeyEvent,
      child: child,
    );
  }
}
