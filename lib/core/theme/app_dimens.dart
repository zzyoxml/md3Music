import 'package:material_ui/material_ui.dart';

/// 全局尺寸设计 token（间距 / 圆角 / 布局约束）。
///
/// 目标：把散落在各页面的行内魔法数字（`EdgeInsets.all(16)`、
/// `SizedBox(height: 12)`、`BorderRadius.circular(8)`…）收敛到一套**等比**尺度，
/// 让间距、圆角、留白节奏在全项目一致、可扫描、可整体调整。
///
/// 设计理念：
/// - **4dp 基准、8dp 节奏**（8pt grid，允许 4dp 半档）。所有值都落在 4 的倍数上，
///   避免 6 / 10 / 14 / 18 这类离格值造成的视觉抖动。
/// - **语义命名**（xs / sm / md / lg / xl…）而非裸数字：迁移时强制在有限档位里
///   做选择，天然收敛不一致。
/// - **纯 dp**：全局「显示大小」由 [DisplayScaleScope]（ui_density.dart）统一缩放，
///   token 一律写裸 dp，不要在这里做任何缩放。
///
/// 迁移约定：`EdgeInsets.all(16)` → `EdgeInsets.all(AppSpacing.lg)`；
/// `SizedBox(height: 12)` → `const Gap(AppSpacing.md)` 或 `SizedBox(height: AppSpacing.md)`。
class AppSpacing {
  AppSpacing._();

  /// 0dp —— 显式表达"无间距"，比裸 0 更有意图。
  static const double none = 0;

  /// 2dp —— 极小间距：图标与文字、徽标内缩等。
  static const double xxs = 2;

  /// 4dp —— 基准单位：紧凑元素间的最小呼吸。
  static const double xs = 4;

  /// 8dp —— 小间距：列表项内垂直间距、chip 间距。
  static const double sm = 8;

  /// 12dp —— 中小间距：卡片内边距、段内元素间距。
  static const double md = 12;

  /// 16dp —— 标准间距：页面左右边距、Section 内边距（默认首选值）。
  static const double lg = 16;

  /// 24dp —— 大间距：Section 之间、主要内容块的分隔。
  static const double xl = 24;

  /// 32dp —— 超大间距：页面顶部留白、主要分区之间的强分隔。
  static const double xxl = 32;

  /// 48dp —— 巨大间距：空状态居中留白、大屏分区。
  static const double xxxl = 48;
}

/// 圆角 token，对齐 Material 3 shape scale（extra-small 4 → extra-large 28）。
///
/// 迁移约定：`BorderRadius.circular(8)` → `AppRadius.smAll`（或 `AppRadius.sm`
/// 在需要 double 的场景）。
class AppRadius {
  AppRadius._();

  static const double xs = 4;

  /// 封面圆角档（6dp）——底栏封面（常驻迷你条 44 / 桌面栏 48）的 clip 半径。
  ///
  /// **为什么单列一档**：6 是本文件设计理念明令避开的离格值，所以 M3 shape scale
  /// 里（xs 4 / sm 8）没有语义相符的档位可复用；而底栏四处封面 clip 历史上恒为 6，
  /// 几何收口（批次 3 第 11 项）的口径是「纯迁移、不改取值」，
  /// 既不能把它并进 xs(4) 或 sm(8)（会改变观感），也不能换成 6.5 之类的近似值。
  /// 故按**用途**命名而不是按数字命名；日后若要真正对齐 8pt 网格，
  /// 那是一次独立的视觉变更，需真机验收，不在收口范围内。
  static const double cover = 6;

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 28;

  /// 下拉面板外层圆角（20dp）——与面板内条目保持同心圆。
  ///
  /// m3e_core 的 `M3EDropdownMenu.containerRadius` 默认 28，但面板内列表
  /// `contentPadding` 为 8、首尾条目外角 `outerRadius` 为 12，同心圆条件是
  /// 外半径 = 内半径 + 间距 = 12 + 8 = 20；28 会让外层明显比内部更圆。
  static const double dropdownPanel = 20;

  /// 胶囊 / 全圆角（配合 [StadiumBorder] 或极大半径）。
  static const double full = 999;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius coverAll = BorderRadius.all(Radius.circular(cover));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
}

