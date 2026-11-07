// 封面切换 pager 的纯逻辑：跟手拖动 / 松手吸附 / 越界回弹共用同一份算法。
//
// 刻意不依赖 Flutter widget：手感边界（橡皮筋上限、过半阈值、甩动阈值、时长夹取）
// 用普通单元测试钉住，比 widget 测试里近似像素可靠得多。
//
// 术语
//   progress p：以「当前曲目封面居中」为 0 的连续页位置。
//               p = +1 → 下一首封面居中；p = -1 → 上一首封面居中。
//   offset   o：相对页偏移（-1 上一首 / 0 当前 / +1 下一首）。
//
// 唯一真值式：x(o, p) = (o - p) * pitch，渲染层与物理层共用（见 [coverSlideOffset]）。
// 卡内图像在此基础上再叠一层视差（见 [coverParallaxOffset]）：图像比卡片慢，
// 读的是同一条 x(o, p)，不做第二套坐标。

import 'package:flutter/physics.dart';

/// 相对页 [offset] 的封面中心，相对视口中心的横向像素偏移。
double coverSlideOffset({
  required int offset,
  required double progress,
  required double pitch,
}) => (offset - progress) * pitch;

/// 卡内图像的视差滞后系数：卡片离开视口中央 1 页时，卡内图像只按 35% 滞后。
///
/// 方向取「朝向视口中央」—— 卡片离中央越远，卡内图像越往中央方向偏，于是图像
/// 在屏幕上只以 `1 - lag` 的速度跟着卡片走，形成「框在滑、画面滞后」的纵深。
const double kCoverParallaxLag = 0.35;

/// 卡内图像的视差位移（相对卡片自身中心，px）。
///
/// 取「朝向视口中央」这个方向顺带解决了「图像滑出卡外露底」：
/// p = 0（卡片贴齐视口）时位移为 0，图像与卡片完全重合；卡片离开中央后，图像被
/// 往**可见侧**（视口内的那一侧）多留 [lag] 比例，被让出来的空白永远落在卡片
/// **背对视口**的那半边 —— 而视口宽 = 卡片边长、卡片外缘与视口外缘同线，那半边
/// 整块都在视口外。因此**不需要额外放大封面**（直觉上以为要放大才够，是错的）。
double coverParallaxOffset({
  required int offset,
  required double progress,
  required double pitch,
  double lag = kCoverParallaxLag,
}) => -lag * coverSlideOffset(offset: offset, progress: progress, pitch: pitch);

/// 拖动越界时允许的最大额外位移（页）。0.35 页约为「一页宽的 1/3」，
/// 再多就会让相邻页被挤到视口外反而看不出「拖不动」的反馈。
const double kCoverOverscrollPages = 0.35;

/// 与 Flutter `ScrollPhysics` 同族的橡皮筋公式：越界越多、阻尼越强，
/// 且**永不越过 [kCoverOverscrollPages]**。
double _rubberBand(double overscroll) {
  const double coefficient = 0.55;
  return kCoverOverscrollPages *
      (1 - 1 / (overscroll * coefficient / kCoverOverscrollPages + 1));
}

/// 跟手拖动：把像素增量换算成页进度，越界部分用橡皮筋衰减。
///
/// [dx] 为 `DragUpdateDetails.delta.dx`（手指右移为正）。手指左移 → 推进入
/// 下一首 → progress 增大，所以取负号。
/// [minProgress]/[maxProgress] 是**可翻页的整页边界**（-1 / 0 / +1 之一），
/// 边界外仍可拖出一点位移（给「到头了」的手感反馈），松手后由
/// [coverSettleTarget] 夹回边界内 → 表现为回弹。
double coverDragProgress({
  required double progress,
  required double dx,
  required double pitch,
  required double minProgress,
  required double maxProgress,
}) {
  if (pitch <= 0) return progress;
  final double raw = progress - dx / pitch;
  if (raw > maxProgress) {
    return maxProgress + _rubberBand(raw - maxProgress);
  }
  if (raw < minProgress) {
    return minProgress - _rubberBand(minProgress - raw);
  }
  return raw;
}

