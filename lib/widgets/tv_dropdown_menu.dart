import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';

import '../core/build_flags.dart';
import '../core/theme/app_dimens.dart';

/// TV 可用的下拉选择器：触屏构建渲染 [M3EDropdownMenu]（行为零变化），
/// TV 构建渲染同外观的可聚焦字段 + 底部弹层可聚焦行。
///
/// ## 为什么 TV 不能直接用 M3EDropdownMenu
/// 与 [lib/widgets/m3e_sort_sheet.dart] 里 `_openTvSortPicker` 记录的同一缺陷
/// （2026-10-04 歌单页排序下拉「捕获」焦点、其它全选不中）：
/// 1. 字段是 `Focus(onKeyEvent: _handleFieldKeyEvent)`，把 ↑/↓/Enter/Space
///    **全部**判为 handled（m3e_core `m3e_dropdown_menu.dart:390-398, 688-697`），
///    焦点一落到字段上方向键就被吞，只能靠左右键逃出；
/// 2. 面板经 `OverlayPortal` 渲染进最近的 Overlay（另一个 FocusScope），
///    而 dpad 的候选收集用 `currentNode.nearestScope.traversalDescendants`，
///    **收不到这个兄弟子树**；条目本身又是 `InkWell(canRequestFocus: false)`
///    纯点击（`m3e_dropdown_menu_item.dart:155-208`）——面板拉开了也选不中任何一项。
/// dpad 没有针对 Overlay 的接口，唯一可靠做法是把选择器换成**路由型弹层**
/// （`showM3EModalBottomSheet` 是独立路由，自带 FocusScope，dpad 会 wrap 到）。
///
/// ## 回调契约（与 M3E 单选一致，不可改）
/// - 选到非当前项 → `onSelectionChanged([item])`
/// - 再选**当前项** → `onSelectionChanged(const [])`
///
/// 仓内多处守卫依赖「空列表 = 重复点击当前项」这一语义
/// （`m3e_sort_sheet.dart:81-93`、`settings_page.dart` 的「同值必须直接返回，
/// 否则 setItems 回调 → setState → 重建 → setItems 无限回环」注释、
/// `comment_sort_filter_bar.dart` 的「不在这里做同值忽略」）。
/// 判定「是否当前项」直接读 `M3EDropdownItem.selected`：调用方每次 build 都按
/// 当前值重建 items（本仓既定手法，M3EDropdownMenu 没有 initialSelection 参数），
/// 因此 `selected` 就是实时当前值。
class TvDropdownMenu<T> extends StatelessWidget {
  final List<M3EDropdownItem<T>> items;
  final bool singleSelect;
  final bool showChipAnimation;
  final M3EDropdownFieldStyle fieldStyle;
  final ValueChanged<List<M3EDropdownItem<T>>>? onSelectionChanged;

  const TvDropdownMenu({
    super.key,
    required this.items,
    this.singleSelect = true,
    this.showChipAnimation = true,
    this.fieldStyle = const M3EDropdownFieldStyle(),
    this.onSelectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (!kTvBuild) {
      return M3EDropdownMenu<T>(
        items: items,
        singleSelect: singleSelect,
        showChipAnimation: showChipAnimation,
        // 外层 20 = 条目外角 12 + 列表内边距 8，同心圆（默认 28 过大）
        containerRadius: AppRadius.dropdownPanel,
        fieldStyle: fieldStyle,
        onSelectionChanged: onSelectionChanged,
      );
    }
    return _TvDropdownField<T>(
      items: items,
      fieldStyle: fieldStyle,
      onSelectionChanged: onSelectionChanged,
    );
  }
}

/// tv: 字段外观 + OK 开弹层。外观参数全部从 [fieldStyle] 取，AM 皮肤等
/// 自定义配色（`comment_sort_filter_bar.dart` 传的白色前景/透明底）自动跟随。
class _TvDropdownField<T> extends StatelessWidget {
  final List<M3EDropdownItem<T>> items;
  final M3EDropdownFieldStyle fieldStyle;
  final ValueChanged<List<M3EDropdownItem<T>>>? onSelectionChanged;

