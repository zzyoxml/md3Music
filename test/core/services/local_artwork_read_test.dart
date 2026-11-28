import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/local_artwork_cache.dart';
import 'package:md3music/core/utils/audio_scanner.dart';
import 'package:md3music/core/utils/local_media_path.dart';

/// 内嵌封面**真实读盘**的回归测试。
///
/// 背景：播放解析把本地歌曲的 `localPath` 回写成 `file://` URI（中文/空格还会
/// percent 编码），封面读取链路此前把这个字符串直接交给 `File()`，于是
/// `existsSync()` 恒为 false → 播放页封面恒为占位符，而列表（用曲库对象、
/// 路径未回写）正常。这里用真实落盘的「MP3 + ID3v2.3 APIC」文件把这条线钉住：
/// 裸路径与 `file://` 两种入参必须读到**同一份**内嵌封面字节。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Uint8List pngBytes;
  late String barePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('md3_artwork_read');
    pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
      'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    // 中文 + 空格：同时覆盖 percent 编码与 UTF-8 两条解码路径
    barePath = '${tempDir.path}${Platform.pathSeparator}晴天 a.mp3';
    File(barePath).writeAsBytesSync(_buildMp3WithApic(pngBytes), flush: true);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('裸路径能读到内嵌封面字节', () {
    final result = readArtworkInIsolate(barePath);
    expect(result, isNotNull);
    expect(result!['bytes'], pngBytes);
  });

  test('契约：isolate 读盘函数只吃裸路径，归一化由上层的 LocalArtworkCache 负责', () {
    final fileUri = Uri.file(barePath).toString();
    expect(fileUri.contains('%'), isTrue, reason: '中文/空格必然被 percent 编码');

    // 为什么这条是「阴性断言」：`readArtworkInIsolate` 是 compute 入口，只接受
    // 裸磁盘路径。把 `file://` 直接喂进去必须读不到（`File()` 不认前缀与编码）——
    // 这正是 bug 的原始形态。修复点是让`LocalArtworkCache.getArtwork` 先归一，
    // 而不是在这个底层函数里偷偷做路径解析（它跑在 isolate，且被多处复用）。
    expect(readArtworkInIsolate(fileUri), isNull);

    final normalized = normalizeLocalMediaPath(fileUri);
    expect(normalized, isNotNull);
    final result = readArtworkInIsolate(normalized!);
    expect(result, isNotNull, reason: '归一后的路径必须能读到内嵌封面');
    expect(result!['bytes'], pngBytes);
  });

  test('LocalArtworkCache 端到端：file:// 入参穿透到读盘并返回字节', () async {
    // 走真实 compute 读盘路径（LocalArtworkCache() 单例没有注入 reader），
    // 覆盖「入口归一 → isolate 读元数据 → 返回字节」全链路。
    final bytes = await LocalArtworkCache().getArtwork(
      Uri.file(barePath).toString(),
    );
    expect(bytes, pngBytes);
  });

  test('归一后的路径确实指向同一文件（存在性证据）', () {
    final normalized =
        normalizeLocalMediaPath(Uri.file(barePath).toString());
    expect(normalized, isNotNull);
    expect(File(normalized!).existsSync(), isTrue);
  });

  test('无内嵌封面的音频仍返回 null（不伪造封面）', () {
    final plain = File('${tempDir.path}${Platform.pathSeparator}plain.mp3')
      ..writeAsBytesSync(_buildMp3WithoutApic(), flush: true);
    expect(readArtworkInIsolate(plain.path), isNull);
  });
}

// ── 最小 MP3 构造（仅 ID3v2.3 标签，足够让 audio_metadata_reader 识别）──

List<int> _synchsafe(int value) => [
  (value >> 21) & 0x7F,
  (value >> 14) & 0x7F,
  (value >> 7) & 0x7F,
  value & 0x7F,
];

Uint8List _buildMp3WithApic(Uint8List image) {
  final payload = <int>[
    0, // 文本编码 latin1
    ...'image/png'.codeUnits,
    0, // MIME 结束符
    3, // picture type: Front cover
    0, // 描述结束符
    ...image,
  ];
  return _wrapId3(<int>[
    ...'APIC'.codeUnits,
    ..._synchsafe(payload.length),
    0,
    0,
    ...payload,
  ]);
}

Uint8List _buildMp3WithoutApic() {
  // 只有一个 TIT2 帧，无 APIC：读封面必须得到 null。
  final payload = <int>[0, ...utf8.encode('no cover')];
  return _wrapId3(<int>[
    ...'TIT2'.codeUnits,
    ..._synchsafe(payload.length),
    0,
    0,
    ...payload,
  ]);
}

Uint8List _wrapId3(List<int> frames) {
  return Uint8List.fromList(<int>[
    ...'ID3'.codeUnits,
    3,
    0,
    0,
    ..._synchsafe(frames.length),
    ...frames,
  ]);
}
