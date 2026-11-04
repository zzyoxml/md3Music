import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// tv: 方向键连发层（TV 构建专用，由 `app.dart` 在 kTvBuild 分支接线）。
///
/// ## 为什么需要它
///
/// dpad 的 `DpadFocusable.onDirection` 文档口径是「按住不放天然连发」——那依赖
/// **平台**投递 `KeyRepeatEvent`（`TvVolumeStepper` 即按此口径实现）。但页面内
/// 的普通焦点移动走另一条路：方向键冒泡到 `Dpad` 根部 `Shortcuts`
/// （`SingleActivator` 默认 `includeRepeats: true`）→ 每次重复事件触发一次遍历。
/// 一旦遥控器/系统不投递重复事件（或延迟过长），「长按上下键在页面里连续移动」
/// 就不再成立。本层把连发改成**自持定时器**，与平台行为解耦：KeyDown 自行完成
/// 第一次移动并起表，之后每 [repeatPeriod] 推动一次；平台重复事件一律吞掉
/// （否则与定时器双速）；KeyUp 收表。
///
/// ## 接线位置（唯一合法位置）
///
/// 必须包在 `Dpad` **之内**、Navigator **之外**（见 `app.dart::_tvContentScope`）：
/// 这样本层 Focus 节点是全部焦点节点的祖先，且位于 `Dpad` 的 `Shortcuts`
/// **之下**——按键先经本层才到 dpad 遍历。`DpadFocusable.onDirection` 控件
/// （如 RemoteSlider）会在叶子消费掉方向键，事件到不了本层；**输入框不在
/// 此列**——方向键的光标编辑走 App 顶层 Shortcuts 链路（editable_text 的
/// forTextField Action），不在叶子消费，故本层对输入框一律放行（见
/// [_TvKeyRepeatLayerState._inEditable]），与 dpad root 对 EditableText 的
/// stand down 同口径（2026-10-16 实测：不放行则光标编辑被本层阻断）。
///
/// ## 语义等价性
///
/// 吞 KeyDown 后由本层代劳 `DpadController.move(dir)`，与 dpad 的
/// `_DpadDirectionalAction.invoke` 是同一调用（`primary.focusInDirection`），
/// 语义逐字等价。
class TvKeyRepeatLayer extends StatefulWidget {
  const TvKeyRepeatLayer({super.key, required this.child});

  final Widget child;

  /// 连发前等待（=「长按上键回顶栏」一类长按手势的判定阈值）。
  static const Duration repeatDelay = Duration(milliseconds: 320);

  /// 连发周期。
  static const Duration repeatPeriod = Duration(milliseconds: 110);

  @override
  State<TvKeyRepeatLayer> createState() => _TvKeyRepeatLayerState();
}

class _TvKeyRepeatLayerState extends State<TvKeyRepeatLayer> {
  Timer? _tick;
  TraversalDirection? _direction;

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    super.dispose();
  }

  /// 焦点是否位于输入框内（此时方向键归光标编辑，本层放行）。
  bool _inEditable() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    final BuildContext? focusContext = primary?.context;
    return focusContext != null &&
        focusContext.findAncestorStateOfType<EditableTextState>() != null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final TraversalDirection? direction = Dpad.keySetOf(
      context,
    ).directionOf(event.logicalKey);
    if (direction == null) return KeyEventResult.ignored;
    // 输入框内的方向键归光标编辑：本层不接手（同 dpad root 对 EditableText
    // 的 stand down 口径），放行给 App 顶层 Shortcuts 的
    // DirectionalFocusIntent → EditableText 的 forTextField Action。
    if (_inEditable()) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _start(direction);
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      // 连发由本层定时器驱动，吞掉平台重复避免双速。
      return _direction == direction
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      if (_direction == direction) _stop();
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  void _start(TraversalDirection direction) {
    _stop();
    _direction = direction;
    _move(direction); // 第一次移动立即完成
    _tick = Timer(TvKeyRepeatLayer.repeatDelay, () {
      _tick = Timer.periodic(TvKeyRepeatLayer.repeatPeriod, (_) {
        final TraversalDirection? d = _direction;
        if (d != null) _move(d);
      });
    });
  }

  void _stop() {
    _tick?.cancel();
    _tick = null;
    _direction = null;
  }

  void _move(TraversalDirection direction) {
    if (!mounted) return;
    // 双保险：焦点在计时期间移进输入框时收手（正常情况 _handleKeyEvent 的
    // 放行检查已拦住；这里防焦点在延迟窗口内转移的竞态）。
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    final BuildContext? focusContext = primary?.context;
    if (focusContext != null &&
        focusContext.findAncestorStateOfType<EditableTextState>() != null) {
      return;
    }
    Dpad.maybeOf(context)?.move(direction);
  }

  @override
  Widget build(BuildContext context) {
    // canRequestFocus=false + skipTraversal=true：本节点不是焦点停点，只挂在
    // 按键传播路径上（同 Flutter Shortcuts / CallbackShortcuts 接线；skipTraversal
    // 只作用于本节点自身，不波及子树遍历）。
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKeyEvent,
      child: widget.child,
    );
  }
}
