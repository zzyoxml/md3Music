import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/lyric_timeline.dart';

void main() {
  for (final offset in [200, -200, 0]) {
    test('歌词显示与点击互逆：offset=$offset ms', () {
      const timestamp = Duration(seconds: 10);
      final seek = lyricSeekPosition(timestamp, offsetMs: offset);
      expect(seek.inMilliseconds, 10000 + offset);
      expect(lyricDisplayPosition(seek, offsetMs: offset), timestamp);
    });
  }
  test('起点不产生负的播放位置或显示位置', () {
    expect(lyricDisplayPosition(Duration.zero, offsetMs: 200), Duration.zero);
    expect(lyricSeekPosition(Duration.zero, offsetMs: -200), Duration.zero);
  });
  test('AM 竖屏、横屏和平板均接入同一套显示及跳转映射', () {
    final source = File('lib/modules/player/full_player_am.dart').readAsStringSync();
    expect(RegExp('adaptTimeMs: _adjustedLyricTimeMs').allMatches(source).length, 3);
    expect(RegExp('onSeek: _seekToLyric').allMatches(source).length, 3);
  });
}
