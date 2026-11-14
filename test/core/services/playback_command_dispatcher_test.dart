import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../../lib/core/services/playback_command_dispatcher.dart';

void main() {
  test('生命周期Future未结束时命令派发已返回，迟到错误仍被接收', () async {
    final playback = Completer<void>();
    final failure = Completer<Object>();
    final dispatched = Completer<void>();

    await dispatchPlaybackCommand(
      playback.future,
      onError: (error, _) {
        failure.complete(error);
      },
    );
    dispatched.complete();

    await dispatched.future;
    expect(playback.isCompleted, isFalse);

    final expectedError = StateError('platform play failed');
    playback.completeError(expectedError, StackTrace.current);
    expect(await failure.future, same(expectedError));
  });
}
