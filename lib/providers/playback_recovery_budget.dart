/// 当前恢复失败的决策类别。
enum PlaybackRecoveryFailureKind {
  noFailure,
  userCanceled,
  authenticationRequired,
  paidContent,
  networkUnavailable,
  transientResolution,
}

/// 播放媒体源返回HTTP状态后的恢复策略分类。
enum PlaybackSourceHttpFailureKind {
  noHttpStatus,
  signedUrlRejected,
  resourceMissing,
  transientHttpFailure,
  permanentHttpFailure,
}

PlaybackSourceHttpFailureKind classifyPlaybackSourceHttpFailure(
  int? statusCode,
) {
  if (statusCode == null) return PlaybackSourceHttpFailureKind.noHttpStatus;
  if (statusCode == 401 || statusCode == 403) {
    return PlaybackSourceHttpFailureKind.signedUrlRejected;
  }
  if (statusCode == 404 || statusCode == 410) {
    return PlaybackSourceHttpFailureKind.resourceMissing;
  }
  if (statusCode == 408 ||
      statusCode == 425 ||
      statusCode == 429 ||
      statusCode >= 500) {
    return PlaybackSourceHttpFailureKind.transientHttpFailure;
  }
  return PlaybackSourceHttpFailureKind.permanentHttpFailure;
}

/// Android Media3 的错误码可区分媒体格式错误与可通过重新解析恢复的失败。
/// 未知错误默认保留原有有限重试行为，避免错误码升级时误阻断恢复。
bool shouldAutomaticallyRetryPlatformPlaybackError({
  required bool isAndroid,
  required int? errorCode,
  int? httpStatusCode,
}) {
  final httpFailure = classifyPlaybackSourceHttpFailure(httpStatusCode);
  if (httpFailure == PlaybackSourceHttpFailureKind.resourceMissing ||
      httpFailure == PlaybackSourceHttpFailureKind.permanentHttpFailure) {
    return false;
  }
  if (!isAndroid || errorCode == null) return true;

  // Media3 3003：容器不受支持；4004/4005：解码器不支持格式或能力不足。
  // 重新请求同一媒体 URL 无法修复这些确定性兼容问题。
  return errorCode != 3003 && errorCode != 4004 && errorCode != 4005;
}

/// 把已知不可恢复状态与可重试解析失败分开，避免定时器盲目重试。
PlaybackRecoveryFailureKind classifyPlaybackRecoveryFailure({
  required bool hasFailure,
  required bool userCanceled,
  required bool authenticationRequired,
  required bool paidContent,
  required bool networkAvailable,
}) {
  if (!hasFailure) return PlaybackRecoveryFailureKind.noFailure;
  if (userCanceled) return PlaybackRecoveryFailureKind.userCanceled;
  if (authenticationRequired) {
    return PlaybackRecoveryFailureKind.authenticationRequired;
  }
  if (paidContent) return PlaybackRecoveryFailureKind.paidContent;
  if (!networkAvailable) return PlaybackRecoveryFailureKind.networkUnavailable;
  return PlaybackRecoveryFailureKind.transientResolution;
}

/// 单首歌曲的有限自动恢复预算，避免后台网络故障形成永久重试循环。
class PlaybackRecoveryBudget {
  PlaybackRecoveryBudget({
    this.maxAttempts = 3,
    this.backoff = const [
      Duration(seconds: 30),
      Duration(seconds: 60),
      Duration(seconds: 120),
    ],
  });

  final int maxAttempts;
  final List<Duration> backoff;
  String? _songId;
  int _attempts = 0;

  int get attempts => _attempts;

  /// 开始一次恢复尝试；返回false时本歌曲自动预算已耗尽。
  bool tryConsume(String songId) {
    if (_songId != songId) reset(songId);
    if (_attempts >= maxAttempts) return false;
    _attempts++;
    return true;
  }

  /// 失败后下次后台重试等待时间；耗尽后返回null。
  Duration? get nextDelay {
    if (_attempts >= maxAttempts || backoff.isEmpty) return null;
    final index = _attempts.clamp(0, backoff.length - 1);
    return backoff[index];
  }

  void reset([String? songId]) {
    _songId = songId;
    _attempts = 0;
  }
}
