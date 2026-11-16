import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

/// tv: 遥控「拖拽」排序状态机：左键拿起 → 上下键移动（连发）→ OK/左键放下。
///
/// ## 交互口径（与触屏长按拖拽等价，TV 无指针故改按键）
///
/// - 焦点行按**左键**：拿起该行（Toast 长显提示）；
/// - 拿起后按**上/下键**：移动一格（dpad 的 `onDirection` 会同时投递
///   KeyRepeatEvent，按住即连发，口径同 `TvVolumeStepper`）；
/// - 拿起后按 **OK 或左键**：放下（Toast 提示），当前顺序即最终顺序；
/// - 拿起后按**返回键**：调用方在返回收口处调 [drop]（等同放下）；
/// - 未拿起时左键以外的方向键：放行给焦点遍历（返回 false）。
///
/// ## 索引语义
///
/// [onReorder] 与 `ReorderableListView.onReorder` **完全一致**（向下移动时
/// newIndex 已含 +1）——调用方把列表原有的 onReorder 原样传进来即可，
/// 由既有消费方（`reorderPlaylist` / `reorderTabs`）内部的 -1 换算收口。
class TvReorderController extends ChangeNotifier {
  TvReorderController({
    required this.itemCount,
    required this.onReorder,
    required this.labelOf,
    this.onToast,
  });

  /// 当前列表长度（惰性读取：排序/删行期间列表会变）。
  final int Function() itemCount;

  /// 重排回调（ReorderableListView 语义）。
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 行的展示名（Toast 文案用）。
  final String Function(int index) labelOf;

  /// Toast 出口（调用方接 `showToast`，便于测试替换）。
  final void Function(String msg, {bool long})? onToast;

  int? _carried;

  /// 正被拿起的行下标；未拿起为 null。
  int? get carriedIndex => _carried;

  bool get isCarrying => _carried != null;

  /// 焦点行 [focusedIndex] 上的方向键。返回 true = 已消费（焦点不移动）。
  bool handleDirection(int focusedIndex, TraversalDirection direction) {
    switch (direction) {
      case TraversalDirection.left:
        if (isCarrying) {
          drop();
        } else {
          pickUp(focusedIndex);
        }
        return true;
      case TraversalDirection.up:
      case TraversalDirection.down:
        if (!isCarrying) return false;
        move(direction == TraversalDirection.up ? -1 : 1);
        return true;
      case TraversalDirection.right:
        return false;
    }
  }

  /// 拿起 [index] 行。
  void pickUp(int index) {
    if (index < 0 || index >= itemCount()) return;
    _carried = index;
    _toast('已拿起《${labelOf(index)}》，按上下键移动，按 OK 或左键放下', long: true);
    notifyListeners();
  }

  /// 移动 [delta] 格（-1 上 / +1 下）。到顶/到底为空操作。
  void move(int delta) {
    final int? from = _carried;
    if (from == null) return;
    final int count = itemCount();
    // 拿起期间列表被外部删短：拿起行已不存在，静默收手（不调 onReorder，
    // 交给消费方越界保护只会静默失败，这里直接收起避免 carriedIndex 悬空）。
    if (from < 0 || from >= count) {
      _carried = null;
      notifyListeners();
      return;
    }
    final int to = (from + delta).clamp(0, count - 1);
    if (to == from) return;
    // ReorderableListView 语义：向下移动时插入位 = 目标位 + 1。
    onReorder(from, to > from ? to + 1 : to);
    _carried = to;
    notifyListeners();
  }

  /// 放下（提交当前顺序）。
  void drop() {
    final int? from = _carried;
    if (from == null) return;
    _carried = null;
    _toast('已放下《${labelOf(from)}》');
    notifyListeners();
  }

  void _toast(String msg, {bool long = false}) {
    onToast?.call(msg, long: long);
  }

  @override
  void dispose() {
    _carried = null;
    super.dispose();
  }
}

/// tv: 可排序列表行的遥控包装：单停点（excludeChildFocus 默认 true，内层
/// ListTile/InkWell 不再产生第二个停点）+ 排序方向键接线 + 拿起态高亮。
///
/// 非 TV 构建由调用方门控（`kTvBuild ? TvReorderItem(...) : 原行`），本组件
/// 自身不依赖编译期旗标，普通 flutter test 可钉住行为。
class TvReorderItem extends StatelessWidget {
  const TvReorderItem({
    super.key,
    required this.index,
    required this.controller,
    required this.child,
    this.onSelect,
    this.focusNode,
    this.autofocus = false,
  });

  final int index;
  final TvReorderController controller;
  final Widget child;

  /// OK 动作（播放/切换勾选等）；null = OK 无动作（排序模式禁用点击的行）。
  /// **拿起态下 OK 一律收口到 [TvReorderController.drop]**，不触发本回调。
  final VoidCallback? onSelect;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final Widget row = child;
    final VoidCallback? select = onSelect;
    return DpadFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onSelect: () {
        // 拿起态 OK = 放下（需求：移动完成后按 OK 或再按左键放下）。
        if (controller.isCarrying) {
          controller.drop();
          return;
        }
        select?.call();
      },
      onDirection: (direction) => controller.handleDirection(index, direction),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final bool carried = controller.carriedIndex == index;
          if (!carried) return row;
          // 拿起态高亮：让用户看清哪一行被拿起来了（Toast 之外的第二重反馈）。
          final ColorScheme cs = Theme.of(context).colorScheme;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: row,
          );
        },
      ),
    );
  }
}
