import 'dart:async';

enum LocalServerState { starting, ready, failed, stopping, stopped }

/// 串行运行native启停操作；单项失败不会让后续操作失去执行机会。
class AsyncSerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

/// 本地服务就绪状态按代次发布，旧启动任务不能完成新一代的等待者。
class LocalServerLifecycle {
  int _generation = 0;
  LocalServerState _state = LocalServerState.starting;
  Completer<bool> _ready = Completer<bool>();

  int get generation => _generation;
  LocalServerState get state => _state;
  bool get isReady => _state == LocalServerState.ready;

  int beginStart() {
    _completeCurrent(false);
    _generation++;
    _state = LocalServerState.starting;
    _ready = Completer<bool>();
    return _generation;
  }

  int beginStop() {
    _completeCurrent(false);
    _generation++;
    _state = LocalServerState.stopping;
    _ready = Completer<bool>()..complete(false);
    return _generation;
  }

  bool markReady(int generation) {
    if (generation != _generation || _state != LocalServerState.starting) {
      return false;
    }
    _state = LocalServerState.ready;
    _completeCurrent(true);
    return true;
  }

  bool markFailed(int generation) {
    if (generation != _generation ||
        (_state != LocalServerState.starting &&
            _state != LocalServerState.ready)) {
      return false;
    }
    _state = LocalServerState.failed;
    _completeCurrent(false);
    return true;
  }

  bool markStopped(int generation) {
    if (generation != _generation || _state != LocalServerState.stopping) {
      return false;
    }
    _state = LocalServerState.stopped;
    _completeCurrent(false);
    return true;
  }

  Future<bool> waitUntilReady({required Duration timeout}) {
    if (_state == LocalServerState.ready) return Future.value(true);
    if (_state != LocalServerState.starting) return Future.value(false);
    return _ready.future.timeout(timeout, onTimeout: () => false);
  }

  Future<bool> waitUntilCurrentReady({required Duration timeout}) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      final generation = _generation;
      final remaining = timeout - stopwatch.elapsed;
      final ready = await waitUntilReady(timeout: remaining);
      if (ready &&
          generation == _generation &&
          _state == LocalServerState.ready) {
        return true;
      }
      // 启动代次变化会以false唤醒旧等待者；继续等新代次，但共享同一总时限。
      if (generation == _generation) return false;
    }
    return _state == LocalServerState.ready;
  }

  void _completeCurrent(bool value) {
    if (!_ready.isCompleted) _ready.complete(value);
  }
}
