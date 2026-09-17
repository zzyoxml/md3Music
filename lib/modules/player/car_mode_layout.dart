// 车机模式下常驻播放器面板的纯逻辑（宽度换算与停靠位置），不依赖 Flutter。
//
// 「车机模式」开启后，任何界面的左侧（或右侧）常驻一块全屏播放器面板：
//   * 面板宽 = 屏幕宽 × 占比，占比可在设置里无级调节（20%~50%，默认 30%）
//   * 面板不可收起，同时全站不显示 MiniPlayer
//   * 设置页 / 登录页 / 引导页 / 用户协议页 不显示面板（见 car_mode_panel.dart）
//
// 本文件只放可单测的纯常量与纯函数；渲染与状态见 car_mode_panel.dart、
// providers/car_mode_provider.dart。

import 'dart:math' as math;

/// 面板宽度占比下限（20%）。
const double kCarModePanelMinRatio = 0.20;

/// 面板宽度占比上限（50%）。
const double kCarModePanelMaxRatio = 0.50;

/// 面板宽度占比默认值（30%）。
const double kCarModePanelDefaultRatio = 0.30;

/// 面板宽度的物理下限（dp）。
///
/// MD 风格播放器的传输控件是**固定宽度**的 `SizedBox`（`MD3ETransportRow`：
/// 紧凑档 44 + 8 + 60 + 8 + 44 = 164dp），加控件左右各 16dp 内边距 = 196dp；
/// 面板再窄必然 `RenderFlex overflow`。因此在很窄的屏幕上「20%」会被这个
/// 物理下限托底（屏宽 < 980dp 时生效），这是有意设计而非 bug。
const double kCarModePanelMinWidth = 196.0;

/// 面板停靠位置。
enum CarModePanelSide {
  /// 左侧常驻（默认）。
  left,

  /// 右侧常驻。
  right;

  /// 从持久化的 int 还原；越界 / 缺失一律回到 [CarModePanelSide.left]。
  static CarModePanelSide fromIndex(int? index) =>
      index != null && index >= 0 && index < CarModePanelSide.values.length
      ? CarModePanelSide.values[index]
      : CarModePanelSide.left;
}

/// 由屏幕宽度与占比推导面板实际宽度（dp）。
///
/// 规则（顺序不可调换）：
/// 1. 占比先夹进 `[kCarModePanelMinRatio, kCarModePanelMaxRatio]`；
/// 2. 乘屏幕宽得到理想宽度；
/// 3. 上限恒为 `屏宽 × kCarModePanelMaxRatio`（屏幕再窄也绝不超过一半）；
/// 4. 下限为 [kCarModePanelMinWidth]，但不得突破第 3 步的上限。
double resolveCarModePanelWidth({
  required double screenWidth,
  required double ratio,
}) {
  final safeWidth = screenWidth.isFinite && screenWidth > 0 ? screenWidth : 0.0;
  final clampedRatio = ratio.isFinite
      ? ratio.clamp(kCarModePanelMinRatio, kCarModePanelMaxRatio)
      : kCarModePanelDefaultRatio;
  final maxWidth = safeWidth * kCarModePanelMaxRatio;
  final minWidth = math.min(kCarModePanelMinWidth, maxWidth);
  return (safeWidth * clampedRatio).clamp(minWidth, maxWidth);
}

/// 由拖动**位移增量**换算面板占比增量（供面板宽度的拖动把手使用）。
///
/// [deltaX]：本次拖动事件相对上一次的指针位移（逻辑像素，向右为正）。
/// [screenWidth]：屏幕逻辑宽。
/// [side]：面板停靠侧 —— 面板在右侧时，指针向右移动会让面板**变窄**，故取反。
///
/// 为什么用「位移增量」而不是「指针绝对位置」：把手的 20dp 热区里，手指按下
/// 位置与面板分界线通常不重合（最多差 20dp）；若按绝对位置换算，第一次拖动
/// 事件会让面板**瞬间平移**那段差值（实测现象：每次起拖都向右跳一下）。
/// 用增量则天然没有这个问题，也顺带绕过了手势识别的 touch slop 位移。
///
/// 只做换算与有限性防御，**不夹取** [kCarModePanelMinRatio]/[kCarModePanelMaxRatio]：
/// 夹取由调用方与 [resolveCarModePanelWidth] 统一负责，避免同一规则散落多处。
double resolveCarModeRatioDelta({
  required double deltaX,
  required double screenWidth,
  required CarModePanelSide side,
}) {
  if (!screenWidth.isFinite || screenWidth <= 0) return 0.0;
  if (!deltaX.isFinite) return 0.0;
  final signed = side == CarModePanelSide.left ? deltaX : -deltaX;
  return signed / screenWidth;
}
