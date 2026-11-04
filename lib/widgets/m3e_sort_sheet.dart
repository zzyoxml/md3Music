import 'package:dpad/dpad.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import '../core/build_flags.dart';
import '../core/theme/app_dimens.dart';

/// 一个排序选项：值 + 显示文本。
typedef M3ESortOption<T> = ({T value, String label});

/// 顶栏排序触发器：外观是一个图标，点一下 M3E 下拉面板就在图标下方就近展开。
///
/// 交互与原 PopupMenu 一致（但少了一次点击）：
/// - 点未选中的项 → 切换排序项（[onPicked] 的 repeated 为 false）
/// - 再次点当前项 → M3E 单选会把当前项取消选中，回调收到空列表，
///   这里映射为切换升/降序（[onPicked] 的 repeated 为 true）
///
/// ## 为什么要用 [OverflowBox] 撑宽
/// `M3EDropdownMenu` 的面板宽度**硬绑定字段宽度**（内部是
/// `SizedBox(width: 字段渲染宽度)`），而字段本身又是拉起/收起面板的唯一触发器
/// （外点关闭层会主动跳过落在字段范围内的点击，所以「隐藏的 0 尺寸字段 + 旁边放
/// 一个 IconButton」会导致点第二次收不起来）。于是这里让字段的真实渲染宽度 =
/// [panelWidth]（够放条目文字），再用 [OverflowBox] 把它塞回顶栏一个图标位。
/// 多出来的宽度从左侧溢出，悬停时显示高亮，但不可点（[OverflowBox]
/// 只对自身尺寸范围做命中测试），图标（[M3EDropdownFieldStyle.suffixIcon]）
/// 正好落在图标位中心，顶栏排布与原来的 IconButton 完全一致。
class M3ESortButton<T> extends StatefulWidget {
  /// Tooltip 文案，同时用作字段的无障碍标签。
  final String tooltip;

  /// 触发器图标。
  final IconData icon;

  /// 下拉字段及面板宽度，也决定悬停高亮向左延伸的范围。
  final double panelWidth;

  /// 排序选项（值 + 显示文本）。
  final List<M3ESortOption<T>> options;

  /// 当前生效的排序项，必须能在 [options] 中找到。
  final T current;

  /// 当前是否正序；null 表示该入口只做筛选、没有方向概念（如 MV 分类），
  /// 此时面板不显示方向切换。
  final bool? ascending;

  /// 选中排序字段回调（再点当前项不动作）。
  final ValueChanged<T> onPicked;

  /// 方向切换回调（点面板底部的「正序 / 倒序」分段控件）；[ascending] 非 null 时必传。
  final ValueChanged<bool>? onDirectionChanged;

  const M3ESortButton({
    super.key,
    this.tooltip = '排序',
    this.icon = Icons.sort,
    this.panelWidth = 220,
    required this.options,
    required this.current,
    this.ascending,
    required this.onPicked,
    this.onDirectionChanged,
  });

  @override
  State<M3ESortButton<T>> createState() => _M3ESortButtonState<T>();
}

class _M3ESortButtonState<T> extends State<M3ESortButton<T>> {
  /// 在顶栏里实际占位的尺寸：与 IconButton 的 48×48 一致，前后图标不位移。
  static const double _slot = 48;

  late final M3EDropdownController<T> _controller;

