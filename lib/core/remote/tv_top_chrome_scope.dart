import 'package:flutter/widgets.dart';

/// tv: 顶栏 chrome 作用域标记（第一层：头像胶囊 / MiniPlayer / 搜索按钮）。
///
/// 存在的唯一理由：`ResponsiveShell` 的焦点校正（`_isFocusUsable`）要把
/// 「焦点在持久顶栏上」判为合法落点——否则路由事件触发的校正会把用户从
/// MiniPlayer / 头像 / 搜索上拽回内容区（顶栏在 tab 的 Navigator scope 之外，
/// 与导航栏节点同理）。用作用域标记而非逐个登记节点，是因为 MiniPlayer 内部
/// 的播放/暂停按钮节点不由本工程持有（IconButton 自建）。
class TvTopChromeScope extends InheritedWidget {
  const TvTopChromeScope({super.key, required super.child});

  @override
  bool updateShouldNotify(TvTopChromeScope oldWidget) => false;

  /// [node] 是否位于顶栏 chrome 子树内（供焦点校正判定）。
  static bool contains(FocusNode node) {
    final BuildContext? context = node.context;
    if (context == null) return false;
    return context
            .getElementForInheritedWidgetOfExactType<TvTopChromeScope>() !=
        null;
  }
}
