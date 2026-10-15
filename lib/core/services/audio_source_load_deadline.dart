import 'dart:async';

/// 播放音源加载超过用户等待预算时抛出；平台操作可能仍在收尾。
class AudioSourceLoadDeadlineExceeded extends TimeoutException {
  AudioSourceLoadDeadlineExceeded(Duration timeout)
    : super('Audio source load exceeded ${timeout.inMilliseconds}ms', timeout);
}

/// 为不能由Dart中断的平台加载Future提供截止状态与迟到结算回调。
class AudioSourceLoadDeadline {
  static Future<T> run<T>(
    Future<T> Function() operation, {
    required Duration timeout,
    void Function()? onDeadline,
    void Function({required bool succeeded, Object? error})? onLateSettlement,
  }) async {
    final source = Future<T>.sync(operation);
    var deadlineExceeded = false;

    // Future.timeout不会取消源Future。提前接收迟到成功/错误，供调用方记录
    // cleanupPending何时真正结算，也避免迟到的平台异常变成未处理异步错误。
    source.then<void>(
      (_) {
        if (deadlineExceeded) {
          _notifyLateSettlement(onLateSettlement, succeeded: true);
        }
      },
      onError: (Object error, StackTrace _) {
        if (deadlineExceeded) {
          _notifyLateSettlement(
            onLateSettlement,
            succeeded: false,
            error: error,
          );
        }
      },
    );

    return source.timeout(
      timeout,
      onTimeout: () {
        // 在超时回调内同步置位，避免源Future恰好同时完成时漏掉迟到结算。
        deadlineExceeded = true;
        try {
          onDeadline?.call();
        } catch (_) {}
        throw AudioSourceLoadDeadlineExceeded(timeout);
      },
    );
  }

  static void _notifyLateSettlement(
    void Function({required bool succeeded, Object? error})? callback, {
    required bool succeeded,
    Object? error,
  }) {
    try {
      callback?.call(succeeded: succeeded, error: error);
    } catch (_) {}
  }
}
