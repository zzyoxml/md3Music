import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/audio_scanner.dart';

void main() {
  test('Android 扫描排除默认 Media3 不支持的容器，Windows 仍保留格式', () {
    expect(isAudioFileSupported('song.mp3', isAndroid: true), isTrue);
    expect(isAudioFileSupported('song.ape', isAndroid: true), isFalse);
    expect(isAudioFileSupported('song.wma', isAndroid: true), isFalse);
    expect(isAudioFileSupported('song.aiff', isAndroid: true), isFalse);
    expect(isAudioFileSupported('song.ape', isAndroid: false), isTrue);
    expect(isAndroidUnsupportedAudioFile('song.WMA'), isTrue);
  });

  test('后台枚举去重重叠根目录，跳过排除目录与不可访问根，保留健康兄弟目录', () async {
    final temp = await Directory('tmp').absolute.create(recursive: true);
    final root = await temp.createTemp('md3_scan_test_');
    try {
      final good = await Directory('${root.path}/good').create();
      final excluded = await Directory('${root.path}/excluded').create();
      await File('${good.path}/one.mp3').writeAsBytes([0]);
      await File('${good.path}/two.FLAC').writeAsBytes([0]);
      await File('${good.path}/not_music.txt').writeAsBytes([0]);
      await File('${excluded.path}/hidden.mp3').writeAsBytes([0]);
      final files = await compute(collectAudioFilesInIsolate, {
        'roots': [root.path, good.path, '${root.path}/missing'],
        'excluded': [excluded.path],
      });
      expect(files.toSet(), {'${good.path}${Platform.pathSeparator}one.mp3',
        '${good.path}${Platform.pathSeparator}two.FLAC'});
      expect(files.length, 2);
    } finally {
      assert(root.absolute.path.startsWith(temp.path + Platform.pathSeparator));
      await root.delete(recursive: true);
    }
  });

  test('损坏音频和失效文件不会让整个 metadata 批次抛异常', () async {
    final temp = await Directory('tmp').absolute.create(recursive: true);
    final root = await temp.createTemp('md3_bad_audio_');
    try {
      final bad = await File('${root.path}/bad.mp3').writeAsBytes([0, 1, 2]);
      final result = await compute(scanAudioFilesInIsolate,
          [bad.path, '${root.path}/missing.mp3']);
      expect(result, isEmpty);
    } finally {
      assert(root.absolute.path.startsWith(temp.path + Platform.pathSeparator));
      await root.delete(recursive: true);
    }
  });
}
