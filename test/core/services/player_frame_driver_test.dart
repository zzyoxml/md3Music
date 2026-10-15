import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/player_frame_driver.dart';

void main() {
  // 驱动挂在 WidgetsBinding 上收口生命周期（后台停表），
  // 未经初始化的绑定下构造单例会抛错。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同一帧中被其他回调移除的订阅者不会再收到回调', () async {
    final driver = PlayerFrameDriver.instance;
    var removedCallbackCount = 0;
    void removeLater() => removedCallbackCount++;
    void remover() => driver.removeListener(removeLater);

    driver.addListener(remover);
    driver.addListener(removeLater);
    try {
      await Future<void>.delayed(PlayerFrameDriver.step * 2);
      expect(removedCallbackCount, 0);
    } finally {
      driver.removeListener(remover);
      driver.removeListener(removeLater);
    }
  });

  testWidgets('退后台停表、回前台恢复，且挂起不改订阅关系', (tester) async {
    final driver = PlayerFrameDriver.instance;
    void noop() {}
    try {
      driver.addListener(noop);
      expect(driver.isRunning, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(driver.isRunning, isFalse, reason: '后台不得保留 16ms 定时器（纯功耗）');
      expect(driver.hasListeners, isTrue, reason: '挂起只停表，不动订阅关系');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(driver.isRunning, isTrue, reason: '回前台且仍有订阅者时必须恢复产帧');
    } finally {
      driver.removeListener(noop);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  testWidgets('挂起期间订阅清空，回前台后不得空转', (tester) async {
    final driver = PlayerFrameDriver.instance;
    void noop() {}
    try {
      driver.addListener(noop);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      driver.removeListener(noop);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(driver.hasListeners, isFalse);
      expect(driver.isRunning, isFalse, reason: '无订阅者时不得重启定时器');
    } finally {
      driver.removeListener(noop);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });
}
