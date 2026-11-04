import 'package:material_ui/material_ui.dart';

import '../core/platform_capabilities.dart';

/// 专辑/歌单评论托盘的初始高度比例。
///
/// Windows 桌面用鼠标时，`DraggableScrollableSheet` 的内容区无法像触摸那样
/// 拖动扩张托盘，默认只开 0.5 会一直停在半屏。给到近全屏；顶部拖动区
/// （[DraggableSheetHeader]）仍可继续拉到 1.0 或收回。
double commentSheetInitialChildSize() => isWindowsDesktop ? 0.9 : 0.5;

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
  ///
  /// 与 [builderWithController] 二选一；不需要顶部拖拽调高时用这个即可。
  final Widget Function(BuildContext context, ScrollController scrollController)?
      builder;

  /// 需要顶部拖动区（[DraggableSheetHeader]）调整托盘高度时用这个构建器。
  ///
  /// 第三个参数是本组件内部的高度控制器，直接交给 [DraggableSheetHeader]；
  /// 控制器生命周期由本组件管理，调用方不需要释放。
  final Widget Function(
    BuildContext context,
    ScrollController scrollController,
    DraggableScrollableController sheetController,
  )? builderWithController;

  const KeyboardExpandScrollableSheet({
    super.key,
    this.builder,
    this.builderWithController,
    this.initialChildSize = 0.5,
    this.minChildSize = 0.25,
    this.maxChildSize = 0.95,
  }) : assert(
         builder != null || builderWithController != null,
         '必须提供 builder 或 builderWithController',
       );

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
      builder: (context, scrollController) {
        final withController = widget.builderWithController;
        if (withController != null) {
          return withController(context, scrollController, _controller);
        }
        return widget.builder!(context, scrollController);
      },
    );
  }
}

/// 托盘顶部的拖拽区（手柄 + 标题）。
///
/// 桌面端用鼠标时，`DraggableScrollableSheet` 的触摸拖拽不生效（Flutter 默认
/// `ScrollBehavior.dragDevices` 不含鼠标），内容区拖不动 → 托盘会一直停在
/// 初始高度。这里让顶部区域直接接管竖向拖动，把位移换算成高度比例，
/// 鼠标和触摸都能把托盘拉到 [maxChildSize]（或收回 [minChildSize]）。
class DraggableSheetHeader extends StatelessWidget {
  const DraggableSheetHeader({
    super.key,
    required this.controller,
    required this.minChildSize,
    required this.maxChildSize,
    required this.child,
  });

  /// 由 [KeyboardExpandScrollableSheet.builderWithController] 传入同一个实例。
  final DraggableScrollableController controller;

  final double minChildSize;
  final double maxChildSize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // 桌面端给出可上下调整的鼠标指针提示，避免用户以为托盘高度固定
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        // 手柄/标题本身没有可点击元素时也要能接住拖动
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) {
          if (!controller.isAttached) return;
          // 向上拖（dy < 0）增高；pixelsToSize 已按托盘可用高度换算成比例差。
          final next =
              (controller.size - controller.pixelsToSize(details.delta.dy))
                  .clamp(minChildSize, maxChildSize);
          controller.jumpTo(next);
        },
        child: child,
      ),
    );
  }
}
