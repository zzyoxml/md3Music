/// 后台自动恢复任务的单飞与代次状态。
///
/// 单独建模 token 生命周期，避免旧任务的 finally 释放后来启动的新任务。
class PlaybackRecoveryFlight {
  int _sequence = 0;
  int? _inFlightToken;

  int get sequence => _sequence;
  int? get inFlightToken => _inFlightToken;

  /// 开始一个恢复任务；已有任务未释放时返回 null。
  int? tryStart() {
    if (_inFlightToken != null) return null;
    final token = ++_sequence;
    _inFlightToken = token;
    return token;
  }

  bool isCurrent(int token) => token == _sequence;

  /// 使当前恢复任务和已排期定时器失效；需要立即接管时同时释放占位。
  void invalidate({bool releaseInFlight = false}) {
    _sequence++;
    if (releaseInFlight) _inFlightToken = null;
  }

  /// 只有占有当前占位的任务才能释放它。
  void releaseIfOwned(int token) {
    if (_inFlightToken == token) _inFlightToken = null;
  }
}