/// 松手后要落到的整页位置：0 = 留在当前曲目（含回弹），±1 = 翻页。
///
/// 判据照抄 Flutter 分页自己的口径（`PageScrollPhysics._getTargetPixels`）：
/// **有速度就先把页位置推半页，再取整** ——
/// 于是「甩一下」无论拖了多远都会翻页（这就是惯性判定），
/// 而手指已经停住再松开（速度≈0）时退化成纯粹的「位移过半才翻页」。
///
/// [velocityPxPerSec] 是**沿进度方向**的释放速度（正 = 朝下一首），单位 px/s：
/// 拿 `DragEndDetails.primaryVelocity` 时记得取负（手指右移 = 回上一首）。
/// [minProgress]/[maxProgress] 仍是可翻页的整页边界，结果会被夹进去 ——
/// 夹回 0 就是「原地回弹」。
double coverSettleTarget({
  required double progress,
  required double velocityPxPerSec,
  required double minProgress,
  required double maxProgress,
}) {
  final double lower = minProgress.ceilToDouble();
  final double upper = maxProgress.floorToDouble();
  final double shifted = velocityPxPerSec.abs() >= kCoverFlingVelocityPxPerSec
      ? progress + (velocityPxPerSec > 0 ? 0.5 : -0.5)
      : progress;
  return shifted.roundToDouble().clamp(lower, upper).toDouble();
}

/// 判定为「甩动」的最小释放速度（px/s，沿进度方向）。
///
/// 取 Flutter 手势系的 `kMinFlingVelocity`：50 px/s。
/// **量纲必须与 `primaryVelocity` 一致**——上一版把阈值写成 480 却当成
/// 「页/秒」用（等于 18 万 px/s），现实中永远达不到，甩动分支形同虚设，
/// 所有快速小位移甩动都掉进「位移过半」规则被弹回，手感就是「没有惯性」。
const double kCoverFlingVelocityPxPerSec = 50.0;

/// 吸附/回弹用的弹簧：Flutter 滚动系自己的那根（`ScrollPhysics._kDefaultSpring`）。
///
/// `ratio = 1.1` 是**过阻尼**：带着释放速度也不会过冲。这一点对本组件是硬约束 ——
/// 页列表只有三张（上一首/当前/下一首），进度越过 ±1 会让视口边缘露出
/// 「没有第 4 张封面」的空白条。
final SpringDescription kCoverSettleSpring = SpringDescription.withDampingRatio(
  mass: 0.5,
  stiffness: 100.0,
  ratio: 1.1,
);

/// 吸附/回弹仿真：**把松手速度带进弹簧**。
///
/// 为什么不继续用 `AnimationController.animateTo` + 曲线：`animateTo` 的起始
/// 速度恒为 0 —— 手指以 2000px/s 带着封面走，松手瞬间速度被清零、再被缓动曲线
/// 重新加速，这个「速度断崖」就是手感生涩的直接来源。
/// `animateWith(simulation)` 则把 [velocity] 当初始速度代入，封面顺势滑过去。
///
/// [from]/[to]/[velocity] 都用**页**为单位（页/秒），与 `progress` 同一坐标系；
/// 容差也按页给（0.001 页 ≈ 0.4px），不依赖 SDK 默认容差的量纲。
Simulation coverSettleSimulation({
  required double from,
  required double to,
  required double velocity,
}) => ScrollSpringSimulation(
  kCoverSettleSpring,
  from,
  to,
  velocity,
  tolerance: const Tolerance(distance: 0.001, velocity: 0.001),
);

/// 松手落点对应的切歌意图；落点是 0 时返回 null（留在原曲 / 回弹）。
enum CoverSwitchIntent { previous, next }

CoverSwitchIntent? coverSwitchIntentForTarget(double target) {
  if (target >= 1) return CoverSwitchIntent.next;
  if (target <= -1) return CoverSwitchIntent.previous;
  return null;
}

/// 两次切歌之间的「方向」：`+1` 下一首、`-1` 上一首、`0` 方向未知。
///
/// 只有相邻下标（含列表循环的首尾绕回）才算方向明确；任意跳转、下标未变、
/// 单曲队列一律返回 0 —— 调用方据此走「不滑动 + 原封面淡入淡出」。
/// 口径与 `PlayerProvider.next()`（`(index + 1) % length`）/
/// `previous()`（`index - 1` 绕回）一致，故 `player.playlist` 里的邻居就是
/// 真正的下一首目标。
int coverSlideDirectionForIndexChange({
  required int fromIndex,
  required int toIndex,
  required int playlistLength,
}) {
  if (playlistLength <= 1) return 0;
  if (toIndex == fromIndex) return 0;
  if (toIndex == fromIndex + 1 ||
      (fromIndex == playlistLength - 1 && toIndex == 0)) {
    return 1;
  }
  if (toIndex == fromIndex - 1 ||
      (fromIndex == 0 && toIndex == playlistLength - 1)) {
    return -1;
  }
  return 0;
}
