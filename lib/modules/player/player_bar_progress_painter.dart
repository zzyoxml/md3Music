import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';

import '../../core/theme/motion_constants.dart';

/// 播放栏进度指示「同一 painter 变形」的两端取值（见
/// `docs/plans/2026-10-11-player-bar-morph-plan.md` §4.3）。
///
/// 常驻条是**贴顶的 2dp 直线**（`formT == 0`），悬浮胶囊是**沿内缘描一圈的
/// 3dp 包边**（`formT == 1`），中间由同一条 painter 连续变形，不再两套画法
/// 交叉淡化。三个常量与既有两处实现逐字节对齐：
/// - 直线端 = `M3ELinearProgressIndicator(minHeight: 2)`（描边 2、`yOffset =
///   size.height / 2`，即贴顶 2px）。
/// - 包边端 = `secondary_mini_player.dart` 的 `_kProgressStroke`（3）与
///   `_kProgressInset`（= 3 / 2 = 1.5）。
const double kPlayerBarProgressLineStroke = 2.0;
const double kPlayerBarProgressRimStroke = 3.0;
const double kPlayerBarProgressRimInset = 1.5;

/// 直线端另有两个 M3E 默认参数**不体现在几何盒子上**，必须由调用方显式传，否则
/// 常驻条观感与旧的 `M3ELinearProgressIndicator` 不一致（取值同
/// `M3EProgressIndicatorDefaults`）：
/// - `linearIndicatorTrackGapSize` = 4：active 末端与 track 起端之间留 4dp；
/// - `linearTrackStopIndicatorSize` = 4：轨道末端 stop 点的直径（描边宽 2 时被钳到
///   2，恰好与轨道自己的圆端帽同心同径 → 只把轨道最右 2dp 重绘成进度色）。
const double kPlayerBarProgressLineGap = 4.0;
const double kPlayerBarProgressLineStopSize = 4.0;

/// 形变窗口内 stop 点随**直线态权重**淡入淡出的 formT 宽度。
///
/// 直线端（常驻条）轨道最右端有一个 2dp 的 stop 点（描边 ≤ stop 直径时被钳到
/// 描边宽，与轨道圆端帽同心同径，效果 = 轨道最右 2dp 画成进度色）。旧实现在
/// 形变态（`!isFlatLine`）直接跳过它 —— 于是**飞行全程没有 stop 点**，交棒到
/// 常驻条的末帧突然多出这 2dp（「切回常驻栏最后一刻进度闪一下」的机制），
/// 反向起飞瞬间又突然消失。改为按 formT 线性淡入淡出：常驻条端点（formT=0，
/// 走 `isFlatLine` 原路径）逐像素不变，浮层在 p→0 的最后一段把 stop 点补回
/// 满不透明（与真身端点等价），中段照旧不画。
const double kPlayerBarProgressStopMorphFade = 0.12;

/// stop 点在形变中的不透明度（纯函数，端点可直接断言）。
///
/// `formT == 0`（直线端 / 常驻条真身）恒为 1；`formT >= kPlayerBarProgressStopMorphFade`
/// 恒为 0（包边端/中段没有 stop 点）；中间线性淡出。`p→0` 的最后一帧
/// （formT ~ 0.002）因此 ≈ 1，与常驻条端点逐帧等价。
@visibleForTesting
double resolveStopIndicatorMorphOpacity(double formT) {
  if (formT <= 0.0) return 1.0;
  return (1.0 - formT / kPlayerBarProgressStopMorphFade).clamp(0.0, 1.0);
}

