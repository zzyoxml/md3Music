import 'dart:async';

/// 接收播放生命周期Future的迟到异常，但不等待歌曲暂停或自然结束。
Future<void> dispatchPlaybackCommand(
  Future<void> playback, {
  required void Function(Object error, StackTrace stackTrace) onError,
}) async {
  unawaited(
    playback.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        onError(error, stackTrace);
      },
    ),
  );
}
