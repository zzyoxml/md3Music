import 'dart:math' as math;

import '../../widgets/player_dock/player_control_dock.dart';

/// 宽屏（手机横屏 / Pad）左栏的**唯一**度量口径：一套按比例算出的左右内衬，
/// 加上由「栏高 − chrome 预留」诚实算出的封面边长。
///
/// 改造前左栏几件东西各吃各的横向留白：栏内衬写死 16、曲名按封面边长（`size`）、
/// 播放键按自身自然宽、进度尺还额外叠一层控制带的 16 —— 实测 800×360 是
/// 封面 147 / 曲名 120 / 播放键 164 三种宽度并存，左右边缘根本对不齐；
/// 1280×800 更夸张（480 / 380 / 164）。这里把内衬收敛成**按栏宽取比例**的一个值，
/// 左栏所有控件共用同一个内容盒。
///
/// MD3 与 AM 两版、`_buildLandscapeLayout` 与 `_buildExpandedLayout` 两种宽屏形态
/// 都读这里，避免四份各写一遍后失同步。
class PlayerWidePane {
  const PlayerWidePane._();

  /// 左栏内衬 = 栏宽 × 5%，夹在 [12, 24]。
  ///
  /// 取值让手机横屏（左栏 320dp）落在 16dp —— 与改造前逐像素一致，
  /// 大屏才抬到 24dp 封顶，不至于让控制贴边。
  static double gutter(double paneWidth) =>
      (paneWidth * 0.05).clamp(12.0, 24.0);

  /// 封面 → 曲名的行距。
  static const double titleGap = 16.0;

  /// 曲名 → 进度尺、进度尺 → 播放键的行距。
  static const double rowGap = 12.0;

  /// 曲名块本体预留：实测 1 倍字 MD3 37 / AM 46，取 50 兜住两版。
  ///
  /// 这个数**必须不小于实测值**：封面是 `SizedBox.square(dimension: size)` 套在
  /// `Flexible` 里的，预留小于实测 chrome 时 Flexible 会把封面再压一截，
  /// 封面边长就不再等于曲名盒的宽度，左右边缘又对不齐。多留几 dp 只是封面略小。
  static const double titleReserve = 50.0;

  /// 进度尺带本体预留 = 带的定高（与 [PlayerControlDock.seekBandHeight] 同一个数）。
  static const double seekReserve = PlayerControlDock.seekBandHeight;

  /// 传输簇本体预留：三按钮形变组（含两端侧键）的定高，实测 60。
  static const double transportReserve = 60.0;

  /// 封面边长下限：再小曲名/艺人的换行就没了立足之地，封面也会被压成扁方块。
  static const double minCover = 64.0;

  /// 左栏只有「封面 + 曲名」时的 chrome（独立控制页档，以及尺搬不进来时的兜底）。
  static double titleChrome() => titleGap + titleReserve;

  /// 常驻档：曲名下方再加**播放键**（尺仍在右栏底部）。
  static double clusterChrome() => titleChrome() + rowGap + transportReserve;

  /// 常驻档且尺也搬进左栏：曲名 → 尺 → 播放键。
  static double bandChrome() => clusterChrome() + rowGap + seekReserve;

  /// 尺与播放键**装得下**左栏吗？
  ///
  /// 装不下（640×300 这类小横屏，栏内高只有 218）还硬塞，封面会被 `Flexible`
  /// 压成 64×33 的扁方块（实测），比进度条留在右栏底部更难看 —— 那种形态下
  /// 尺回到右栏那条 chrome，左栏仍留播放键（改造前的分工）。
  static bool bandFits({required double innerHeight}) =>
      innerHeight - bandChrome() >= minCover;

  /// 封面正方形边长：宽、高两个方向取小的那个，再夹进 [minCover, maxCover]。
  ///
  /// 默认不封顶：封顶值一旦小于栏内宽，封面就会比横贯栏宽的进度尺窄一截，
  /// 左右边缘又对不齐（曾用 380 封顶，实测 1280×800 上封面 380 / 尺 464）。
  static double coverSize({
    required double innerWidth,
    required double innerHeight,
    required double chrome,
    double maxCover = double.infinity,
  }) {
    final byHeight = innerHeight - chrome;
    final side = math.min(innerWidth, byHeight);
    return side < minCover ? minCover : math.min(side, maxCover);
  }
}
