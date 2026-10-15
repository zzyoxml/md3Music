// 评论区顶栏：排序分段（最热/最新/最早）+ 范围筛选（全部/歌手/我的）+ 写评论入口。
//
// 从 CommentsView 抽成独立 widget 的两个原因：
// 1. 三个控件的高度口径集中在这里，且只有这一处真值（见 kCommentBarControlHeight）；
// 2. 可脱离评论数据加载单独打 widget 测试。

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/utils/app_haptics.dart';
import '../../widgets/tv_dropdown_menu.dart';
import '../../services/kugou_api/comment_sort.dart';

/// 评论区顶栏三个控件共用的高度（逻辑像素）。
///
/// 三者的内容高度天然不同：排序分段是 M3EButtonSize.xs（32dp），范围下拉是
/// 文字 + 24dp 下拉箭头，写评论是 18dp 图标。不统一时顶栏就是三段错落的锯齿。
/// 这里是唯一真值——分段按钮直接用 [M3EButtonSize.xs]（其 token 高度就是 32），
/// 写评论按钮用它算 [Size.square]，范围下拉用它减掉内容高度得到垂直 padding。
const double kCommentBarControlHeight = 32.0;

/// 范围下拉 field 的内容高度：结尾的下拉箭头是未指定 size 的
/// [Icons.keyboard_arrow_down_rounded]（默认 24dp），行高由它撑着。
const double _kDropdownContentHeight = 24.0;

/// 范围下拉的 field padding：内容高度 + 上下 padding 恒等于
/// [kCommentBarControlHeight]。
const EdgeInsets _kDropdownPadding = EdgeInsets.symmetric(
  horizontal: 10,
  vertical: (kCommentBarControlHeight - _kDropdownContentHeight) / 2,
);

/// 评论区顶栏。
class CommentSortFilterBar extends StatelessWidget {
  const CommentSortFilterBar({
    super.key,
    required this.sortMode,
    required this.onSortModeChanged,
    required this.scope,
    required this.scopeItems,
    required this.onScopeChanged,
    required this.isAmStyle,
    required this.showComposeButton,
    required this.onCompose,
  });

  final CommentSortMode sortMode;
  final ValueChanged<CommentSortMode> onSortModeChanged;

  final CommentScope scope;

  /// 下拉条目。**必须是稳定实例**：M3EDropdownMenu.didUpdateWidget 以
  /// `widget.items != oldWidget.items`（列表同一性）判断是否 setItems，
  /// 每次 build 新建列表会让它恒真 → setItems 在 build 期间回调
  /// onSelectionChanged → setState during build → 语义树无限互递归
  /// （真机 ANR，2026-09-29）。选中态交给 controller 维护，列表只提供初始选中。
  final List<M3EDropdownItem<CommentScope>> scopeItems;

  final ValueChanged<CommentScope> onScopeChanged;

  /// AM 皮肤浮在模糊封面上，跟随主题的分组底色会很突兀，改用半透明白色。
  final bool isAmStyle;

  /// 是否显示右侧「写评论」入口。
  /// 播放器评论 tab 没有内联输入框（CommentsView.showComposer = false），
  /// 右侧提供显式入口；评论托盘里输入框常驻，不显示该按钮。
  final bool showComposeButton;

  final VoidCallback onCompose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          _buildSortGroup(),
          const Spacer(),
          SizedBox(width: 100, child: _buildScopeDropdown()),
          const SizedBox(width: 8),
          if (showComposeButton) _buildComposeButton(),
        ],
      ),
    );
  }

  Widget _buildSortGroup() {
    // AM 皮肤下选中段更亮、未选中段更淡；MD3 走默认分组底色。
    final groupDecoration = isAmStyle
        ? M3EToggleButtonDecoration(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? const Color(0x2EFFFFFF)
                  : const Color(0x14FFFFFF),
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.white
                  : const Color(0xB3FFFFFF),
            ),
          )
        : null;
    return M3EToggleButtonGroup(
      decoration: groupDecoration,
      actions: const [
        M3EToggleButtonGroupAction(label: Text('最热')),
        M3EToggleButtonGroupAction(label: Text('最新')),
        M3EToggleButtonGroupAction(label: Text('最早')),
      ],
      // xs 的 token 高度就是 32dp，与 kCommentBarControlHeight 一致；
      // 若将来 m3e_core 改了 xs 高度，这里要同步改常量（widget 测试会挡住）。
      size: M3EButtonSize.xs,
      density: M3EButtonGroupDensity.compact,
      selectedIndex: sortMode.index,
      onSelectedIndexChanged: (index) {
        if (index == null) return;
        onSortModeChanged(CommentSortMode.values[index]);
      },
    );
  }

  Widget _buildScopeDropdown() {
    return TvDropdownMenu<CommentScope>(
      items: scopeItems,
      singleSelect: true,
      showChipAnimation: false,
      onSelectionChanged: (selected) {
        if (selected.isEmpty) return;
        final value = selected.first.value;
        // 不在这里做「同值忽略」：controller 里注册的回调不会随 build 更新，
        // 闭包捕获的 [scope] 可能是旧值，守卫会失效。改由 CommentsView 读实时
        // 字段判断（见 _onScopeSelected 的注释）。
        AppHaptics.selectionClick(HapticCategory.control);
        onScopeChanged(value);
      },
      fieldStyle: isAmStyle
          ? const M3EDropdownFieldStyle(
              padding: _kDropdownPadding,
              backgroundColor: Color(0x14FFFFFF),
              // 前景色同时驱动下拉箭头（fgColor），AM 皮肤下要求白色
              foregroundColor: Colors.white,
              border: BorderSide.none,
              focusedBorder: BorderSide.none,
              selectedTextStyle: TextStyle(color: Colors.white, fontSize: 12),
              hintStyle: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
            )
          : const M3EDropdownFieldStyle(padding: _kDropdownPadding),
    );
  }

  Widget _buildComposeButton() {
    return M3EFilledButton(
      onPressed: onCompose,
      tooltip: '写评论',
      decoration: isAmStyle
          ? M3EButtonDecoration(
              padding: EdgeInsets.zero,
              // fixedSize 单独用**压不小**：minimumSize 默认是 48×40
              // （m3e_button.dart:323），而 BoxConstraints.constrain 只会向上钳，
              // 于是 fixedSize 的 32 被抬回 48；tapTargetSize 默认 padded 再叠
              // 48×48 底线。必须两个一起补齐，才真的等于 kCommentBarControlHeight。
              // 与 M3EToggleButton 内部的处理一致（它硬编码 shrinkWrap）。
              fixedSize: Size.square(kCommentBarControlHeight),
              minimumSize: Size.square(kCommentBarControlHeight),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: WidgetStateProperty.all(
                const Color(0x1FFFFFFF),
              ),
              foregroundColor: WidgetStateProperty.all(Colors.white),
            )
          : const M3EButtonDecoration(
              padding: EdgeInsets.zero,
              fixedSize: Size.square(kCommentBarControlHeight),
              minimumSize: Size.square(kCommentBarControlHeight),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
      semanticLabel: '写评论',
      child: const Icon(Icons.edit_outlined, size: 18),
    );
  }
}