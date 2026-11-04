import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/recognition/recognition_utils.dart';

/// 构造一段只有头部的 WAV：RIFF/WAVE + fmt + data（数据长度可为 0）。
Uint8List buildWavHeader({
  required int sampleRate,
  required int channels,
  int bitsPerSample = 16,
  int dataBytes = 0,
}) {
  final buffer = ByteData(44);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      buffer.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  ascii(0, 'RIFF');
  buffer.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  buffer.setUint32(16, 16, Endian.little);
  buffer.setUint16(20, 1, Endian.little); // PCM
  buffer.setUint16(22, channels, Endian.little);
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, byteRate, Endian.little);
  buffer.setUint16(32, blockAlign, Endian.little);
  buffer.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  buffer.setUint32(40, dataBytes, Endian.little);
  return buffer.buffer.asUint8List();
}

void main() {
  group('parseWavInfo', () {
    test('从 fmt 块读出 48000Hz 双声道', () {
      final info = parseWavInfo(buildWavHeader(sampleRate: 48000, channels: 2));
      expect(info, isNotNull);
      expect(info!.sampleRate, 48000);
      expect(info.channels, 2);
    });

    test('从 fmt 块读出 44100Hz 单声道', () {
      final info = parseWavInfo(buildWavHeader(sampleRate: 44100, channels: 1));
      expect(info, isNotNull);
      expect(info!.sampleRate, 44100);
      expect(info.channels, 1);
    });

    test('非 RIFF 数据返回 null', () {
      expect(parseWavInfo(Uint8List.fromList(List<int>.filled(64, 0))), isNull);
    });

    test('过短数据返回 null（不越界）', () {
      expect(parseWavInfo(Uint8List.fromList([0x52, 0x49])), isNull);
    });
  });

  group('downmixToMono', () {
    test('双声道取算术平均', () {
      // 帧1: L=1000 R=2000 → 1500；帧2: L=-1000 R=-2000 → -1500
      final pcm = Uint8List(8);
      final view = pcm.buffer.asByteData();
      view.setInt16(0, 1000, Endian.little);
      view.setInt16(2, 2000, Endian.little);
      view.setInt16(4, -1000, Endian.little);
      view.setInt16(6, -2000, Endian.little);

      final mono = downmixToMono(pcm, 2);
      expect(mono.length, 4);
      final out = mono.buffer.asByteData();
      expect(out.getInt16(0, Endian.little), 1500);
      expect(out.getInt16(2, Endian.little), -1500);
    });

    test('单声道原样返回（同一实例）', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      expect(identical(downmixToMono(pcm, 1), pcm), isTrue);
    });
  });

  group('describeRecordingStartError', () {
    test('权限被拒给出隐私设置路径', () {
      final text = describeRecordingStartError(
        'PlatformException(Record, System error, 0x80070005)',
        windows: true,
      );
      expect(text, contains('隐私'));
      expect(text, contains('麦克风'));
    });

    test('设备占用/拔出给出可操作提示', () {
      final text = describeRecordingStartError('0xC00D36FA', windows: true);
      expect(text, contains('占用'));
    });

    test('未知错误保留原始信息', () {
      final text = describeRecordingStartError('boom', windows: true);
      expect(text, contains('boom'));
    });
  });

  group('kWindowsCaptureFormats', () {
    test('首个候选是 48000Hz 单声道，含立体声兜底', () {
      expect(kWindowsCaptureFormats.first.sampleRate, 48000);
      expect(kWindowsCaptureFormats.first.channels, 1);
      expect(kWindowsCaptureFormats.any((f) => f.channels == 2), isTrue);
    });
  });
}
