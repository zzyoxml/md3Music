import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_clock.dart';

void main() {
  group('estimatePosition', () {
    test('播放中外推：base + (now - sampledAt)', () {
      final pos = estimatePosition(
        base: const Duration(seconds: 3),
        wallClock: const Duration(seconds: 10, milliseconds: 200),
        sampleClock: const Duration(seconds: 10),
        isPlaying: true,
      );
      expect(pos, const Duration(milliseconds: 3200));
    });

    test('暂停时不做外推', () {
      final pos = estimatePosition(
        base: const Duration(seconds: 3),
        wallClock: const Duration(seconds: 10, milliseconds: 200),
        sampleClock: const Duration(seconds: 10),
        isPlaying: false,
      );
      expect(pos, const Duration(seconds: 3));
    });

    test('时钟回拨（wallClock < sampleClock）返回 base', () {
      final pos = estimatePosition(
        base: const Duration(seconds: 3),
        wallClock: const Duration(seconds: 9),
        sampleClock: const Duration(seconds: 10),
        isPlaying: true,
      );
      expect(pos, const Duration(seconds: 3));
    });
  });
}
