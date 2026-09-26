// 车机模式下常驻播放器面板的纯逻辑（宽度换算与停靠位置），不依赖 Flutter。
//
// 「车机模式」开启后，任何界面的左侧（或右侧）常驻一块全屏播放器面板：
//   * 面板宽 = 屏幕宽 × 占比，占比可在设置里无级调节（20%~50%，默认 30%）
//   * 底部布局（竖屏 / 近方屏车机）下限放宽至 10%（见 kCarModePanelMinRatioBottom）
//   * 面板不可收起，同时全站不显示 MiniPlayer
//   * 设置页 / 登录页 / 引导页 / 用户协议页 不显示面板（见 car_mode_panel.dart）
//
// 本文件只放可单测的纯常量与纯函数；渲染与状态见 car_mode_panel.dart、
// providers/car_mode_provider.dart。

import 'dart:math' as math;

/// 面板宽度占比下限（20%）。
const double kCarModePanelMinRatio = 0.20;

/// 底部布局（竖屏 / 近方屏车机）下的面板高度占比下限（10%）。
///
/// 底部面板横贯全宽，宽度不是瓶颈；竖屏/方屏车机屏高紧凑，20% 的下限会把
/// 面板撑得过高、挤压主界面，因此放宽到 10%。物理下限
/// [kCarModePanelMinHeight] 仍会托底，传输控件不会溢出。
const double kCarModePanelMinRatioBottom = 0.10;

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

/// 自动启用车机模式的屏幕长比阈值（短边 / 长边）。
///
/// 「检测到车机屏幕时自动开启」的命中条件：屏幕短边/长边 **大于等于** 该值
/// 就视为车机屏并自动开启车机模式。
///   * 常见 16:9 横屏车机 = 短/长 ≈ 0.5625，≥ 0.55，命中；
///   * 方屏（如 880×860）≈ 0.98，命中；
///   * 竖屏手机 ≈ 0.45~0.5，不命中（避免普通手机误触发）。
/// 纯长比判断，与物理像素 / 逻辑像素无关（比值无量纲），可单测。
const double kCarModeAutoEnableMinAspect = 0.55;

/// 「竖屏或接近方屏」的屏幕长比阈值（短边 / 长边）。
///
/// 命中该判定的屏幕其常驻面板置于**底部**（横贯全宽、高度占比可调），
/// 而不是左/右两侧。竖屏（高 > 宽）恒归入此类，与长比数值无关；
/// 接近方屏（长比 ≥ 该值）同样归入，如 880×860（≈0.98）。
const double kCarModePortraitOrSquareMinAspect = 0.8;

/// 屏幕短边 / 长边（无量纲，介于 (0, 1]）。非法输入返回 0。
double screenAspect(double width, double height) {
  if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
    return 0;
  }
  final w = width, h = height;
  return w < h ? w / h : h / w;
}

/// 是否判定为「车机屏」：短边/长边 ≥ [kCarModeAutoEnableMinAspect]。
bool isCarLikeScreen(double width, double height) =>
    screenAspect(width, height) >= kCarModeAutoEnableMinAspect;

/// 是否「竖屏或接近方屏」：竖屏（高>宽）或短/长边长比 ≥
/// [kCarModePortraitOrSquareMinAspect]。此类屏幕面板置于底部。
bool isPortraitOrSquareScreen(double width, double height) {
  final aspect = screenAspect(width, height);
  final portrait = height > width;
  return portrait || aspect >= kCarModePortraitOrSquareMinAspect;
}

/// 底部面板下缘避让区的固定兜底高度（dp）。
///
/// 车机端的「车联 dock 栏」多为系统级悬浮窗，绘制在 App 之上且**不产生
/// WindowInsets**，MediaQuery.padding.bottom 为 0，SafeArea 挡不住它。
/// 因此底部布局下面板与屏幕下缘之间恒定留出一块避让区：
/// 取 max(系统安全区, 本兜底值)，两种 dock 形态都盖得住。
const double kCarModeBottomDockClearance = 48.0;

/// dock 避让高度的可设置上限（dp）：覆盖常见车机 dock 高度，防止误设
/// 把面板挤到不可用。
const double kCarModeDockClearanceMax = 160.0;

