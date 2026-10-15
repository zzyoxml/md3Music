import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../core/theme/app_dimens.dart';

/// 竖向邻居挤压的高度分配（纯函数，便于单测）。
///
/// 规则与 m3e_core `RenderButtonGroup.performLayout` 的横向挤压完全对称：
/// - 被按下的一项按 `自然高度 * expandedRatio * progress` 增高；
/// - 它上下两侧的邻居各让出增量的一半；首项把增量全部让给下一项，末项同理；
/// - **总高度守恒**：分配后各项之和恒等于自然高度之和。
///
/// 总高守恒是硬要求：组里没有外层 `SizedBox` 固定高度，`Column` 的高度由子项
/// 求和决定，一旦总量随按压漂移，弹窗就会在按下/松开时长高一截。
///
/// [pressedIndex] 越界或 [progress] <= 0 时原样返回（不做无意义的分配）。
List<double> applyVerticalSquish({
  required List<double> naturalHeights,
  required int? pressedIndex,
  required double progress,
  required double expandedRatio,
}) {
  final sizes = List<double>.of(naturalHeights);
  final count = sizes.length;
  final index = pressedIndex;
  if (count == 0 || index == null) return sizes;
  if (index < 0 || index >= count) return sizes;
  final t = progress.clamp(0.0, 1.0);
  if (t <= 0) return sizes;

  final growth = sizes[index] * expandedRatio * t;
  sizes[index] += growth;
  if (count == 1) return sizes;
  if (index > 0 && index < count - 1) {
    sizes[index - 1] = math.max(0.0, sizes[index - 1] - growth / 2);
    sizes[index + 1] = math.max(0.0, sizes[index + 1] - growth / 2);
  } else if (index == 0) {
    sizes[1] = math.max(0.0, sizes[1] - growth);
  } else {
    sizes[index - 1] = math.max(0.0, sizes[index - 1] - growth);
  }
  return sizes;
}

/// 竖向版 MD3E 按钮组。
///
/// 视觉与设置页「主题模式」用的 [M3EToggleButtonGroup] **完全一致**（同一个
/// [M3EToggleButton]、同一套 token），只是排成一列，并把 m3e 只在横轴上提供的
/// 邻居挤压（neighbor-squish）换算到纵轴。
///
/// **为什么不直接用 `M3EToggleButtonGroup(direction: Axis.vertical)`**：
/// m3e_core 1.1.4 的 `_supportsAnimatedSquish` 硬性要求 `direction ==
/// Axis.horizontal`，传 vertical 会退回成一根纹丝不动的普通 Column（底层
/// `RenderButtonGroup` 其实已经写好了纵向分支，是 widget 层把路关掉了）。
///
/// 动画说明：这是**按压反馈**，属于 AGENTS.md §10.2 的"跟手"档，必须满帧，
/// 因此直接用 `AnimationController` + `vsync: this`，不挂 `PlayerFrameDriver`；
/// 它也不循环——松手即 reverse 回 0 并停。
class M3EVerticalSquishGroup extends StatefulWidget {
  const M3EVerticalSquishGroup({
    super.key,
    required this.actions,
    this.selectedIndex,
    this.onSelectedIndexChanged,
    this.size = M3EButtonSize.sm,
    this.style = M3EButtonStyle.filled,
    this.spacing = AppSpacing.xs,
    this.expandedRatio = 0.15,
    this.squishDuration = const Duration(milliseconds: 220),
    this.enableFeedback = true,
    this.semanticLabel,
  });

  /// 子项描述，直接复用 m3e 的 [M3EToggleButtonGroupAction]，保证与横版一致。
  final List<M3EToggleButtonGroupAction> actions;

  /// 单选当前项下标；null 表示无选中。
  final int? selectedIndex;

  /// 选中变化回调（点已选中的项不会再回调，因为那会传 `null` 语义之外的 false）。
  final ValueChanged<int?>? onSelectedIndexChanged;

  final M3EButtonSize size;
  final M3EButtonStyle style;

  /// 项与项之间的固定间距（挤压只改高度，不改间距）。
  final double spacing;

  /// 被按下项相对自然高度的增长比例。
  final double expandedRatio;

  /// 挤压进 / 出的时长。
  final Duration squishDuration;

  final bool enableFeedback;
  final String? semanticLabel;

  @override
  State<M3EVerticalSquishGroup> createState() =>
      _M3EVerticalSquishGroupState();
}

