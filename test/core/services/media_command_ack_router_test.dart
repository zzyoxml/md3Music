import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/media_notification_service.dart';

void main() {
  group('MediaCommandAckRouter', () {
    test('缺少回调时不确认，稍后可以同 ID 执行', () {
      final router = MediaCommandAckRouter();
      var calls = 0;

      expect(router.dispatch(1, null), isFalse);
      expect(router.dispatch(1, () => calls++), isTrue);
      expect(calls, 1);
    });

    test('回调抛错时不记为已处理，原生同 ID 重试可以成功执行', () {
      final router = MediaCommandAckRouter();
      var calls = 0;

      expect(
        () => router.dispatch(4, () {
          calls++;
          if (calls == 1) throw StateError('暂时无法接收命令');
        }),
        throwsStateError,
      );
      expect(router.dispatch(4, () => calls++), isTrue);
      expect(router.dispatch(4, () => calls++), isTrue);
      expect(calls, 2);
    });

    test('重复 ID 确认成功但只调用一次；新 ID 正常执行', () {
      final router = MediaCommandAckRouter();
      var calls = 0;
      void callback() => calls++;

      expect(router.dispatch(7, callback), isTrue);
      expect(router.dispatch(7, callback), isTrue);
      expect(router.dispatch(8, callback), isTrue);
      expect(calls, 2);
    });

    test('去重历史有界，淘汰旧 ID 后允许后续新代重用', () {
      final router = MediaCommandAckRouter(maxRememberedCommands: 2);
      var calls = 0;
      void callback() => calls++;

      router.dispatch(1, callback);
      router.dispatch(2, callback);
      router.dispatch(3, callback);
      router.dispatch(1, callback);
      expect(calls, 4);
    });
  });
}
