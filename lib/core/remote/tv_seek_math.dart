import 'dart:math' as math;

/// tv: 遥控方向键调进度的目标位置（夹取到 `[0, duration]`）。
///
/// 原先驻留在 `mv_player_page.dart`（为可单测而抽成顶层纯函数）；MV 与刷刷
/// 竖屏流两条视频链路都要同一套钳制，故收在此处。MV 侧保留同名转发壳，
/// 使既有 `test/modules/player/mv_player_page_tv_test.dart` 继续生效。
Duration tvSeekTarget(
  Duration current,
  Duration duration,
  int deltaSeconds,
) {
  final target = current + Duration(seconds: deltaSeconds);
  if (target < Duration.zero) return Duration.zero;
  if (duration > Duration.zero && target > duration) return duration;
  return target;
}

/// tv: 上下键在分页流里换页的目标下标（夹取到 `[0, count - 1]`）。
int tvPageTarget(int current, int count, int delta) {
  if (count <= 0) return 0;
  return math.min(math.max(current + delta, 0), count - 1);
}
