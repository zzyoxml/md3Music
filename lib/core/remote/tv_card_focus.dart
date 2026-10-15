import 'package:dpad/dpad.dart';
import 'package:flutter/widgets.dart';

import '../build_flags.dart';

/// TV 构建下的「可点卡片/行」焦点停点包装。
///
/// 本仓口径（AGENTS §0.5）：每个可点卡片/行/按钮都要有一个 `DpadFocusable`
/// 单停点，`onSelect` 接原来的 `onTap`、`onLongSelect` 接原来的 `onLongPress`。
/// 裸 `InkWell` 卡片不满足这条：它 `enableFocusHighlight` 默认 false，
/// 落到它身上时卡片自身**没有任何聚焦反馈**，dpad 的聚焦特效与 `onSelect`
/// 链路也不归它管，真机表现为「焦点落不下去」——
/// 2026-10-08 频道详情页相似频道带、场景专区「音乐/歌单/视频」标签带即此缺陷
/// （上方的 ListTile 行能选，行是自带聚焦反馈与 ActivateIntent 的 Material 组件）。
///
/// `DpadFocusable` 的 `excludeChildFocus` 默认 true，内层 InkWell 会被
/// `ExcludeFocus` 关掉，**不会**产生第二个停点，因此调用方不需要
/// `canRequestFocus: false` 之类的手法。
///
/// 刻意不默认开启 [autofocus]：卡片位于懒加载列表里，异步数据到达/重建时
/// autofocus 会抢焦点（AGENTS §12.4 规则 7）。进页首落点交给 dpad 自己的
/// `_focusInitial`（取 scope 内的初始候选）。只有「画面里本就只有一个活动项」
/// 的场景（如刷刷竖屏流的当前视频格）才传 `autofocus: isActive`。
///
/// 非 TV 构建（`kTvBuild` 为 const false，AOT 树摇）原样返回 child，零开销；
/// `onSelect`/`onLongSelect` 全为 null 时同样原样返回（不制造死停点）。
class TvCardFocus extends StatelessWidget {
  final VoidCallback? onSelect;
  final VoidCallback? onLongSelect;

  /// 焦点排障用的标签（出现在 dpad 调试叠层与 TvFocusDebug 日志里）。
  final String? debugLabel;

  /// 页面需要**程序化移交焦点**时传入自有节点（如切页后把焦点交给新的活动格）。
  /// 生命周期归调用方，必须自行 dispose。
  final FocusNode? focusNode;

  final bool autofocus;

  final Widget child;

  const TvCardFocus({
    super.key,
    this.onSelect,
    this.onLongSelect,
    this.debugLabel,
    this.focusNode,
    this.autofocus = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!kTvBuild) return child;
    // 两个动作都没有时不制造「死停点」：遥控焦点落上去却什么都做不了，
    // 比根本没有这个停点更难排查（调用方常见于 onTap 可空的卡片）。
    if (onSelect == null && onLongSelect == null) return child;
    return DpadFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      debugLabel: debugLabel,
      onSelect: onSelect,
      onLongSelect: onLongSelect,
      child: child,
    );
  }
}
