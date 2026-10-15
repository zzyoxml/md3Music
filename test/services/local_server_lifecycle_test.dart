import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/local_server_lifecycle.dart';

void main() {
  group('LocalServerLifecycle', () {
    test('native start和stop按提交顺序串行执行', () async {
      final queue = AsyncSerialQueue();
      final entered = Completer<void>();
      final release = Completer<void>();
      final operations = <String>[];
      final start = queue.run(() async {
        operations.add('start.begin');
        entered.complete();
        await release.future;
        operations.add('start.end');
      });
      await entered.future;
      final stop = queue.run(() async => operations.add('stop'));

      expect(operations, ['start.begin']);
      release.complete();
      await Future.wait([start, stop]);
      expect(operations, ['start.begin', 'start.end', 'stop']);
    });

    test('旧启动代次不能放行新代次的请求', () async {
      final lifecycle = LocalServerLifecycle();
      final oldGeneration = lifecycle.beginStart();
      final oldWaiter = lifecycle.waitUntilReady(
        timeout: const Duration(seconds: 1),
      );
      final currentGeneration = lifecycle.beginStart();
      final currentWaiter = lifecycle.waitUntilReady(
        timeout: const Duration(seconds: 1),
      );

      expect(await oldWaiter, isFalse);
      expect(lifecycle.markReady(oldGeneration), isFalse);
      expect(lifecycle.markFailed(oldGeneration), isFalse);
      expect(lifecycle.markReady(currentGeneration), isTrue);
      expect(await currentWaiter, isTrue);
      expect(lifecycle.state, LocalServerState.ready);
    });

    test('启动切代时请求等待新ready，沿用同一总时限', () async {
      final lifecycle = LocalServerLifecycle();
      lifecycle.beginStart();
      final waiter = lifecycle.waitUntilCurrentReady(
        timeout: const Duration(seconds: 1),
      );
      final currentGeneration = lifecycle.beginStart();
      expect(lifecycle.markReady(currentGeneration), isTrue);
      expect(await waiter, isTrue);
    });

    test('启动失败立即结束ready等待，不用等到超时', () async {
      final lifecycle = LocalServerLifecycle();
      final generation = lifecycle.beginStart();
      final waiter = lifecycle.waitUntilReady(
        timeout: const Duration(seconds: 1),
      );

      expect(lifecycle.markFailed(generation), isTrue);
      expect(await waiter, isFalse);
      expect(lifecycle.state, LocalServerState.failed);
    });

    test('停止时拒绝请求，停止后的迟到ready无效', () async {
      final lifecycle = LocalServerLifecycle();
      final startGeneration = lifecycle.beginStart();
      final waiter = lifecycle.waitUntilReady(
        timeout: const Duration(seconds: 1),
      );
      final stopGeneration = lifecycle.beginStop();

      expect(await waiter, isFalse);
      expect(lifecycle.markReady(startGeneration), isFalse);
      expect(lifecycle.markStopped(stopGeneration), isTrue);
      expect(lifecycle.state, LocalServerState.stopped);
      expect(
        await lifecycle.waitUntilReady(timeout: const Duration(seconds: 1)),
        isFalse,
      );
    });

    test('ready超时返回false，后续新启动仍可成功', () async {
      final lifecycle = LocalServerLifecycle();
      lifecycle.beginStart();
      expect(await lifecycle.waitUntilReady(timeout: Duration.zero), isFalse);
      final generation = lifecycle.beginStart();
      expect(lifecycle.markReady(generation), isTrue);
      expect(
        await lifecycle.waitUntilReady(timeout: const Duration(seconds: 1)),
        isTrue,
      );
    });
  });
}