/// 「进度分母」在两形态间的插值权重（`formT` → `[0, 1]`，纯函数、端点可断言）。
///
/// **为什么需要它**：两端的进度分母口径**不同**，必须按 formT 过渡
/// （见 [resolveBarProgressGeometry] 的 `progressSpan`）：
/// - 直线态（`formT == 0`，常驻条 `mini_player.dart:908-924`）= M3E determinate 的
///   `currentProgress * width` —— 分母是**盒宽** W；
/// - 胶囊态（`formT == 1`，`secondary_mini_player.dart` 的 `_SecondaryProgressPainter`
///   `:1666-1669`）= `metric.length * p` —— 分母是**闭合中心线周长** L ≈ 2W。
/// 若两端共用「当前路径长度」，`formT` 刚离开 0 的第一帧分母就从 W 跳到 ≈2W
/// （开放线段 → 闭合环），同样的 progress 算出的已播放段瞬时翻倍
/// （实测 W=400 / p=0.5：199px → 399px），即「交棒瞬间已播放条硬切」。
///
/// **为什么不是线性权重**：已播放长度 ≈ progress × 分母，端点残差 ≈
/// `(1 − s(t)) × (L − W) × progress`。交棒前一帧（16ms / 约 400ms 行程）若仍是
/// 线性权重，实测残差 2.6~3.7px（t=0.99 / 0.02）—— 把 200px 的硬切缩成 3px 但没消掉；
/// 权重**两端导数趋零**后同一帧降到亚像素，且已播放段的**速度**在交棒处连续
/// （线性权重下它在端点仍以 ~500px/s 生长后被真身瞬间刹停，会读成一次「急停」）。
///
/// `s(t) = C(t)`，`C` = [M3ExpressiveMotion.barFormMorphEasing]
/// （`Cubic(0.2, 0, 0, 1)`，K1）：`s(0) == 0`、`s(1) == 1` 精确、单调不减、
/// 两端导数同样趋零（`s'(0) = s'(1) = 0`，上面那条"端点速度连续"的前提不变），
/// 但中段远陡于 smoothstep（`s(0.25) ≈ 0.61` vs 0.16、`s(0.5) ≈ 0.88` vs 0.5）
/// —— 已播放段在形变**早期**就把分母朝胶囊口径推进到位。
///
/// **为什么要更陡（K1）**：形态交棒的可见形变已前置到窗口开头 260ms 内走完
/// （见 `bottom_bar_morph_overlay.dart` 的 `kBarFormVisibleMorphDuration`）。
/// 权重若仍是 smoothstep（半程才 0.5），已播放段会在形变最猛的一段里明显落后于
/// 条体形状 —— 用户读到的就是「进度条没跟上变形」。
double resolveProgressSpanWeight(double formT) {
  final double t = formT.clamp(0.0, 1.0);
  return M3ExpressiveMotion.barFormMorphEasing.transform(t);
}

/// [PlayerBarProgressPainter] 的几何解算结果（纯数据，便于单元测试直接断言
/// 端点，不依赖截图或 recording canvas）。
///
/// 中心线是一条 inset 后的 stadium：[centerTop] / [centerBottom] 是上下两条直
/// 边的 y，[centerLeft] / [centerRight] 是左右两端的 x，四角半径 [radius]。
/// `formT == 0` 时上下直边重合（[isFlatLine]），退化成一条水平直线。
@immutable
class BarProgressGeometry {
  const BarProgressGeometry({
    required this.size,
    required this.strokeWidth,
    required this.inset,
    required this.radius,
    required this.centerTop,
    required this.centerBottom,
    required this.strokeCap,
    required this.gapSize,
    required this.capOffset,
    required this.activeStart,
    required this.activeEnd,
    required this.trackStart,
    required this.trackEnd,
  });

  final Size size;

  /// 描边宽度（2 → 3）。
  final double strokeWidth;

  /// 中心线的水平内缩（0 → 1.5）。
  final double inset;

  /// 中心线四角半径（0 → `cornerRadius`，受垂直半径上限钳制）。
  final double radius;

  /// 中心线上直边 y（`formT == 0` 时 = 盒子中线）。
  final double centerTop;

  /// 中心线下直边 y（`formT == 0` 时 = 盒子中线）。
  final double centerBottom;

  /// 端帽形状（默认 `StrokeCap.round`，与 M3E 同）。
  final StrokeCap strokeCap;

  /// 生效间隙：入参 `gapSize` 按直线态权重（`1 - formT`）插值，`formT == 1` 时为 0
  /// （胶囊包边没有间隙）。
  final double gapSize;

