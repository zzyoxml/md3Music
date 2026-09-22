/// 估算当前真实播放位置。
///
/// `video_player` 的 `value.position` 由 500ms 周期定时器刷新，直接用会在
/// 每 500ms 造成一批弹幕集中涌出；这里用单调时钟差在两次采样之间做线性外推。
/// 调用方必须用 `Stopwatch.elapsed`（单调）而不是 `DateTime.now()`：
/// 后者会被 NTP 同步/手动改时间打断，造成外推跳变并被误判为 seek。
Duration estimatePosition({
  required Duration base,
  required Duration wallClock,
  required Duration sampleClock,
  required bool isPlaying,
}) {
  if (!isPlaying) return base;
  final elapsed = wallClock - sampleClock;
  if (elapsed <= Duration.zero) return base;
  return base + elapsed;
}
