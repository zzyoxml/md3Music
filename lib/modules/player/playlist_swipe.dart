// 播放列表「从右往左滑 → 切到下一页」的手势判定（纯逻辑，不依赖 Flutter）。
//
// 为什么必须由面板自己判：队列每行都套在 m3e_core 的 M3EDismissibleCard 里，
// 它注册了水平拖拽（滑动删除），外层 TabBarView 的横向拖拽在竞技场里永远
// 抢不到事件。面板用不参与竞技场的 Listener 收原始指针事件，判定结果逐帧
// 喂给 PlaylistSwipeDriver，由后者写进 TabController 实现跟手。
//
// 本文件只放纯函数，供单测直接覆盖；面板状态在 PlayerPlaylistView，
// 换页写入在 PlaylistSwipeDriver。

/// 「从右往左滑切页」的判定阈值。
///
/// 数值沿用改造前 PlayerPlaylistView 里的同一组常量（阈值 / 轴向倍数 /
/// 纵向上限），抽到这里只是为了让判定可单测，手感不变。
class PlaylistSwipeThresholds {
  const PlaylistSwipeThresholds({
    this.maxCrossAxis = 48.0,
    this.axisRatio = 1.6,
  });

  /// 纵向位移上限（逻辑像素）：超过即放弃本次判定，把纵向手势让给列表。
  final double maxCrossAxis;

  /// 横向位移必须达到纵向位移的这个倍数，才算「横向滑动」。
  final double axisRatio;

  /// 默认阈值，面板直接用它。
  static const PlaylistSwipeThresholds defaults = PlaylistSwipeThresholds();
}

/// 纵向位移是否已超限（应放弃本次滑页判定）。
bool playlistSwipeCrossAxisExceeded(
  double dy, [
  PlaylistSwipeThresholds thresholds = PlaylistSwipeThresholds.defaults,
]) => dy.abs() > thresholds.maxCrossAxis;

/// 本次位移是否算「从右往左」的横向滑动（dx 为负）。
///
/// 右滑（dx > 0）一律 false：那段手势留给列表的滑动删除
/// （M3EDismissibleCardStyle.direction = startToEnd）。
bool playlistSwipeIsForwardHorizontal(
  double dx,
  double dy, [
  PlaylistSwipeThresholds thresholds = PlaylistSwipeThresholds.defaults,
]) => dx < 0 && dx.abs() >= dy.abs() * thresholds.axisRatio;

/// 左滑位移换算成页面进度（0~1）。
///
/// [panelWidth] 是播放列表面板的宽度（即一页宽度）；未测量（<= 0）时返回 0，
/// 避免除零把页面 offset 顶到无穷。
double playlistSwipeProgressFromDx(double dx, double panelWidth) {
  if (panelWidth <= 0) return 0;
  return (-dx / panelWidth).clamp(0.0, 1.0);
}

/// 松手速度折算成「额外滑过页数」的时间常数（秒）。
///
/// 与 PageScrollPhysics 同思路：快速轻扫即使位移不足半页也应当翻页。
const double kPlaylistSwipeFlingProjectionSeconds = 0.08;

/// 松手后吸附到哪一页：0 = 回播放列表，1 = 停在下一页。
///
/// [progress] 是松手时已滑过的比例（0~1），[velocityPxPerSec] 是水平速度
/// （逻辑像素/秒，向左为负），[panelWidth] 是一页宽度。
int playlistSwipeSettleTarget({
  required double progress,
  required double velocityPxPerSec,
  required double panelWidth,
}) {
  final pagesPerSecond = panelWidth <= 0 ? 0.0 : -velocityPxPerSec / panelWidth;
  final projected = (progress + pagesPerSecond * kPlaylistSwipeFlingProjectionSeconds)
      .clamp(0.0, 1.0);
  return projected.round().clamp(0, 1);
}