  /// 端帽外扩量，同时是端帽夹取量：`round` 时 = `strokeWidth / 2`，其余为 0，并按
  /// 直线态权重插值（`formT == 1` → 0，胶囊侧因此与旧包边逐像素一致）。
  ///
  /// 直线态下即 M3E 的 `strokeCapOffset`（`m3e_linear_progress_indicator.dart:244`）：
  /// 端点被夹进 `[capOffset, 周长 - capOffset]`，圆端帽因此不外溢盒子，active 的
  /// 起点也从 x = 0 挪到 x = 1（描边正好从盒左缘起、到盒右缘止）。
  final double capOffset;

  /// active 描边沿中心线的**弧长**起 / 止（直线态下与 x 坐标同值：中心线起点在
  /// x = 0）。均已按 [capOffset] 夹取。
  final double activeStart;
  final double activeEnd;

  /// track 描边沿中心线的弧长起 / 止。[trackStart] >= [trackEnd] 表示抽不出长度
  /// （进度逼近满格时 M3E 直接跳过 track，见 `m3e_linear_progress_indicator.dart:282`）。
  final double trackStart;
  final double trackEnd;

  double get centerLeft => inset;
  double get centerRight => size.width - inset;
  double get centerY => (centerTop + centerBottom) / 2;

  /// active 描边的可视末端（含圆端帽外扩 [capOffset]）。
  double get activePaintedEnd => activeEnd + capOffset;

  /// track 描边的可视起端（含圆端帽外扩 [capOffset]）。
  double get trackPaintedStart => trackStart - capOffset;

  /// 是否该画 track（夹取后仍有非零长度）。
  bool get hasTrack => trackStart < trackEnd;

  /// 描边带的上边缘（= [centerTop] - [strokeWidth] / 2）。
  ///
  /// `formT == 0` 时恒为 0 —— 即「贴顶」的那条边。中心线取盒子中线
  /// （与 `M3ELinearProgressIndicator` 的 `yOffset = size.height / 2` 同源），
  /// 描边因此正好铺满盒子顶部 `strokeWidth` 高的一条带，与既有顶置线等价。
  double get bandTop => centerTop - strokeWidth / 2;

  /// 是否退化为一条水平直线（`formT == 0` 的端点形态）。
  bool get isFlatLine => centerBottom - centerTop <= precisionErrorTolerance;

  /// 中心线路径（实现见 [_buildCenterLine]）。
  Path toPath() => _buildCenterLine(
    centerLeft: centerLeft,
    centerRight: centerRight,
    centerTop: centerTop,
    centerBottom: centerBottom,
    radius: radius,
    isFlatLine: isFlatLine,
  );
}

/// 中心线路径。
///
/// 直线态是两点线段；其余按既有包边实现（`_SecondaryProgressPainter._buildRim`）
/// **从底边左切点出发、顺时针绕一圈**。自拼 line/arc 而不用 `Path.addRRect`，
/// 是为了确定起点与绕向 —— 包边的「起点在封面下方」是设计的一部分，而
/// addRRect 的起点/绕向属实现细节，跨引擎版本不保证。
///
/// 独立成函数是为了让 [resolveBarProgressGeometry] 能用**同一条路径**取弧长：胶囊
/// 态下解析周长与 Skia 的圆弧逼近有约 0.05% 偏差，直接拿它做分段会把包边端点挪出
/// 亚像素级误差。
Path _buildCenterLine({
  required double centerLeft,
  required double centerRight,
  required double centerTop,
  required double centerBottom,
  required double radius,
  required bool isFlatLine,
}) {
  final double cy = (centerTop + centerBottom) / 2;
  final path = Path();
  if (isFlatLine) {
    path.moveTo(centerLeft, cy);
    path.lineTo(centerRight, cy);
    return path;
  }
  final double r = radius;
  final double xLeft = centerLeft + r;
  final double xRight = centerRight - r;
  path.moveTo(xLeft, centerBottom);
  path.lineTo(xRight, centerBottom);
  // 右半圆：底(π/2) → 右(0) → 顶(-π/2)。画布 y 轴向下，负绕向即视觉顺时针。
  path.arcTo(
    Rect.fromCircle(center: Offset(xRight, cy), radius: r),
    math.pi / 2,
    -math.pi,
    false,
  );
  path.lineTo(xLeft, centerTop);
  // 左半圆：顶(-π/2) → 左(π) → 底(π/2)，回到起点
  path.arcTo(
    Rect.fromCircle(center: Offset(xLeft, cy), radius: r),
    -math.pi / 2,
    -math.pi,
    false,
  );
  path.close();
  return path;
}

