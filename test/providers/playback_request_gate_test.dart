import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/playback_request_gate.dart';

void main() {
  group('PlaybackRequestGate', () {
    test('新播放请求会使旧请求失效', () {
      final gate = PlaybackRequestGate();
      final oldRequest = gate.issue();
      final newRequest = gate.issue();

      expect(gate.isCurrent(oldRequest), isFalse);
      expect(gate.isCurrent(newRequest), isTrue);
    });

    test('暂停或停止可以取消尚未完成的请求', () {
      final gate = PlaybackRequestGate();
      final request = gate.issue();

      gate.invalidate();

      expect(gate.isCurrent(request), isFalse);
    });

    test('取消后可以正常开始新的请求', () {
      final gate = PlaybackRequestGate();
      final oldRequest = gate.issue();
      gate.invalidate();
      final newRequest = gate.issue();

      expect(gate.isCurrent(oldRequest), isFalse);
      expect(gate.isCurrent(newRequest), isTrue);
    });
  });
}
