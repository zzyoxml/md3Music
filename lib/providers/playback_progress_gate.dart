/// 只把本次请求基线之后的平台位置增长认作真实播放进度。
///
/// 播放/恢复命令已发出只表示用户意图，不代表解码器已经推进位置。此闸门
/// 忽略恢复时重发的当前位置、旧请求的位置事件，以及同一请求的后续采样。
class PlaybackProgressGate {
  int? _request;
  Duration _baseline = Duration.zero;
  bool _reported = false;

  void begin(int request, {required Duration baseline}) {
    _request = request;
    _baseline = baseline;
    _reported = false;
  }

  /// 首次观察到当前请求的位置超过基线时返回 true。
  bool observe(int request, Duration platformPosition) {
    if (request != _request || _reported || platformPosition <= _baseline) {
      return false;
    }
    _reported = true;
    return true;
  }

  bool isPending(int request) => _request == request && !_reported;

  void reset() {
    _request = null;
    _baseline = Duration.zero;
    _reported = false;
  }
}