/// 解算进度条几何（纯函数、无副作用）：供 painter 绘制，也供单元测试直接断言
/// 「端点几何」。
///
/// 中心线**形状**：
/// - `formT == 0`：贴顶、满宽、描边 [kPlayerBarProgressLineStroke] 的水平直线
///   （中心线 = 盒子中线，故描边带上边缘恰好落在 y = 0）；
/// - `formT == 1`：按 [cornerRadius] 内缩 [kPlayerBarProgressRimInset]、描边
///   [kPlayerBarProgressRimStroke] 的 stadium（上/下直边分别在 `inset` 与
///   `height - inset`，左右端在 `inset` 与 `width - inset`）；
/// - 中间线性插值：描边 2→3、内缩 0→1.5，中心线由盒子中线向上下张开成两条直边。
///
/// 中心线**描边分段**（弧长）逐项复刻 M3E `_LinearProgressPainter` 的 determinate
/// 分支（`m3e_linear_progress_indicator.dart:221-294`）：active 是中心线前缀、track
/// 是其后（直线态还要让出 [gapSize] 与两侧端帽），两端按 [capOffset] 夹取。直线态
/// 专属量（间隙、端帽夹取）都按**直线态权重** `1 - formT` 插值，`formT == 1` 时
/// 双双归零 → 胶囊侧与旧的「整圈 + active 前缀」逐像素一致。
///
/// **进度分母**另有插值：直线态是盒宽（M3E 的 `progress * width`）、胶囊态是中心线
/// 周长（`metric.length * p`），按 [resolveProgressSpanWeight] 过渡 —— 否则
/// `formT` 离开 0 的第一帧路径长度就从 W 跳到 ≈2W，已播放段瞬时翻倍（硬切）。
///
/// [progress] 默认 0：不传时解得的就是「零进度」的分段（active 只剩起点端帽）。
///
/// [cornerRadius] 由调用方传入（`lerp(0, BottomChromeDimens.discDiameter / 2)`），
/// 解算时被**垂直半径上限**（`(centerBottom - centerTop) / 2`）钳制以保证 stadium
/// 成立：标准胶囊（高 = 2 × cornerRadius）下该钳制恰好等于 `cornerRadius - inset`，
/// 与既有包边的中心线半径一致。
///
/// [barHeight] 是**条盒**高度（非进度盒）：中心线的垂直基准由进度盒中线
/// （`size.height / 2`）连续移到条盒中心（`barHeight / 2`）。交叉过渡浮层里进度盒
/// 高会由 2 长到整条高，若中心线恒取进度盒中线，中段包边会随进度盒下移、贴在条体
/// 偏上处被封面盖住（2026-10-12 会诊 W2）。传 0（常驻条真身的 formT=0 调用点）时
/// 退化为进度盒中线，与原行为逐像素一致。
@visibleForTesting
BarProgressGeometry resolveBarProgressGeometry({
  required Size size,
  required double formT,
  required double cornerRadius,
  double progress = 0.0,
  double barHeight = 0.0,
  double gapSize = 0.0,
  StrokeCap strokeCap = StrokeCap.round,
  // tv: 直线态描边宽可调（默认 2 与既有端点逐像素一致；TV 顶栏 MiniPlayer
  // 传 4 加粗）。胶囊端 kPlayerBarProgressRimStroke 不随它变。
  double lineStroke = kPlayerBarProgressLineStroke,
}) {
  final double t = formT.clamp(0.0, 1.0);
  final double flatWeight = 1.0 - t;
  final double strokeWidth = lerpDouble(
    lineStroke,
    kPlayerBarProgressRimStroke,
    t,
  )!;
  final double inset = lerpDouble(0.0, kPlayerBarProgressRimInset, t)!;
  // 中心线 y 基准：从**进度盒中线**（`size.height / 2`，常驻条贴顶直线所在）
  // 连续移到**条盒中心**（`barHeight / 2`，胶囊整圈的内缘）。若恒取进度盒中线，
  // 进度盒高由 2 长到整条高时会带着整条中心线一起下移，中段包边贴在条体偏上处、
  // 被后画的封面盖住（2026-10-12 会诊 W2：t=0.5 时 y≈21.8）。`barHeight <= 0`
  // （常驻条真身的 formT=0 调用点）时退化为进度盒中线，与原行为逐像素一致。
  final double boxMidY = size.height / 2;
  final double midY = (t <= 0.0 || barHeight <= 0.0)
      ? boxMidY
      : lerpDouble(boxMidY, barHeight / 2, t)!;
  final double centerTop = lerpDouble(midY, inset, t)!;
  final double centerBottom = lerpDouble(midY, size.height - inset, t)!;
  final double maxRadius = (centerBottom - centerTop) / 2;
  final double radius = math.min(math.max(cornerRadius, 0.0), maxRadius);
  final bool isFlatLine = centerBottom - centerTop <= precisionErrorTolerance;

  // 弧长一律取自**真实路径**（见 [_buildCenterLine] 的说明）。
  final double pathLength = _buildCenterLine(
    centerLeft: inset,
    centerRight: size.width - inset,
    centerTop: centerTop,
    centerBottom: centerBottom,
    radius: radius,
    isFlatLine: isFlatLine,
  ).computeMetrics().first.length;

  // 端帽夹取量。它只在「端点落在盒子边缘」时才有意义 —— M3E 对 `strokeCap == butt`
  // 或描边宽超过盒宽的情形同样不夹取（`m3e_linear_progress_indicator.dart:237`）。
  // 胶囊态的中心线是闭合环、起点在形状内部（底边左切点），夹取只会把包边的闭合口
  // 挪开 1dp，故与间隙一样按直线态权重插值：`formT == 1` 归零，胶囊侧逐像素不变。
  final double capOffset =
      strokeCap != StrokeCap.butt && strokeWidth <= size.width
      ? strokeWidth / 2 * flatWeight
      : 0.0;
  final double lo = capOffset;
  final double hi = math.max(pathLength - capOffset, lo);
  final double gap = gapSize * flatWeight;

  final double p = progress.clamp(0.0, 1.0);
  // **进度分母**（「一整格」有多长）：两端口径不同，按 formT 过渡（权重见
  // [resolveProgressSpanWeight]）。
  //
  // - 直线态分母 = **盒宽** `size.width`：即 M3E 的 `currentProgress * width`，
  //   也正是 `formT == 0` 的路径长度（inset 归零 ⇒ 中心线横跨 [0, size.width]，
  //   两点线段长 == 盒宽，与常驻条真身逐值同源）；
  // - 胶囊态分母 = **中心线周长** `pathLength`：即胶囊真身
  //   `_SecondaryProgressPainter` 的 `metric.length * p`。
  //
  // 中间**不能**直接用当前路径长度：路径在 formT 刚离开 0 时由开放线段变闭合
  // stadium（长度 W → ≈2W），同一 progress 的已播放段会在交棒帧翻倍。
  final double progressSpan = lerpDouble(
    size.width,
    pathLength,
    resolveProgressSpanWeight(t),
  )!;
  // 未经夹取的 active 末端（直线态 = M3E 的 `currentProgress * width`；胶囊态 =
  // `metric.length * p`）。
  final double activeHead = p * progressSpan;
  // M3E `:270-281`：`trackStart = progress + min(progress, adjustedGap / width)`，
  // 其中 `adjustedGap = gapSize + strokeHeight`（圆端帽）—— 端帽每侧吃掉
  // `strokeWidth / 2`，位置等价即 `activeHead + min(activeHead, gap + 2 * capOffset)`。
  // `min()` 取的是**未夹取**的 activeHead：进度很小时间隙也同比缩短。
  final double trackHead =
      activeHead + math.min(activeHead, gap + 2 * capOffset);

  return BarProgressGeometry(
    size: size,
    strokeWidth: strokeWidth,
    inset: inset,
    radius: radius,
    centerTop: centerTop,
    centerBottom: centerBottom,
    strokeCap: strokeCap,
    gapSize: gap,
    capOffset: capOffset,
    activeStart: lo,
    activeEnd: math.min(math.max(activeHead, lo), hi),
    trackStart: math.min(math.max(trackHead, lo), hi),
    trackEnd: hi,
  );
}

