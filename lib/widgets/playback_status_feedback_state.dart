/// 播放状态提示条的显示模型。
///
/// 错误优先于仍未结束的加载标志，避免请求失败后界面继续显示不可操作的
/// “正在准备播放/取消”；只有没有错误时才显示准备状态。
enum PlaybackFeedbackPhase { hidden, preparing, awaitingProgress, failed }

class PlaybackStatusFeedbackState {
  final PlaybackFeedbackPhase phase;
  final String? errorMessage;

  const PlaybackStatusFeedbackState._(this.phase, this.errorMessage);

  factory PlaybackStatusFeedbackState.resolve({
    required bool loading,
    bool awaitingProgress = false,
    required String? errorMessage,
  }) {
    if (errorMessage != null && errorMessage.trim().isNotEmpty) {
      return PlaybackStatusFeedbackState._(
        PlaybackFeedbackPhase.failed,
        errorMessage,
      );
    }
    if (loading) {
      return const PlaybackStatusFeedbackState._(
        PlaybackFeedbackPhase.preparing,
        null,
      );
    }
    if (awaitingProgress) {
      return const PlaybackStatusFeedbackState._(
        PlaybackFeedbackPhase.awaitingProgress,
        null,
      );
    }
    return const PlaybackStatusFeedbackState._(
      PlaybackFeedbackPhase.hidden,
      null,
    );
  }

  bool get visible => phase != PlaybackFeedbackPhase.hidden;
  bool get isPreparing => phase == PlaybackFeedbackPhase.preparing;
  bool get isAwaitingProgress =>
      phase == PlaybackFeedbackPhase.awaitingProgress;

  String get message => switch (phase) {
    PlaybackFeedbackPhase.preparing => '正在准备播放',
    PlaybackFeedbackPhase.awaitingProgress => '播放命令已发出，等待音频进度',
    PlaybackFeedbackPhase.failed => errorMessage!,
    PlaybackFeedbackPhase.hidden => '',
  };

  String? get actionLabel => switch (phase) {
    PlaybackFeedbackPhase.preparing => '取消',
    PlaybackFeedbackPhase.awaitingProgress => '暂停',
    PlaybackFeedbackPhase.failed => '重试',
    PlaybackFeedbackPhase.hidden => null,
  };
}
