/// 播放请求的 latest-wins 闸门。
///
/// 播放链接解析、setUrl 和等待 ready 都是异步操作。用户切歌或暂停后，
/// 旧请求即使稍后完成，也不能再把播放器重新拉起。
class PlaybackRequestGate {
  int _generation = 0;

  /// 开始一个新的播放请求，并使之前的请求失效。
  int issue() => ++_generation;

  /// 取消当前请求，但不开始新的播放请求。
  int invalidate() => ++_generation;

  /// 判断请求是否仍是最新请求。
  bool isCurrent(int generation) => generation == _generation;
}