/// M3E 轨道末端 stop 点的解算（`m3e_progress_indicator_utils.dart:30-91` 的移植，
/// 纯函数、便于断言）：返回圆点直径（0 = 不画）与圆心 x。
///
/// 只在直线态使用 —— M3E 的位置按**盒宽**定（右端取 `size.width`），对闭合的胶囊
/// 包边无意义。直径先被 [strokeWidth] 钳制（:43），[progress] 逼近末端时再收缩并入
/// active（:55-58）；描边宽不大于 stop 直径时（常驻条 2 < 4 → 钳到 2）它与轨道自己
/// 的圆端帽同心同径，效果就是「轨道最右端画成进度色」。
@visibleForTesting
({double dotSize, double centerX}) resolveStopIndicator({
  required Size size,
  required double progress,
  required double strokeWidth,
  required double stopSize,
}) {
  if (stopSize <= 0) return (dotSize: 0.0, centerX: 0.0);
  // 注意 M3E 这里恒取 `strokeWidth / 2`（`:42`），与端帽形状无关。
  final double capOffset = strokeWidth / 2;
  double dotSize = math.min(stopSize, strokeWidth);
  final double dotOffset = math.min((strokeWidth - dotSize) / 2, 6.0);
  double x = size.width - dotSize - dotOffset;
  final double progressX = size.width * progress.clamp(0.0, 1.0) + capOffset;
  if (x <= progressX) {
    dotSize = math.max(0.0, dotSize - (progressX - x));
    x = progressX;
  }
  return (dotSize: dotSize, centerX: x + dotSize / 2);
}