class _M3EVerticalSquishGroupState extends State<M3EVerticalSquishGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.squishDuration,
  );

  /// 每项一个按压态控制器：M3EToggleButton 会把自己的按压态写进来。
  late List<WidgetStatesController> _states;

  /// 可见槽位的量测 key（量到的是**自然高度**，不是被挤过的）。
  final List<GlobalKey> _slotKeys = [];

  /// 已量到的自然高度；长度 != actions.length 表示还没量完。
  List<double> _naturalHeights = const [];

  int? _pressedIndex;

  /// 量测代数：actions 变化时自增，让上一代的异步回调作废。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initPerAction();
  }

  @override
  void didUpdateWidget(covariant M3EVerticalSquishGroup old) {
    super.didUpdateWidget(old);
    if (old.squishDuration != widget.squishDuration) {
      _controller.duration = widget.squishDuration;
    }
    if (old.actions.length != widget.actions.length) {
      _disposeStates();
      _initPerAction();
      return;
    }
    // 选中项变了 → 文字/图标可能换，自然高度要重量一次。
    if (old.selectedIndex != widget.selectedIndex ||
        old.size != widget.size ||
        old.style != widget.style) {
      _naturalHeights = const [];
      _scheduleMeasure();
    }
  }

  @override
  void dispose() {
    _disposeStates();
    _controller.dispose();
    super.dispose();
  }

  void _initPerAction() {
    _states = List.generate(widget.actions.length, (i) {
      final controller = WidgetStatesController();
      controller.addListener(() => _onStateChanged(i, controller));
      return controller;
    });
    _slotKeys
      ..clear()
      ..addAll(List.generate(widget.actions.length, (_) => GlobalKey()));
    _naturalHeights = const [];
    _generation++;
    _scheduleMeasure();
  }

  void _disposeStates() {
    // 监听器只在 _initPerAction 里注册，而 WidgetStatesController.dispose()
    // 自己会清空监听者，这里不需要（也无法）再摘一次。
    for (final controller in _states) {
      controller.dispose();
    }
    _states = const [];
  }

  void _onStateChanged(int index, WidgetStatesController controller) {
    if (!mounted) return;
    final pressed = controller.value.contains(WidgetState.pressed);
    if (pressed) {
      if (_pressedIndex != index) {
        _pressedIndex = index;
        _controller.forward(from: 0);
      }
    } else if (_pressedIndex == index) {
      _pressedIndex = null;
      _controller.reverse();
    }
  }

  void _scheduleMeasure() {
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure(generation));
  }

  /// 自然高度必须从**无约束的那一帧**量（`_naturalHeights` 还是空、槽位没有
  /// 显式 height 的那一帧），绝不能从已被挤压的那一列里量——否则每按一次
  /// 自然高度就大一点，越按越高（m3e 在它自己的注记里踩过同一个坑）。
  ///
  /// 因此这里量的是可见槽位本身：只有当 `sizes == null` 时槽位才是无约束渲染
  /// 的，那一帧 post-frame 量到的就是按钮的自然高度；量到之后立刻固定下来，
  /// 后续挤压只改槽位 height，不再重量。
  void _measure(int generation) {
    if (!mounted || generation != _generation) return;
    final heights = <double>[];
    for (final key in _slotKeys) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      heights.add(box != null && box.hasSize ? box.size.height : 0);
    }
    if (heights.length != widget.actions.length) return;
    if (heights.any((h) => h <= 0)) return; // 量不到就等下一次重建再量
    if (_naturalHeights.length == heights.length) {
      var same = true;
      for (var i = 0; i < heights.length; i++) {
        if ((heights[i] - _naturalHeights[i]).abs() > 0.01) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    setState(() => _naturalHeights = heights);
  }

  Widget _buildButton(int index) {
    final action = widget.actions[index];
    return M3EToggleButton(
      key: ValueKey('vsg-item-$index'),
      size: widget.size,
      style: widget.style,
      statesController: _states[index],
      checked: widget.selectedIndex == index,
      icon: action.icon,
      checkedIcon: action.checkedIcon,
      label: action.label,
      checkedLabel: action.checkedLabel,
      enabled: action.enabled,
      enableFeedback: action.enableFeedback ?? widget.enableFeedback,
      // M3EToggleButton 点已选中的项会回 false，单选场景必须丢掉这一路。
      onCheckedChange: (checked) {
        if (checked) widget.onSelectedIndexChanged?.call(index);
      },
    );
  }

  /// 第 [index] 项的高度槽位。
  ///
  /// 外层只挂一个 [GlobalKey] 供量测用（一层 widget 只能有一个 key，所以
  /// `ValueKey('vsg-slot-$i')` 放在内层、真正带 height 的那个 SizedBox 上——
  /// 挤压改的就是它的高度，测试也靠它定位）。
  Widget _buildSlot(int index, double? height) {
    return SizedBox(
      key: _slotKeys[index],
      child: SizedBox(
        key: ValueKey('vsg-slot-$index'),
        height: height,
        child: _buildButton(index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) return const SizedBox.shrink();
    final count = widget.actions.length;
    final measured = _naturalHeights.length == count;

    Widget group = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final sizes = measured
            ? applyVerticalSquish(
                naturalHeights: _naturalHeights,
                pressedIndex: _pressedIndex,
                progress: _controller.value,
                expandedRatio: widget.expandedRatio,
              )
            : null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) SizedBox(height: widget.spacing),
              // vsg-slot-N 是每一项的高度槽位：挤压只改这里的高度，
              // 测试也靠这个 key 量高度（不能靠 find.ancestor 猜）。
              _buildSlot(i, sizes?[i]),
            ],
          ],
        );
      },
    );

    if (widget.semanticLabel != null) {
      group = Semantics(
        container: true,
        label: widget.semanticLabel,
        child: group,
      );
    }
    return group;
  }
}
