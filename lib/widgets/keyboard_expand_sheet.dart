import 'package:material_ui/material_ui.dart';

/// 键盘自适应的 `DraggableScrollableSheet`。
///
/// 弹层（modal bottom sheet）不会随软键盘上移，托盘里的输入框只能靠自身 padding
/// 避让，于是「键盘以上可用的列表高度」会被托盘自身的比例（如 0.5）限制住——
/// 打字时列表只剩一条缝。这里在键盘可见时把托盘动画到 [maxChildSize]，
/// 键盘收起后回到用户原来的高度比例。
///
/// 之所以用控制器而不是直接改 [initialChildSize]：`DraggableScrollableSheet`
/// 的 `didUpdateWidget` 只替换 extent 的 min/max/snap 与 snapSizes，
/// **不会**把当前高度重置成新的 `initialChildSize`。
class KeyboardExpandScrollableSheet extends StatefulWidget {
  /// 初始高度比例（父容器高度的比例）。
  final double initialChildSize;

  /// 允许拖到的最小高度比例。
  final double minChildSize;

  /// 允许拖到的最大高度比例。键盘弹出时也展开到这个值。
  final double maxChildSize;

  /// 托盘内容构建器（与 `DraggableScrollableSheet.builder` 同签名）。
  final Widget Function(BuildContext context, ScrollController scrollController)
      builder;

  const KeyboardExpandScrollableSheet({
    super.key,
    required this.builder,
    this.initialChildSize = 0.5,
    this.minChildSize = 0.25,
    this.maxChildSize = 0.95,
  });

  @override
  State<KeyboardExpandScrollableSheet> createState() =>
      _KeyboardExpandScrollableSheetState();
}

class _KeyboardExpandScrollableSheetState
    extends State<KeyboardExpandScrollableSheet> {
  final DraggableScrollableController _controller =
      DraggableScrollableController();

  /// 键盘弹出前的高度比例，键盘收起后恢复到这里。
  double? _sizeBeforeKeyboard;
  bool _keyboardVisible = false;

  /// 键盘弹出/收起时的高度过渡时长。
  static const Duration _resizeDuration = Duration(milliseconds: 220);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (visible == _keyboardVisible) return;
    _keyboardVisible = visible;
    // 等这一帧布局完成再动高度：首帧里控制器可能还没 attach
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncSize(visible));
  }

  void _syncSize(bool keyboardVisible) {
    if (!mounted || !_controller.isAttached) return;
    final current = _controller.size;

    if (keyboardVisible) {
      _sizeBeforeKeyboard = current;
      if (current < widget.maxChildSize) {
        _controller.animateTo(
          widget.maxChildSize,
          duration: _resizeDuration,
          curve: Curves.easeOut,
        );
      }
      return;
    }

    // 键盘收起：回到键盘弹出前的高度（用户在弹出前可能自己拖过）
    final target = (_sizeBeforeKeyboard ?? widget.initialChildSize)
        .clamp(widget.minChildSize, widget.maxChildSize);
    _sizeBeforeKeyboard = null;
    if ((current - target).abs() > 0.001) {
      _controller.animateTo(
        target,
        duration: _resizeDuration,
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _controller,
      initialChildSize: widget.initialChildSize,
      minChildSize: widget.minChildSize,
      maxChildSize: widget.maxChildSize,
      expand: false,
      builder: widget.builder,
    );
  }
}