/// 播放栏进度指示的「同一 painter 形态变形」。
///
/// 常驻条（[formT] == 0）与悬浮胶囊（[formT] == 1）共用它，交叉过渡期间只改
/// [formT]（与 [cornerRadius]）即连续变形。颜色一律由调用方传 token，且**两端
/// 本就不同**（见 plan §2 的修正段，不要顺手统一）：
/// - 常驻条 track = `surfaceContainerHighest`、active = `primary`（= 旧调用点显式覆盖的
///   值，**不是** M3E 默认的 `secondaryContainer`）；
/// - 胶囊 track = `onSurfaceVariant @ 0.16`、active = `primary`。
/// 端帽 / 间隙 / 轨道末端 stop 点三个 M3E 直线态参数同理由调用方传：间隙与端帽
/// 夹取会被几何按 (1 - formT) 插值归零、stop 点只在直线态生效，所以胶囊侧只传前
/// 五个参数即可（保持原样不动）。
class PlayerBarProgressPainter extends CustomPainter {
  PlayerBarProgressPainter({
    required this.progress,
    required this.formT,
    required this.trackColor,
    required this.activeColor,
    required this.cornerRadius,
    this.barHeight = 0.0,
    this.gapSize = 0.0,
    this.strokeCap = StrokeCap.round,
    this.stopIndicatorSize = 0.0,
    this.lineStroke = kPlayerBarProgressLineStroke,
  });

  /// 播放进度 0..1。
  final double progress;

  /// 形态进度：0 = 顶置直线（常驻条），1 = 内缘包边（胶囊），中间连续变形。
  final double formT;

  /// 轨道色。**两形态不同值、由调用方给**：常驻条传 `surfaceContainerHighest`
  /// （旧调用点显式覆盖的值），胶囊传 `onSurfaceVariant @ 0.16`。
  final Color trackColor;

  /// 进度色（`primary`）。
  final Color activeColor;

  /// 中心线四角半径（调用方传 `lerp(0, discDiameter / 2)`）。
  final double cornerRadius;

  /// 条盒高度（交叉过渡浮层传 `layout.barHeight`）：中心线的垂直基准由
  /// **进度盒中线**连续移到**条盒中心**（见 [resolveBarProgressGeometry] 的
  /// `midY`）。`<= 0`（常驻条真身的 formT=0 调用点）时退化为进度盒中线，与
  /// 改动前逐像素一致。
  final double barHeight;

  /// active 描边末端与 track 描边起端之间的间隙（直线态 = M3E 的 4dp
  /// [kPlayerBarProgressLineGap]；胶囊态传不传都无所谓，几何会按 formT 归零）。
  final double gapSize;

