import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_source_load_deadline.dart';

void main() {
  test('装载在截止前完成时正常返回', () async {
    final result = await AudioSourceLoadDeadline.run<int>(
      () async => 7,
      timeout: const Duration(seconds: 1),
    );

    expect(result, 7);
  });

  test('15秒截止前仍等待，到点超时且迟到成功只结算一次', () {
    fakeAsync((async) {
      final source = Completer<void>();
      var deadlineCount = 0;
      var lateSettlementCount = 0;
      Object? loadError;

      AudioSourceLoadDeadline.run<void>(
        () => source.future,
        timeout: const Duration(seconds: 15),
        onDeadline: () => deadlineCount++,
        onLateSettlement: ({required succeeded, error}) {
          expect(succeeded, isTrue);
          lateSettlementCount++;
        },
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace _) => loadError = error,
      );

      async.elapse(const Duration(seconds: 14, milliseconds: 999));
      async.flushMicrotasks();
      expect(loadError, isNull);
      expect(deadlineCount, 0);

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(loadError, isA<AudioSourceLoadDeadlineExceeded>());
      expect(deadlineCount, 1);

      source.complete();
      async.flushMicrotasks();
      expect(lateSettlementCount, 1);
    });
  });

  test('截止后的原Future错误会被接收并报告', () {
    fakeAsync((async) {
      final source = Completer<void>();
      Object? loadError;
      Object? lateError;

      AudioSourceLoadDeadline.run<void>(
        () => source.future,
        timeout: const Duration(seconds: 15),
        onLateSettlement: ({required succeeded, error}) => lateError = error,
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace _) => loadError = error,
      );

      async.elapse(const Duration(seconds: 15));
      async.flushMicrotasks();
      expect(loadError, isA<AudioSourceLoadDeadlineExceeded>());

      source.completeError(StateError('late platform failure'));
      async.flushMicrotasks();
      expect(lateError, isA<StateError>());
    });
  });
}
