/// 底部 chrome（常驻迷你条 / 二级悬浮播放器 / 桌面播放栏 / 底部导航栏）的
/// 跨文件几何常量。
///
/// **为什么收口到这里**：44 / 64 / 72 / 76 / 400 这组数值此前散落在
/// `modules/player/secondary_mini_player.dart`、`mini_player.dart`、
/// `now_playing_bar.dart` 与 `core/layout/responsive_layout.dart` 里各自裸写，
/// 同一个"底栏几何"没有一处共同口径（批次 3 第 11 项）。本文件**只做命名迁移，
/// 取值与迁移前逐字节一致**；任何"顺手改成更合理的值"都属于行为变更，不在这里发生。
///
/// **命名口径**：按语义命名（谁用它、为什么是这个值），不按数字命名
/// （禁止 `kSize44` 一类）。同名不同义的数值**分开命名**，不强行合并
/// （例如 64 既是悬浮条圆盘直径、又是底栏显示标签时的高度、又是导航胶囊宽，
/// 三者毫无关系，故三个独立常量）。
///
/// **纯 dp**：全局「显示大小」由 `DisplayScaleScope`（`ui_density.dart`）统一缩放，
/// 这里的值一律写裸 dp，不做任何缩放（与 `app_dimens.dart` 同一约定）。
class BottomChromeDimens {
  BottomChromeDimens._();

  /// 常驻迷你条（`MiniPlayer`）的封面边长（dp，正方形）。
  ///
  /// 用在封面的 `SizedBox` 宽高与 `SmartArtworkImage` 的解码 `size` 三处，
  /// 三者必须同值——否则解码尺寸与实际显示盒子不一致会重新采样发糊。
  /// 同时是封面形变（`CoverGeometryProbe` 上报给 `PlayerCoverMorphBus`）的
  /// 起飞矩形大小，即播放页封面形变的起点几何。
  static const double miniPlayerCoverSize = 44.0;

  /// 二级悬浮播放器的圆盘直径（dp，同时是收起态圆盘的边长与展开态胶囊的高度）。
  ///
  /// 悬浮条在「圆角胶囊 ↔ 圆盘」之间形变，两种形态共用这一个恒定尺寸：收起态
  /// 就是直径 64 的正圆，展开态宽由视口/Pad 上限决定而**高度**仍是 64。
  /// 圆角半径由它推导（`_disc / 2`，见 `secondary_mini_player.dart`），
  /// 故本常量是那两套形态共用的唯一真值。
  static const double discDiameter = 64.0;

  /// 桌面外壳「正在播放」栏（`NowPlayingBar`）的固定高度（dp）。
  ///
  /// 不含顶部分隔线（`Divider` 高 1）。`bottom_chrome_sink.dart` 的
  /// `PlayerPanelSignal.fallbackBarHeight` 取的就是这一个值（锚点未登记时
  /// 合成兜底迷你条用），两处必须同源——否则面板下沿与底栏位移会对不上。
  static const double nowPlayingBarHeight = 72.0;

  /// 二级悬浮播放器为 body 内容预留的底部高度（dp）。
  ///
  /// = 圆盘/胶囊直径 [discDiameter]（64）+ 悬浮条的底部内边距 12；
  /// 悬浮条贴底渲染，内容页底部要让出这一整段，否则最后一行会被遮住。
  static const double discReservedBottom = 76.0;

  /// Pad 下二级悬浮播放器轨道的**最大宽度**（dp，即展开态胶囊宽上限）。
  ///
  /// 手机上的可用宽度（视口 − 左右各 16）约 368dp，胶囊内 4 个元素
  /// （封面 / 标题·艺人 / 播放暂停 / 切歌）的排布以此为基准，故 Pad 上取同量级的
  /// 400dp：既避免"横贯全屏的长条"，也不改变内部排布。
  static const double discTrackMaxWidth = 400.0;

  /// 底部导航栏在「仅图标」（`labelBehavior == alwaysHide`）时的高度（dp）。
  ///
  /// Material 默认 `NavigationBar` 高 80，本仓压到 44 让底栏在仅图标时更紧凑；
  /// 该值同时进入底栏槽位高（`barHeight + MediaQuery.padding.bottom`），
  /// 因此它决定 body 的可用高度，不只是导航栏自身的外观。
  static const double navBarIconOnlyHeight = 44.0;

  /// 底部导航栏在「显示文字」（alwaysShow / onlyShowSelected）时的高度（dp）。
  ///
  /// 同样是从默认 80 压下来的紧凑档：比 [navBarIconOnlyHeight] 高 20，
  /// 刚好容纳 icon + label。与 [navBarIconOnlyHeight] 一样参与底栏槽位高计算。
  static const double navBarWithLabelHeight = 64.0;

  /// 导航项选中胶囊（`_CapsuleBounce`）的宽度（dp）。
  ///
  /// 与 M3 `NavigationIndicator` 的规格一致（64×32，高度 32 是胶囊自身的定值，
  /// 属于本轮明确不迁移的 32 档，见计划 §1.2）。与 [navBarWithLabelHeight]
  /// **数值相同但语义无关**（一个是胶囊宽、一个是底栏高），故单列一档，
  /// 不允许后续以"统一"为名把两者并成一个常量。
  static const double navCapsuleWidth = 64.0;
}
