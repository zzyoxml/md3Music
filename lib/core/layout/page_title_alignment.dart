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
  final route = ModalRoute.of(context);
  if (route != null && !route.isFirst) return false;
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
