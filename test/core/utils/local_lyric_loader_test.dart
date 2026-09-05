import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/local_lyric_loader.dart';

/// LocalLyricLoader 单元测试
///
/// 覆盖：同目录 .lrc / .ttml 文件查找与读取、内嵌优先（无内嵌时回退文件）、
/// 无歌词文件返回 null。用临时目录模拟本地歌曲。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lyric_loader_test');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File _write(String name, String content) {
    final f = File('${tempDir.path}${Platform.pathSeparator}$name');
    f.writeAsStringSync(content);
    return f;
  }

  test('L1. 音频无内嵌歌词时读取同目录同名 .lrc', () {
    // 构造一个无内嵌歌词的音频文件（用任意非音频内容模拟，readEmbeddedLyrics 会失败）
    final audio = _write('song.mp3', 'not a real mp3');
    _write('song.lrc', '[00:10.00]Hello world');

    final result = LocalLyricLoader.loadForAudio(audio.path);
    expect(result, '[00:10.00]Hello world');
  });

  test('L2. 无 .lrc 时回退 .ttml', () {
    final audio = _write('song.mp3', 'not a real mp3');
    _write('song.ttml', '<tt xmlns="http://www.w3.org/ns/ttml"></tt>');

    final result = LocalLyricLoader.loadForAudio(audio.path);
    expect(result, contains('<tt'));
  });

  test('L3. 无任何歌词文件返回 null', () {
    final audio = _write('song.mp3', 'not a real mp3');
    expect(LocalLyricLoader.loadForAudio(audio.path), isNull);
  });

  test('L4. 扩展名优先级：.lrc 优先于 .ttml', () {
    final audio = _write('song.mp3', 'not a real mp3');
    _write('song.lrc', '[00:10.00]LRC content');
    _write('song.ttml', '<tt xmlns="http://www.w3.org/ns/ttml">TTML</tt>');

    final result = LocalLyricLoader.loadForAudio(audio.path);
    expect(result, '[00:10.00]LRC content');
  });

  test('L5. 文件不存在返回 null', () {
    expect(
      LocalLyricLoader.loadForAudio(
          '${tempDir.path}${Platform.pathSeparator}missing.mp3'),
      isNull,
    );
  });
  test('L6. FLAC 内嵌歌词含 = 不被截断（audio_metadata_reader 1.4.1 bug 回归）', () {
    // 构造最小 FLAC：fLaC + STREAMINFO + VORBIS_COMMENT（LYRICS 为含 = 的 TTML XML）
    const lyrics = '<?xml version="1.0" encoding="utf-8"?><tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="0.000" end="5000">飞云之下</p></div></body></tt>';
    final flac = _buildFlacWithLyrics(lyrics);
    final f = File('${tempDir.path}${Platform.pathSeparator}song.flac');
    f.writeAsBytesSync(flac);

    final result = LocalLyricLoader.loadForAudio(f.path);
    // 必须是完整 XML，而非被 `=` 截断成 `<?xml version`
    expect(result, lyrics);
  });
}

/// 构造含 LYRICS 标签的最小 FLAC 二进制（fLaC + STREAMINFO + VORBIS_COMMENT）。
List<int> _buildFlacWithLyrics(String lyrics) {
  final out = <int>[];
  out.addAll('fLaC'.codeUnits);
  // STREAMINFO：type=0，非末块，len=34
  _appendFlacBlock(out, 0, false, List<int>.filled(34, 0));
  // VORBIS_COMMENT：type=4，末块
  final vendor = utf8.encode('test');
  final comment = utf8.encode('LYRICS=$lyrics');
  final vorbis = <int>[]
    ..addAll(_u32le(vendor.length))
    ..addAll(vendor)
    ..addAll(_u32le(1)) // comment 数
    ..addAll(_u32le(comment.length))
    ..addAll(comment);
  _appendFlacBlock(out, 4, true, vorbis);
  return out;
}

void _appendFlacBlock(List<int> out, int type, bool isLast, List<int> data) {
  out.add((isLast ? 0x80 : 0) | type);
  out.add((data.length >> 16) & 0xFF);
  out.add((data.length >> 8) & 0xFF);
  out.add(data.length & 0xFF);
  out.addAll(data);
}

List<int> _u32le(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
