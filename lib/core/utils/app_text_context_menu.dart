import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as mu;

import 'app_toast.dart';

/// 输入框长按上下文菜单：只要框可编辑就始终给出「粘贴」，按下才读剪贴板。
///
/// 框架默认把粘贴项挂在 `Clipboard.hasStrings()` 的预探测结果上
/// （EditableTextState.pasteEnabled）。空输入框没有选区，粘贴是唯一候选按钮，
/// 预探测一旦返回 false/null 或被 ROM 拦截，按钮列表为空 → 整条菜单不弹，
/// 用户看到的就是"长按完全没反应"。Android 允许用户在上下文菜单中主动发起
/// 粘贴，所以正确做法是按钮常显、把读取推迟到按下时。
///
/// 接法：`TextField(contextMenuBuilder: buildAppTextContextMenu)`。
/// material_ui 1.3.0 的 TextField 不支持 EditableTextConfigurator 全局注入，
/// 因此必须逐调用点接线（守卫测试 test/core/utils/
/// text_field_context_menu_guard_test.dart 负责锁死）。
///
/// 按钮文本统一为中文：框架默认取 `MaterialLocalizations` 的英文（本 App 未接
/// `GlobalMaterialLocalizations`，不会跟随系统语言），故在传入工具条前逐项
/// 补中文 label（[contextMenuZhLabel]）。
///
/// 返回类型必须是 `Widget`（非空）：Flutter 3.47.5 的 EditableTextContextMenuBuilder
/// typedef 返回 `Widget`（editable_text.dart:99-100），且 showToolbar() 无条件调用
/// 该 builder（editable_text.dart:5202）——本版本没有"返回 null 即隐藏菜单"的契约。
/// 因此零按钮项时返回零尺寸控件：返回空工具条会在只读框上画出一个没有按钮的气泡。
Widget buildAppTextContextMenu(BuildContext context, EditableTextState state) {
  // 框架生成的按钮项一律不带 label，渲染时回退 MaterialLocalizations 英文
  // （Cut/Copy/Paste/Select All…），这里统一换成中文再交给工具条。
  final List<ContextMenuButtonItem> items = state.contextMenuButtonItems
      .map((ContextMenuButtonItem item) => item.copyWith(
            label: contextMenuZhLabel(item),
          ))
      .toList();
  // state.widget.readOnly 同时覆盖 TextField 的 readOnly:true 与 enabled:false
  // （material_ui text_field.dart:1704 传的是 widget.readOnly || !_isEnabled）。
  final bool canPaste = !state.widget.readOnly;
  final bool alreadyHasPaste = items.any(
    (ContextMenuButtonItem item) => item.type == ContextMenuButtonType.paste,
  );
  if (canPaste && !alreadyHasPaste) {
    items.insert(
      0,
      ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        label: '粘贴',
        onPressed: () => _pasteNow(state),
      ),
    );
  }
  // 零按钮项（只读框/禁用框且框架没给任何项）也要返回非空 Widget，
  // 用零尺寸控件而不是空工具条，避免画出一个没有按钮的气泡。
  if (items.isEmpty) {
    return const SizedBox.shrink();
  }
  return mu.AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: items,
  );
}

/// 上下文菜单按钮的中文标签。
///
/// 已自带 label 的项是系统注册的文本处理动作（`ProcessTextAction`，label 即
/// 动作名，如第三方「翻译」），原样保留不翻译；其余按 [ContextMenuButtonType]
/// 映射中文（与项目既有 UI 文案一致，如列表页「全选」）。
///
/// `custom` 且无 label 的项返回 null：框架对该类型本就渲染空文本。
String? contextMenuZhLabel(ContextMenuButtonItem item) {
  if (item.label != null) {
    return item.label;
  }
  return switch (item.type) {
    ContextMenuButtonType.cut => '剪切',
    ContextMenuButtonType.copy => '复制',
    ContextMenuButtonType.paste => '粘贴',
    ContextMenuButtonType.selectAll => '全选',
    ContextMenuButtonType.delete => '删除',
    ContextMenuButtonType.lookUp => '查询',
    ContextMenuButtonType.searchWeb => '网页搜索',
    ContextMenuButtonType.share => '分享',
    ContextMenuButtonType.liveTextInput => '扫描文本',
    ContextMenuButtonType.custom => null,
  };
}

/// 按下「粘贴」后执行：先读一次剪贴板用于如实反馈，再交给框架完成插入。
Future<void> _pasteNow(EditableTextState state) async {
  final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
  final String? text = data?.text;
  if (text == null || text.isEmpty) {
    showToast('剪贴板没有可粘贴的文本');
    return;
  }
  if (!state.mounted) {
    return;
  }
  // 未经点击聚焦的空输入框可能没有有效选区，而 EditableTextState.pasteText
  // 的前置条件就是 selection.isValid（editable_text.dart:2840）。
  final TextEditingValue value = state.textEditingValue;
  if (!value.selection.isValid) {
    state.userUpdateTextEditingValue(
      value.copyWith(selection: TextSelection.collapsed(offset: value.text.length)),
      SelectionChangedCause.tap,
    );
  }
  // 框架自己会再次读剪贴板并处理光标/滚动/onChange，不在此重复实现。
  state.pasteText(SelectionChangedCause.toolbar);
}
