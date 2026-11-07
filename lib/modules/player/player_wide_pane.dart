import 'dart:math' as math;

import 'package:flutter/widgets.dart' show MediaQueryData;

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

  /// 宽屏左右分栏：左栏占比。对称 1:1，否则 4:6。
  ///
  /// 左右两个 `Expanded` 的 flex（5:5 或 4:6）、右栏分档宽度、左栏内衬与顶栏
  /// 尾部胶囊的右内衬都从这一个函数取占比，避免四份各写一遍后失同步。
  /// 「对称与否」由设置开关 `kSymmetricWidePaneEnabled` 决定。
  static double leftPaneFraction(bool symmetric) => symmetric ? 0.5 : 0.4;

  /// 左栏内衬 = 栏宽 × 5%，夹在 [12, 24]。
  ///
  /// 取值让手机横屏（左栏 320dp）落在 16dp —— 与改造前逐像素一致，
  /// 大屏才抬到 24dp 封顶，不至于让控制贴边。
  ///
  /// 下限 12 触发时整页同步收紧：左栏内衬、`bandFits` 的余量判断与顶栏尾部
  /// 胶囊的右内衬都从这一个函数取值，左右边缘不会失衡；不要让右栏另行独立取
  /// `gutter(0.6W)`——非对称分栏下右栏更宽，同一屏幕会算出比左栏更大的值
  /// （典型宽度上 16 vs 24），两边内衬立刻错位。
  /// 另注：右栏面板（播放列表 / 歌词 / 底部页签条与 dock）各自的横向内衬
  /// 不归此口径管，属既有独立节奏（固定 16 / 24），不必也没法同源对齐。
  ///
  /// [override] 非 null 时（用户开启「自定义宽屏边距」）**完全取代**比例算法：
  /// 直接返回该值，不再夹 [12, 24]——0 即无边距，48 即 48dp 固定内衬。
  /// null 时按上面的自动口径计算。
  static double gutter(double paneWidth, {double? override}) =>
      override ?? (paneWidth * 0.05).clamp(12.0, 24.0);

  /// 横屏挖孔/异形屏对称补偿：取左右安全区较大者统一补偿两侧。
  ///
  /// SafeArea 默认左吃左、右吃右，挖孔只在一侧时左右起点不齐（左栏封面
  /// 缩进挖孔宽，右栏内容却贴边）；这里改为取 `max(padding.left, padding.right)`
  /// 一个值对称加在两侧，左右内容起点相等。
  /// 异常值钳制：NaN、负数或 >128（挖孔补偿不可能这么宽，多为平台脏数据）
  /// 一律按 0 处理，避免个别机型把整页推开。Windows/桌面无挖孔时结果为 0，
  /// 行为与不加补偿一致。
  static double cutoutSymmetricInset(MediaQueryData mq) {
    double clampInset(double v) => (v.isNaN || v < 0 || v > 128) ? 0 : v;
    return math.max(clampInset(mq.padding.left), clampInset(mq.padding.right));
  }

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
