import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/playback_recovery_flight.dart';

void main() {
  group('PlaybackRecoveryFlight', () {
    test('同时到达的恢复触发只允许一个任务进入', () {
      final flight = PlaybackRecoveryFlight();

      final first = flight.tryStart();

      expect(first, isNotNull);
      expect(flight.tryStart(), isNull);
      expect(flight.tryStart(), isNull);
      expect(flight.isCurrent(first!), isTrue);
    });

    test('旧任务finally不能释放手动接管后启动的新恢复任务', () {
      final flight = PlaybackRecoveryFlight();
      final oldToken = flight.tryStart()!;

      flight.invalidate(releaseInFlight: true);
      final newToken = flight.tryStart()!;
      flight.releaseIfOwned(oldToken);

      expect(flight.isCurrent(oldToken), isFalse);
      expect(flight.isCurrent(newToken), isTrue);
      expect(flight.inFlightToken, newToken);
      expect(flight.tryStart(), isNull);
    });

    test('失效的退避定时器不会匹配新恢复代次', () {
      final flight = PlaybackRecoveryFlight();
      final scheduledSequence = flight.sequence;

      flight.invalidate();

      expect(flight.isCurrent(scheduledSequence), isFalse);
      expect(flight.isCurrent(flight.sequence), isTrue);
    });
  });
}
