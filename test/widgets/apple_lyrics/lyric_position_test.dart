import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/utils/lyric_position.dart';

void main() {
  group('adjustLyricPosition', () {
    test('positive offset delays lyric highlighting', () {
      expect(
        adjustLyricPosition(const Duration(milliseconds: 1200), 300),
        const Duration(milliseconds: 900),
      );
    });

    test('negative offset advances lyric highlighting', () {
      expect(
        adjustLyricPosition(const Duration(milliseconds: 1200), -300),
        const Duration(milliseconds: 1500),
      );
    });

    test('positive offset clamps before the first line to zero', () {
      expect(
        adjustLyricPosition(const Duration(milliseconds: 100), 500),
        Duration.zero,
      );
    });

    test('negative offset at the start produces a nonnegative position', () {
      expect(
        adjustLyricPosition(Duration.zero, -500),
        const Duration(milliseconds: 500),
      );
    });
  });
}
