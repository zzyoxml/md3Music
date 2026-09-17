import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/utils/audio_format_utils.dart';

/// `AudioFormatUtils.parseWavBitsForTest` 的 WAV 解析分支（RIFF chunk 链遍历）。
///
/// 背景（2026-09-14）：旧实现硬编码 bitsPerSample@34，仅对「RIFF 后紧跟 16 字节
/// fmt」的规范布局成立；fmt 前有 JUNK/LIST、fmt 为 18/40 字节（EXTENSIBLE）、
/// 或 IEEE float 的实际产物解析失败 → USB 独占格式链「源文件」行缺位深。
void main() {
  Uint8List chunk(String id, List<int> body) {
    final b = BytesBuilder();
    b.add(id.codeUnits);
    b.add(_u32(body.length));
    b.add(body);
    if (body.length.isOdd) b.add([0]); // chunk 按 2 字节对齐
    return b.toBytes();
  }

  /// fmt chunk 体：tag(2) ch(2) rate(4) byteRate(4) align(2) bits(2) [cbSize(2)+ext(22)]
  Uint8List fmtBody({required int tag, required int bits, int extBytes = 0}) {
    final b = BytesBuilder();
    b.add(_u16(tag));
    b.add(_u16(2)); // channels
    b.add(_u32(48000)); // sample rate
    b.add(_u32(48000 * 2 * (bits ~/ 8))); // byte rate
    b.add(_u16(2 * (bits ~/ 8))); // block align
    b.add(_u16(bits)); // wBitsPerSample
    if (extBytes > 0) {
      b.add(_u16(22)); // cbSize
      b.add(List<int>.filled(extBytes, 0));
    }
    return b.toBytes();
  }

  Uint8List wav(List<Uint8List> chunks, {String magic = 'RIFF'}) {
    var riffSize = 4;
    for (final c in chunks) {
      riffSize += c.length;
    }
    final out = BytesBuilder();
    out.add(magic.codeUnits);
    out.add(_u32(riffSize));
    out.add('WAVE'.codeUnits);
    for (final c in chunks) {
      out.add(c);
    }
    return out.toBytes();
  }

  test('规范布局：16 字节 fmt 紧跟 RIFF 头（与旧 offset-34 等价）', () {
    final head = wav(<Uint8List>[
      chunk('fmt ', fmtBody(tag: 1, bits: 24)),
      chunk('data', List<int>.filled(16, 0)),
    ]);
    expect(AudioFormatUtils.parseWavBitsForTest(head), 24);
  });

  test('fmt 前有 JUNK/LIST chunk（非规范布局，旧实现解析失败）', () {
    final head = wav(<Uint8List>[
      chunk('JUNK', List<int>.filled(28, 0x00)),
      chunk('LIST', 'INFOhello'.codeUnits),
      chunk('fmt ', fmtBody(tag: 1, bits: 32)),
      chunk('data', List<int>.filled(16, 0)),
    ]);
    expect(AudioFormatUtils.parseWavBitsForTest(head), 32);
  });

  test('WAVE_FORMAT_EXTENSIBLE（fmt 40 字节，tag=0xFFFE）', () {
    final head = wav(<Uint8List>[
      chunk('fmt ', fmtBody(tag: 0xFFFE, bits: 24, extBytes: 22)),
      chunk('data', List<int>.filled(16, 0)),
    ]);
    expect(AudioFormatUtils.parseWavBitsForTest(head), 24);
  });

  test('IEEE float（tag=3，32bit）', () {
    final head = wav(<Uint8List>[
      chunk('fmt ', fmtBody(tag: 3, bits: 32)),
      chunk('data', List<int>.filled(16, 0)),
    ]);
    expect(AudioFormatUtils.parseWavBitsForTest(head), 32);
  });

  test('畸形 chunk size → 跳过时不越界，走完头部返回 null', () {
    final junk = chunk('JUNK', List<int>.filled(16, 0x00));
    junk[7] = 0x7F; // size = 0x7F000010，远超头部缓冲
    final head = wav(<Uint8List>[
      junk,
      chunk('fmt ', fmtBody(tag: 1, bits: 16)),
    ]);
    // size 巨大 ⇒ 遍历越过 head 末尾终止（不得越界读），fmt 不可达 ⇒ null
    expect(AudioFormatUtils.parseWavBitsForTest(head), isNull);
  });

  test('非 WAVE/非 RIFF → null', () {
    final head = Uint8List.fromList('OGGS'.codeUnits + List<int>.filled(64, 0));
    expect(AudioFormatUtils.parseWavBitsForTest(head), isNull);
  });
}

Uint8List _u16(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

Uint8List _u32(int v) => Uint8List.fromList([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
