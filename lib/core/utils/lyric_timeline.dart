import 'dart:math' show max;

/// 歌词时间轴与音频时间轴的互逆转换；调用方对本地歌词传入零偏移。
Duration lyricDisplayPosition(Duration position, {required int offsetMs}) =>
    Duration(milliseconds: max(0, position.inMilliseconds - offsetMs));

Duration lyricSeekPosition(Duration timestamp, {required int offsetMs}) =>
    Duration(milliseconds: max(0, timestamp.inMilliseconds + offsetMs));