/// 胶囊 / 小徽章的几何刻度（沿用本文件的 4dp 基准、8dp 节奏）。
///
/// 之前同类小标签有三处各写各的：顶栏尾部胶囊 36 高 / 图标 20、播放页音质徽章
/// 内衬 8×4 / 图标 14、发现页问候胶囊 32 / 图标 16 —— 14 与 10 都是本文件明令
/// 避开的离格值，而同一类信息在三个页面上大小不一。收敛成两档：
///
/// - **[badgeSize]** 徽章档：只读或一次性的小徽章（车机面板进度条时间行上的
///   音质徽章、发现页问候胶囊）。整颗 32 高，图标方块 32×32 内含 16 的图标。
/// - **[cellHeight]** 格子档：顶栏那颗连体胶囊里的一格（可点的图标格）。
///   视觉 32 高、热区 [cellTouchHeight] 40、图标格宽 40、图标 20。
///
/// 两档的文案内衬（[labelLeftPad] / [labelRightPad]）刻意同值：文字与图标、
/// 与胶囊右端的关系是同一个视觉问题，不该随高度换一套数字。
class AppCapsule {
  AppCapsule._();

  /// 徽章档：胶囊高度 = 图标方块边长。
  static const double badgeSize = 32;

  /// 徽章档的图标尺寸。
  static const double badgeIcon = 16;

  /// 格子档：胶囊**视觉**高度。
  ///
  /// 与 [badgeSize] 同值（32）：竖屏顶栏那颗 40 高时，顶栏行高由 IconButton 的
  /// 48 决定，胶囊上下各只剩 4dp，看着就是「贴着边、很挤」。压到 32 后上下各
  /// 8dp，与发现页问候胶囊一个量级。
  static const double cellHeight = 32;

  /// 格子档：每一格的**触控**高度，比视觉高出 4dp 一圈（上下各 4）。
  ///
  /// 视觉缩了不能顺手把热区也缩掉：40×32 距离 Material 的 48 地板更远。
  /// 横向没法扩（相邻格零间距，热区互扩会互相抢点击），纵向可以——
  /// 于是视觉 32、热区 40，两头都不退让。
  static const double cellTouchHeight = 40;

  /// 热区高出视觉的那一半（上下各这些）。
  static const double cellTouchPad = (cellTouchHeight - cellHeight) / 2;

  /// 格子档的图标格宽度（与 [cellHeight] 同值）。
  static const double cellIconBox = 40;

  /// 格子档的图标尺寸。
  static const double cellIcon = 20;

  /// 文案段左内衬：图标方块本身已带 (尺寸 − 图标) / 2 的余量，补 2 与右端均衡。
  static const double labelLeftPad = 2;

  /// 文案段右内衬（胶囊右端半圆之前的呼吸位）。
  static const double labelRightPad = 12;
}

/// 大屏 / 平板布局约束 token。
///
/// 「重组而非拉伸」原则：宽屏下不让内容行 / 文本无脑撑满，而是约束到一个
/// 可读宽度并居中，多出来的宽度用于分栏或留白。
class AppLayout {
  AppLayout._();

  /// 手机原有单栏宽度上限；大屏以此为基准，通过 contentWidthFor 扩展。
  static const double maxContentWidth = 840;

  /// 大屏内容占局部可用宽度的 85%；窄面板不缩窄，手机沿用原限宽。
  static double contentWidthFor(double width, {
    double compactWidth = maxContentWidth, bool adaptive = true,
  }) {
    if (!width.isFinite) return compactWidth;
    if (width <= compactWidth) return width;
    if (!adaptive) return compactWidth;
    return (width * 0.85).clamp(compactWidth, width);
  }

  /// 正文文本的舒适阅读宽度上限（歌词、长段描述），约 60–75 字符行长。
  static const double readableMaxWidth = 640;

  /// 网格每列的目标宽度（配合 [gridColumnsForWidth]）。
  static const double gridTargetExtent = 200;

  /// 双列（列表-详情）左列固定宽度。M3 list-detail master pane 推荐 280–300dp。
  static const double twoPaneMasterWidth = 300;

  /// 双列右列内容的最大宽度：超过就居中留白，与 [maxContentWidth] 同一
  /// 「重组而非拉伸」原则（约等于 MD3 body pane 在双列下的舒适上限）。
  static const double twoPaneDetailMaxWidth = 720;
}

/// 等距方形间隔组件，替代裸 `SizedBox(height: x)` / `SizedBox(width: x)`。
///
/// 同时设置宽高为 [extent]，在 [Column] 与 [Row] 中都能正确撑出间距
/// （Flex 交叉轴方向的固定尺寸无副作用）。需要非方形间隔时仍直接用 `SizedBox`。
class Gap extends StatelessWidget {
  const Gap(this.extent, {super.key});

  final double extent;

  @override
  Widget build(BuildContext context) => SizedBox(width: extent, height: extent);
}
