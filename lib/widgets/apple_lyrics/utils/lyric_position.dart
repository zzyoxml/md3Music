/// 将播放器权威位置映射为歌词位置。
///
/// 正偏移会让高亮延后（歌词位置减去偏移）；负偏移会让高亮提前。
/// 播放速度、暂停和 seek 已由播放器 position 流反映，这里不使用 wall clock。
Duration adjustLyricPosition(Duration playbackPosition, int offsetMs) {
  final adjustedMs = playbackPosition.inMilliseconds - offsetMs;
  return Duration(milliseconds: adjustedMs < 0 ? 0 : adjustedMs);
}