  const _TvDropdownField({
    required this.items,
    required this.fieldStyle,
    required this.onSelectionChanged,
  });

  M3EDropdownItem<T>? get _current {
    for (final item in items) {
      if (item.selected) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final current = _current;

    final textStyle = (current != null
            ? fieldStyle.selectedTextStyle ?? tt.bodyMedium
            : fieldStyle.hintStyle ?? tt.bodyMedium) ??
        tt.bodyMedium!;
    final contentColor = fieldStyle.foregroundColor ??
        (current != null ? cs.onSurface : cs.onSurfaceVariant);
    final borderColor = fieldStyle.border?.style == BorderStyle.none
        ? null
        : fieldStyle.border?.color ?? cs.outlineVariant;
    final borderWidth = fieldStyle.border?.width ?? 1.0;

    return DpadFocusable(
      debugLabel: 'tv-dropdown',
      onSelect: () => _openPicker(context),
      child: Container(
        decoration: BoxDecoration(
          color: fieldStyle.backgroundColor ?? cs.surfaceContainerHighest,
          borderRadius: fieldStyle.borderRadius ??
              const BorderRadius.all(Radius.circular(8)),
          border: borderColor == null
              ? null
              : Border.all(color: borderColor, width: borderWidth),
        ),
        padding: fieldStyle.padding,
        margin: fieldStyle.margin,
        child: Row(
          children: [
            if (fieldStyle.prefixIcon != null) ...[
              fieldStyle.prefixIcon!,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                current?.label ?? fieldStyle.hintText ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle.copyWith(color: contentColor),
              ),
            ),
            if (fieldStyle.suffixIcon != null)
              fieldStyle.suffixIcon!
            else if (fieldStyle.showArrow)
              Icon(Icons.arrow_drop_down, color: contentColor, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    if (items.isEmpty) return;
    final cs = Theme.of(context).colorScheme;
    final picked = await showM3EModalBottomSheet<M3EDropdownItem<T>>(
      context: context,
      // 实色背景：与仓内其它 TV 弹层同口径（全局 M3E 主题的 0.97 alpha 会让
      // 内容透出，压在全屏页上不易辨认）。
      backgroundColor: cs.surfaceContainerLow,
      builder: (ctx) => _TvDropdownSheet<T>(
        items: items,
        title: fieldStyle.hintText,
      ),
    );
    if (picked == null) return;
    // 当前项再选一次 = 触屏的「取消选中」，按契约回传空列表。
    onSelectionChanged?.call(picked.selected ? const [] : [picked]);
  }
}

class _TvDropdownSheet<T> extends StatelessWidget {
  final List<M3EDropdownItem<T>> items;
  final String? title;

  const _TvDropdownSheet({required this.items, this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 弹层是独立路由、dpad 会为其建 FocusScope；首行 autofocus 让一打开
    // 就看得见焦点在哪（AGENTS §12.4 规则 1：一个屏只给一个 autofocus）。
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Flexible(
              child: ConstrainedBox(
                // 长列表（如导入歌单选择、七类震动）必须能在弹层内滚动，
                // 同时不能顶到状态栏：上限 70% 屏高。
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.7,
                ),
                // 弹层的底是 material_ui 的 Scaffold/Material，而下面的行是
                // flutter/material 的 ListTile —— 同名不同型的 Material 匹配不上，
                // 必须自带一层 flutter 的 Material（AGENTS §4.13）。
                child: Material(
                  type: MaterialType.transparency,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final item = items[i];
                      final row = ListTile(
                        title: Text(
                          item.label,
                          style: TextStyle(
                            color: item.disabled ? cs.outline : cs.onSurface,
                          ),
                        ),
                        trailing: item.selected
                            ? Icon(Icons.check, color: cs.primary)
                            : null,
                      );
                      if (item.disabled) return row;
                      return DpadFocusable(
                        autofocus: i == 0,
                        debugLabel: 'tv-dropdown-option-$i',
                        onSelect: () => Navigator.pop(context, item),
                        child: row,
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
