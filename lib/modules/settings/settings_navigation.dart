// 设置页三级导航模型与层级解析。
//
// 层级：总览（1）→ 分类详情（2）→ 分类子页（3）。
// 二级页承载「三级入口列表 + 少量内联短分组」，三级页承载某个功能域的完整设置项。
//
// 本文件只放模型与纯函数，不依赖任何 Provider，便于单测。

import 'package:material_ui/material_ui.dart';

/// 三级页面（分类下的一个功能子域）。
class SettingsSubpage {
  const SettingsSubpage({
    required this.title,
    required this.icon,
    required this.description,
    required this.builder,
  });

  /// 子页标题，同时作为导航键（同一分类内唯一）
  final String title;

  /// 二级页入口行与（预留的）子页标题区图标
  final IconData icon;

  /// 二级页入口行的副标题
  final String description;

  /// 三级页内容构建器。由设置页 State 提供，可访问其全部本地状态与仓储。
  final Widget Function(ColorScheme colorScheme) builder;
}

/// 二级页面（设置分类）。
class SettingsCategory {
  const SettingsCategory({
    required this.title,
    required this.icon,
    required this.description,
    this.leading,
    this.body,
    this.subpages = const <SettingsSubpage>[],
  });

  /// 分类标题（二级页 AppBar 标题、搜索索引的 category 字段）
  final String title;

  /// 分类总览入口行图标
  final IconData icon;

  /// 分类总览入口行副标题；空串表示不显示副标题
  final String description;

  /// 二级页在三级入口列表**之前**渲染的内容；null 表示入口列表置顶。
  /// 目前仅「播放页样式」使用（风格选择卡决定其余项可用性，必须常驻可见，见 R3）。
  final Widget Function(ColorScheme colorScheme)? leading;

  /// 二级页在三级入口列表**之后**渲染的内容。
  /// 有子页时这里放 1–2 项的内联短分组；无子页时这里就是二级页的全部内容。
  final Widget Function(ColorScheme colorScheme)? body;

  /// 三级子页列表；为空表示该分类不下钻（私有构建注入的分类走此路径）。
  final List<SettingsSubpage> subpages;

  bool get hasSubpages => subpages.isNotEmpty;

  /// 按标题查子页；未命中或入参为 null 时返回 null
  /// （防御性：状态与模型不同步时降级为渲染二级页，不抛异常）。
  SettingsSubpage? subpageNamed(String? title) {
    if (title == null) return null;
    for (final subpage in subpages) {
      if (subpage.title == title) return subpage;
    }
    return null;
  }
}

/// 旧扩展点 `SettingsPage.extraCategories` 的 record 转新模型。
/// 私有构建注入的分类没有子页，二级页直接渲染其内容（行为与改造前一致）。
SettingsCategory settingsCategoryFromLegacy(
  (String, IconData, Widget Function(ColorScheme)) record,
) {
  final (title, icon, builder) = record;
  return SettingsCategory(
    title: title,
    icon: icon,
    description: '',
    body: builder,
  );
}

/// 设置页当前所在层级。
enum SettingsLevel { overview, category, subpage }

/// 由当前导航状态解析层级（纯函数）。
SettingsLevel resolveSettingsLevel({
  required String? category,
  required String? subpage,
}) {
  if (category == null) return SettingsLevel.overview;
  if (subpage == null) return SettingsLevel.category;
  return SettingsLevel.subpage;
}

/// 计算返回键的目标层级：三级→二级→总览；总览页返回 null（交还系统处理）。
({String? category, String? subpage})? settingsBackTarget({
  required String? category,
  required String? subpage,
}) {
  if (category == null) return null;
  if (subpage != null) return (category: category, subpage: null);
  return (category: null, subpage: null);
}

/// 设置页 Pad 双列视图开关（纯函数，便于单测）。
///
/// 三个条件同时满足才出「左列分类 + 右列内容」双列：
/// - [padLayout]：大屏设备判定，由调用方用 `isPadLayout(context)` 求值
///   （手机横屏宽度再大也返回 false，不触发双列）；
/// - [desktopLayout]：桌面外壳开启时恒单列 —— 横屏平板重设计计划 4.4
///   把设置页归为 A 类（中央内容区导航），桌面形态不引入双栏；
/// - [width] ≥ 600：Pad 竖屏（逻辑宽 ≈853）也出双列；「显示大小」调大后
///   视口跌出 600 回落单列，与 `isPadLayout` auto 判定口径一致。
bool settingsUseTwoPaneLayout({
  required bool padLayout,
  required double width,
  bool desktopLayout = false,
}) {
  return padLayout && !desktopLayout && width >= 600;
}
