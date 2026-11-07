import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/player_artwork_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造一张最小 PNG（1×1）落到临时目录，返回 file:// URI。
  String writeTempPng(String name) {
    const pngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    final dir = Directory.systemTemp.createTempSync('md3_art_ready');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/$name.png')
      ..writeAsBytesSync(base64Decode(pngBase64));
    return Uri.file(file.path).toString();
  }

  group('isPlayerArtworkReady', () {
    test('uri 为空：按就绪（无可探测之物）', () async {
      expect(
        await isPlayerArtworkReady(
          artworkUri: null,
          settledLogicalWidth: 300,
          devicePixelRatio: 2.75,
        ),
        isTrue,
      );
    });

    test('local:// 内嵌封面：按就绪（外部无法同键探测）', () async {
      expect(
        await isPlayerArtworkReady(
          artworkUri: 'local:///song.mp3',
          settledLogicalWidth: 300,
          devicePixelRatio: 2.75,
        ),
        isTrue,
      );
    });

    test('file:// 指向不存在的文件：按就绪（探测不了，交给渲染层兜底）', () async {
      expect(
        await isPlayerArtworkReady(
          artworkUri: 'file:///no/such/cover.png',
          settledLogicalWidth: 300,
          devicePixelRatio: 2.75,
        ),
        isTrue,
      );
    });

    test('file:// 真实文件：就绪', () async {
      final uri = writeTempPng('ready');
      expect(
        await isPlayerArtworkReady(
          artworkUri: uri,
          settledLogicalWidth: 300,
          devicePixelRatio: 2.75,
        ),
        isTrue,
      );
    });
  });
}
