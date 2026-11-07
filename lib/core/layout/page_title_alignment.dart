/// 页面标题对齐的全局判定逻辑（所有页面统一走这里，不要各页面自己写死）。
///
/// 规则：
/// - **已固定页面**：页面对应的 tab 当前在底部导航栏可直达，且正以一级页面形态
///   呈现（位于路由栈底的主布局内）→ 标题**左对齐**（无返回键，标题起头即页面
///   起头，符合 M3 顶栏惯例）；
/// - **二级页面**：push 出来的路由（详情页、tab 被隐藏后从 LaunchPad / 桌面快捷
///   方式打开的功能页、设置页内部子分区等）→ 标题**居中对齐**（与左侧返回键、
///   右侧 actions 视觉配平）。
///
/// 两个条件缺一不可：
/// - 只看路由栈不够：新手引导 / 用户协议页同样是栈底路由，但并非导航栏页面；
/// - 只看 tab 配置不够：设置页等 tab 可见时仍可能被 push 成二级页面呈现。
///
/// 全局 `appBarTheme.centerTitle` 已是 `true`（居中），因此从来不作为 tab 出现的
/// 页面无需调用本文件的方法，天然居中。
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/tab_config_provider.dart';

/// 当前页面是否以「二级页面」形态呈现，即位于路由栈里 push 出来的非栈底路由
/// （详情页、tab 被隐藏后从 LaunchPad / 桌面快捷方式打开的功能页、设置子分区等）。
///
/// 这只是「有没有被 push 出来」这一条**路由栈事实**，不等于「二级页面」——
/// 完整判据还要看该页是不是导航栏里固定的一级 tab（见 [isPrimaryNavTab]）。
/// 本函数被以下三处共用：
/// - 标题对齐（[isPinnedNavPage] / [centerPageTitle]）：二级页面标题居中；
/// - 播放栏形态（`SecondaryMiniPlayerHost`）：二级页面用悬浮播放栏，一级页面
///   由主布局底部常驻 `MiniPlayer` 承载；
/// - 底部导航栏显隐（经 [isPrimaryNavPage] 的壳层等价形式，见
///   `ResponsiveShell.onSecondaryRouteChanged`）。
///
/// 栈底主布局内（`route.isFirst`）视为一级形态；`route` 为空（无路由环境，
/// 如测试）同样按一级形态处理。必须在 build 内调用（依赖 [ModalRoute]）。
bool isSecondaryRoutePage(BuildContext context) {
  final route = ModalRoute.of(context);
  return route != null && !route.isFirst;
}

/// 当前页面是否为「已固定」的一级导航页面（底部导航栏可直达）。
///
/// [tabId] 是页面在 [TabConfigProvider] 中的 tab id（取值见 [kAllAvailableTabs]）；
/// 从来不作为 tab 出现的页面传 `null`，恒返回 false。
///
/// 必须在 build 内调用：内部 watch [TabConfigProvider]，用户在设置页开关/排序
/// tab 后会自动重算对齐方式。
bool isPinnedNavPage(BuildContext context, [String? tabId]) {
  if (tabId == null || tabId.isEmpty) return false;
  // 二级页面（push 出来的路由）一律不算已固定，即使其 tab 同时可见
  if (isSecondaryRoutePage(context)) return false;
  return context.watch<TabConfigProvider>().visibleIndexOf(tabId) >= 0;
}

/// `AppBar.centerTitle` 的统一取值：已固定的一级页面左对齐，其余居中。
///
/// ```dart
/// AppBar(
///   centerTitle: centerPageTitle(context, tabId: 'settings'),
///   title: const Text('设置'),
/// )
/// ```
bool centerPageTitle(BuildContext context, {String? tabId}) =>
    !isPinnedNavPage(context, tabId);

/// **一级页面**的权威判据（纯数据侧）：标题左对齐才算一级页面。
///
/// 三条同时成立才算一级：
/// - [tab] 非 null —— 该页当前在底部导航栏里有固定入口（不在导航栏里的页面
///   从来不作为 tab 出现，一律按二级处理）；
/// - [TabItem.pinnedTitle] 为真 —— 该 tab 的标题**左对齐**（无返回键）；
/// - [pushedRoute] 为假 —— 没有被 push 出更深的页面。
///
/// 一级 ⇔ 底部导航栏在场、播放条能「固定在菜单栏」上方常驻；二级（及以后）
/// ⇔ 导航栏收起、播放条改用悬浮胶囊。这两件事必须共用本函数，否则会出现在
/// 同一页上「底栏按一级留着、播放条按二级悬浮并随滚动收缩」的矛盾状态
/// （排行榜 / 搜索 / 本地音乐 这类**标题居中**的 tab 正是分歧点）。
///
/// 两个调用方按各自能拿到的输入使用，结论必须一致：
/// - 播放栏宿主用 [isPrimaryNavPage]（有 BuildContext，自己取路由栈事实）；
/// - 底部导航栏由 `ResponsiveShell` 取齐两条路由事实（中央 Navigator 深度 + 双栏
///   tab 单栏态独占整宽的详情面板）后调用本函数定级，再上报给主布局
///   （见 `app.dart` 的 `hideNavigation`）。
bool isPrimaryNavTab(TabItem? tab, {required bool pushedRoute}) =>
    !pushedRoute && (tab?.pinnedTitle ?? false);

/// [isPrimaryNavTab] 的 BuildContext 版：自动从 [TabConfigProvider] 查 [tabId]
/// 对应的可见 tab，并用 [isSecondaryRoutePage] 取「是否被 push 出来」。
///
/// 与 [centerPageTitle] 同源，但只认 [TabItem.pinnedTitle]（= 该 tab 的页面确实
/// 给 AppBar 传了 tabId、标题左对齐），因此比 [isSecondaryRoutePage]（只看栈底路由）
/// 更严：排行榜 / 搜索 / 本地音乐 这些**标题居中**的 tab 页一律算二级页面。
///
/// 用途：悬浮播放器的"一级页面不回缩"等外壳级形态决策（见
/// `SecondaryMiniPlayerHost._buildHost`）。这些逻辑要跟随的是**用户看到的页面层级**
/// （有无返回键、标题是否起头），而不是路由栈深度。
///
/// 必须在 build 内调用：内部 watch [TabConfigProvider]。
bool isPrimaryNavPage(BuildContext context, String? tabId) {
  // 先取路由事实：已经确定是二级页面时不再查 tab 表，避免在二级路由上建立
  // 对 [TabConfigProvider] 的依赖（用户重排/显隐 tab 会连带重建这些页面）。
  final pushedRoute = isSecondaryRoutePage(context);
  if (pushedRoute) return false;
  return isPrimaryNavTab(_visibleTabById(context, tabId), pushedRoute: false);
}

/// 按 tab id 取当前导航栏里的 [TabItem]；id 为空或该 tab 未显示时返回 null。
///
/// 在 build 内调用会 watch [TabConfigProvider]，用户开关/排序 tab 后自动重算。
TabItem? _visibleTabById(BuildContext context, String? tabId) {
  if (tabId == null || tabId.isEmpty) return null;
  final tabs = context.watch<TabConfigProvider>().visibleTabs;
  final index = tabs.indexWhere((t) => t.id == tabId);
  return index >= 0 ? tabs[index] : null;
}