/// 底部面板高度的物理下限（dp）。
///
/// 侧边面板靠 [kCarModePanelMinWidth] 托底保证传输控件不溢出；底部面板
/// 横贯全宽、限制的是高度，同样需要物理下限避免 `RenderFlex overflow`。
/// 高度低于该值时底部面板切换为细条（dock bar）模式渲染（见
/// car_mode_panel.dart 的 `_CarModeDockBar`），FullPlayer 紧凑布局只在
/// 高度 ≥ 本值时使用。
const double kCarModePanelMinHeight = 140.0;

/// 底部面板「细条模式」的物理下限（dp）。
///
/// 底部布局占比下限为 10%，但 [kCarModePanelMinHeight]（140dp，FullPlayer
/// 紧凑布局的下限）会把小屏上的 10% 托底回 ~20%，等于 10% 形同虚设。
/// 因此底部布局把物理下限放宽到本值，低于 [kCarModePanelMinHeight] 的
/// 高度由细条模式（封面缩略图 + 曲名/歌手 + 上一首/播放/下一首）兜底渲染，
/// 不再溢出。44dp 传输侧键 + 上下各 6dp 边距 ≈ 56dp。
const double kCarModeDockBarMinHeight = 56.0;

/// 紧凑歌词条（[CarModeLyricBar]）的物理下限（dp）。
///
/// 歌词条布局 = 歌名/歌手两行 + 传输键行（34dp 触控高），低于本值放不下，
/// 由 car_mode_panel.dart 回退旧细条 [_CarModeDockBar] 单行渲染。
/// 更矮的屏上 10% 被 [kCarModeDockBarMinHeight]（56dp）托底时走此回退。
/// 2026-09-23 起歌词条带按 1.1x 缩放核算最低到 85dp 也能放（歌手行隐藏），
/// 故下限从 80dp 放宽到 72dp：10%（86dp）始终走歌词条带。
const double kCarModeDockBarFallbackMin = 72.0;

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

/// 由屏幕高度与占比推导底部面板实际高度（dp）。
///
/// 规则与 [resolveCarModePanelWidth] 对称：占比夹进合法区间 → 乘屏高得到理想
/// 高度 → 上限恒为 `屏高 × kCarModePanelMaxRatio` → 下限为
/// [kCarModePanelMinHeight]（但不能突破上限）。
///
/// [minRatio]：高度占比下限。侧边/底部布局共用本函数时由调用方决定：
/// 底部布局传 [kCarModePanelMinRatioBottom]（10%），其余场景用默认值
/// [kCarModePanelMinRatio]（20%）。
///
/// [minPhysicalHeight]：物理下限。底部布局传 [kCarModeDockBarMinHeight]
/// （56dp，细条模式托底），侧边/其余场景用默认 [kCarModePanelMinHeight]
/// （140dp，FullPlayer 紧凑布局下限）。
double resolveCarModePanelHeight({
  required double screenHeight,
  required double ratio,
  double minRatio = kCarModePanelMinRatio,
  double minPhysicalHeight = kCarModePanelMinHeight,
}) {
  final safeHeight = screenHeight.isFinite && screenHeight > 0
      ? screenHeight
      : 0.0;
  final clampedRatio = ratio.isFinite
      ? ratio.clamp(minRatio, kCarModePanelMaxRatio)
      : kCarModePanelDefaultRatio;
  final maxHeight = safeHeight * kCarModePanelMaxRatio;
  final minHeight = math.min(minPhysicalHeight, maxHeight);
  return (safeHeight * clampedRatio).clamp(minHeight, maxHeight);
}

/// 由拖动**位移增量**换算底部面板的高度占比增量（底部面板的垂直把手）。
///
/// [deltaY]：本次拖动事件相对上一次的指针位移（逻辑像素，向下为正）。
/// [screenHeight]：屏幕逻辑高。
/// [atBottom]：面板是否贴底放置 —— 贴底面板的把手在**上缘**，指针**向上**
/// 移动（deltaY<0）= 上缘上移 = 面板**变高**（标准 bottom-sheet 手势：
/// 上滑展开、下滑收起）。贴顶时相反（本设计恒贴底；保留参数应对未来贴顶）。
///
/// 语义与 [resolveCarModeRatioDelta] 完全对齐：用增量而非绝对位置，避免
/// 每次起拖都瞬间平移「按下点与分界线的差值」。不夹取，夹取由调用方负责。
double resolveCarModeHeightDelta({
  required double deltaY,
  required double screenHeight,
  required bool atBottom,
}) {
  if (!screenHeight.isFinite || screenHeight <= 0) return 0.0;
  if (!deltaY.isFinite) return 0.0;
  final signed = atBottom ? -deltaY : deltaY;
  return signed / screenHeight;
}