  @override
  void initState() {
    super.initState();
    _controller = M3EDropdownController<T>();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 选择变化回调。
  ///
  /// 上游只在挂载（或换 controller）时登记该回调一次，所以这里必须读
  /// `widget.xxx` 取实时值，不能捕获 build 时的局部变量。
  void _handleSelectionChanged(List<M3EDropdownItem<T>> selected) {
    if (selected.isEmpty) {
      // 再点当前项：单选下当前项被取消选中 → 空列表。方向已改由面板
      // 底部的分段控件切换，这里只重建一次把高亮回灌到当前项。
      setState(() {});
      return;
    }
    final value = selected.first.value;
    if (value == widget.current) {
      // 回调值与组件声明的当前值一致：这是上游 setItems 的回灌
      // （父级每次重建都会经 didUpdateWidget → setItems 触发一次），
      // 不是用户操作，必须忽略。
      return;
    }
    widget.onPicked(value);
  }

  /// 图标取色：与相邻 IconButton 的规则保持一致。
  ///
  /// IconButton 的规则是「环境 IconTheme 有非默认色就用它（顶栏里就是 AppBar
  /// 注入的 foregroundColor），否则回落到 onSurfaceVariant」；裸 Icon 直接用
  /// 环境色，在非顶栏场景（如本地音乐页的工具栏）会比相邻 IconButton 偏黑。
  Color _iconColor(BuildContext context) {
    final theme = Theme.of(context);
    final ambient = IconTheme.of(context).color;
    final isDefaultAmbient = ambient == null ||
        ambient ==
            (theme.brightness == Brightness.dark
                ? Colors.white
                : Colors.black87);
    return isDefaultAmbient ? theme.colorScheme.onSurfaceVariant : ambient;
  }

  /// tv: 遥控下的排序选择弹层，替代触屏用的 [M3EDropdownMenu]。
  ///
  /// 为什么 TV 不能沿用下拉（2026-10-04：歌单页焦点被右上角排序下拉"捕获"，
  /// 其它功能全部选不中）：
  /// 1. 字段是 `Focus(onKeyEvent: …)`，把 ↑/↓/Enter/Space **全部** 判为
  ///    handled（m3e_core `m3e_dropdown_menu.dart:390`）—— 焦点一旦落到排序
  ///    按钮上，方向键就被吞掉，只能靠左右键逃出去；
  /// 2. 面板条目是 `GestureDetector` + `onTap`，不带焦点节点，就算把面板
  ///    拉开了遥控也选不中任何一项。
  ///
  /// 故 TV 构建换成底部弹层，每行一个 [DpadFocusable]：OK 选排序项；
  /// 方向切换用与触屏面板同款的「正序 / 倒序」分段控件。
  Future<void> _openTvSortPicker() async {
    await showM3EModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        // 弹层底是 material_ui 的 Material，下面的行是 flutter/material 的
        // ListTile：同名不同型的 Material 匹配不上，必须自带一层（AGENTS §4.13），
        // 否则 TV 上打开排序弹层会顶出「此处内容加载出错」。
        return Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    widget.tooltip,
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (var i = 0; i < widget.options.length; i++)
                  DpadFocusable(
                    // 弹层首项自动聚焦：一打开就看得见焦点在哪
                    autofocus: i == 0,
                    debugLabel: 'sort_option_$i',
                    onSelect: () {
                      Navigator.pop(ctx);
                      widget.onPicked(widget.options[i].value);
                    },
                    child: ListTile(
                      title: Text(widget.options[i].label),
                      trailing: widget.options[i].value == widget.current
                          ? Icon(Icons.check, color: cs.primary)
                          : null,
                    ),
                  ),
                if (widget.ascending != null) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: _SortDirectionToggle(
                      ascending: widget.ascending!,
                      onChanged: widget.onDirectionChanged!,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // tv: 触屏的下拉在遥控下会吞掉方向键（见 [_openTvSortPicker] 的说明），
    // 这里换成同外观的图标按钮 + 可聚焦弹层。
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'sort_button',
        onSelect: _openTvSortPicker,
        child: SizedBox(
          width: _slot,
          height: _slot,
          child: Icon(widget.icon, size: 24, color: _iconColor(context)),
        ),
      );
    }
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox(
        width: _slot,
        height: _slot,
        child: OverflowBox(
          // 只放开宽度，字段与下拉面板共用宽度。
          minWidth: widget.panelWidth,
          maxWidth: widget.panelWidth,
          minHeight: _slot,
          maxHeight: _slot,
          // 字段与图标位右对齐：图标留在图标位内，多出的宽度从左侧溢出
          alignment: Alignment.centerRight,
          child: M3EDropdownMenu<T>(
            controller: _controller,
            items: [
              for (final option in widget.options)
                M3EDropdownItem<T>(
                  label: option.label,
                  value: option.value,
                  selected: option.value == widget.current,
                ),
            ],
            singleSelect: true,
            showChipAnimation: false,
            // 外层 20 = 条目外角 12 + 列表内边距 8，同心圆（默认 28 过大）
            containerRadius: AppRadius.dropdownPanel,
            // 面板底部独立分组：「正序 | 倒序」分段控件，与上方字段条目区分
            dropdownStyle: M3EDropdownStyle(
              footer: widget.ascending == null
                  ? null
                  : _SortDirectionFooter(
                      ascending: widget.ascending!,
                      onChanged: widget.onDirectionChanged!,
                    ),
            ),
            onSelectionChanged: _handleSelectionChanged,
            // 字段里不显示任何文字，外观只由 suffixIcon 提供
            selectedItemBuilder: (_) => const SizedBox.shrink(),
            fieldStyle: M3EDropdownFieldStyle(
              hintText: widget.tooltip,
              backgroundColor: Colors.transparent,
              // 使用黑色低透明度高亮；组件内部按交互状态重新设置 alpha。
              foregroundColor: Colors.transparent,
              border: BorderSide.none,
              focusedBorder: BorderSide.none,
              // 字段比图标位宽，键盘聚焦时的高亮环同样不需要
              focusRingWidth: 0,
              showArrow: false,
              // 用 suffixIcon 而非 prefixIcon：字段比图标位宽，
              // 只有右端对齐时图标才会落在图标位正中心
              suffixIcon: Icon(
                widget.icon,
                size: 24,
                color: _iconColor(context),
              ),
              // 排序图标不该随面板开合旋转
              animateSuffixIcon: false,
              // 12 内边距 + 24 图标 = 48，与图标位等高，图标垂直居中
              padding: const EdgeInsets.all(12),
            ),
          ),
        ),
      ),
    );
  }
}

/// 下拉面板底部的方向切换区：细分隔线 + 「正序 | 倒序」分段控件，
/// 与上方字段条目列表分组区分；点选只切方向，面板保持打开。
class _SortDirectionFooter extends StatelessWidget {
  final bool ascending;
  final ValueChanged<bool> onChanged;

  const _SortDirectionFooter({required this.ascending, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 8),
          _SortDirectionToggle(ascending: ascending, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 「正序 | 倒序」分段控件：带方向箭头图标，触屏面板与 TV 弹层共用。
class _SortDirectionToggle extends StatelessWidget {
  final bool ascending;
  final ValueChanged<bool> onChanged;

  const _SortDirectionToggle({required this.ascending, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return M3EToggleButtonGroup(
            actions: const [
              M3EToggleButtonGroupAction(
                icon: Icon(Icons.arrow_upward_rounded),
                label: Text('正序'),
              ),
              M3EToggleButtonGroupAction(
                icon: Icon(Icons.arrow_downward_rounded),
                label: Text('倒序'),
              ),
            ],
            size: M3EButtonSize.xs,
            density: M3EButtonGroupDensity.compact,
            style: M3EButtonStyle.outlined,
            selectedIndex: ascending ? 0 : 1,
            onSelectedIndexChanged: (index) {
              if (index == null) return;
              onChanged(index == 0);
            },
          );
  }
}