  /// 端帽形状（M3E 默认 `StrokeCap.round`）。
  final StrokeCap strokeCap;

  /// 轨道末端 stop 点的直径（直线态 = M3E 的 4dp
  /// [kPlayerBarProgressLineStopSize]；0 = 不画）。只在直线态生效。
  final double stopIndicatorSize;

  /// 直线态描边宽（默认 [kPlayerBarProgressLineStroke]；tv: 顶栏 MiniPlayer
  /// 传 4 加粗，见 mini_player.dart 的 TV 分支）。
  final double lineStroke;

  @override
  void paint(Canvas canvas, Size size) {
    // 退化约束（形变极短帧 / 异常约束）下没有可画的环或线。
    if (size.width <= 0 || size.height <= 0) return;
    final geo = resolveBarProgressGeometry(
      size: size,
      formT: formT,
      cornerRadius: cornerRadius,
      progress: progress,
      barHeight: barHeight,
      gapSize: gapSize,
      strokeCap: strokeCap,
      lineStroke: lineStroke,
    );
    final path = geo.toPath();
    final metric = path.computeMetrics().first;

    // track：直线态是「让开 gapSize + 两侧端帽」之后的后半段 —— 不能整条画满，
    // 否则间隙会被轨道色填掉（M3E `:280-291`）；胶囊态退化为整圈，与
    // `_SecondaryProgressPainter` 的「整圈 + active 前缀」逐像素一致。
    if (geo.hasTrack) {
      canvas.drawPath(
        metric.extractPath(geo.trackStart, geo.trackEnd),
        _stroke(geo.strokeWidth, trackColor),
      );
    }

    final double p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      // active 是中心线前缀。起点同样按 capOffset 夹取：圆端帽因此不外溢盒子
      // （M3E `:245-252`），直线态下描边左端正好落在 x = 0。
      canvas.drawPath(
        metric.extractPath(geo.activeStart, geo.activeEnd),
        _stroke(geo.strokeWidth, activeColor),
      );
    }
    // 顺序与 M3E 一致（track → active → stop）。零进度下 M3E 仍走 determinate
    // 分支、照样画 stop 点，故这里不在 p == 0 时提前返回。
    _paintStopIndicator(canvas, geo, size);
  }

  /// 轨道末端 stop 点（M3E determinate 分支的最后一步，`m3e_linear_progress_indicator.dart:297-306`）。
  ///
  /// 形变态（`!isFlatLine`）不再直接跳过：按 [resolveStopIndicatorMorphOpacity]
  /// 在 p→0 的最后一段淡入（见 [kPlayerBarProgressStopMorphFade] 的说明），
  /// 否则交棒帧会"凭空"多出/消失这 2dp。`formT == 0` 的直线端照旧走
  /// `isFlatLine` 路径、逐像素与 M3E 现状一致。
  void _paintStopIndicator(Canvas canvas, BarProgressGeometry geo, Size size) {
    if (geo.strokeCap != StrokeCap.round) return;
    if (stopIndicatorSize <= 0) return;
    double opacity = 1.0;
    if (!geo.isFlatLine) {
      opacity = resolveStopIndicatorMorphOpacity(formT);
      if (opacity <= 0.0) return;
    }
    final stop = resolveStopIndicator(
      size: size,
      progress: progress,
      strokeWidth: geo.strokeWidth,
      stopSize: stopIndicatorSize,
    );
    if (stop.dotSize <= 0) return;
    canvas.drawCircle(
      Offset(stop.centerX, geo.centerY),
      stop.dotSize / 2,
      Paint()
        ..color = opacity >= 1.0
            ? activeColor
            : activeColor.withValues(alpha: activeColor.a * opacity),
    );
  }

  Paint _stroke(double width, Color color) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = strokeCap;

  @override
  bool shouldRepaint(PlayerBarProgressPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.formT != formT ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.cornerRadius != cornerRadius ||
      oldDelegate.barHeight != barHeight ||
      oldDelegate.gapSize != gapSize ||
      oldDelegate.strokeCap != strokeCap ||
      oldDelegate.stopIndicatorSize != stopIndicatorSize;
}
