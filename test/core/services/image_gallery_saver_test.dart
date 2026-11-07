import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/image_gallery_saver.dart';

/// 保存图片到相册：文件名规则、下载失败分支、MethodChannel 调用契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/image_saver');
  late List<MethodCall> calls;
  late Directory tempDir;

  setUp(() async {
    calls = [];
    tempDir = await Directory.systemTemp.createTemp('image_saver_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'content://media/external/images/media/42';
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('imageFileNameFor', () {
    final now = DateTime(2026, 9, 30, 14, 25, 30);

    test('jpg 链接生成带时间戳与盐值的 jpg 文件名', () {
      final name = ImageGallerySaver.imageFileNameFor(
        Uri.parse('https://cmtimgbssdl.cloud.kugou.com/a/photo.jpg?x=1'),
        now,
      );
      expect(name, matches(RegExp(r'^MD3Music_20260930_142530_[0-9a-f]{4}\.jpg$')));
    });

    test('png/gif/webp 保留扩展名', () {
      for (final ext in ['png', 'gif', 'webp']) {
        final name = ImageGallerySaver.imageFileNameFor(
          Uri.parse('https://a/b.$ext'),
          now,
        );
        expect(name.endsWith('.$ext'), isTrue, reason: ext);
      }
    });

    test('未知/缺失扩展名回退 jpg；带查询串也能正确取扩展名', () {
      expect(
        ImageGallerySaver.imageFileNameFor(Uri.parse('https://a/b'), now),
        endsWith('.jpg'),
      );
      expect(
        ImageGallerySaver.imageFileNameFor(Uri.parse('https://a/b.avif'), now),
        endsWith('.jpg'),
      );
      expect(
        ImageGallerySaver.imageFileNameFor(
          Uri.parse('https://a/b.png?token=1&v=2'),
          now,
        ),
        endsWith('.png'),
      );
    });

    test('同一秒不同 URL 的文件名不重复', () {
      final a = ImageGallerySaver.imageFileNameFor(Uri.parse('https://a/1.jpg'), now);
      final b = ImageGallerySaver.imageFileNameFor(Uri.parse('https://a/2.jpg'), now);
      expect(a, isNot(b));
    });
  });

  group('downloadImageBytes', () {
    test('返回注入的字节', () async {
      final bytes = await ImageGallerySaver.downloadImageBytes(
        Uri.parse('https://a/1.jpg'),
        fetcher: (_) async => Uint8List.fromList([1, 2, 3]),
      );
      expect(bytes, [1, 2, 3]);
    });

    test('空内容抛 ImageSaveException', () {
      expect(
        () => ImageGallerySaver.downloadImageBytes(
          Uri.parse('https://a/1.jpg'),
          fetcher: (_) async => Uint8List(0),
        ),
        throwsA(isA<ImageSaveException>()),
      );
    });

    test('超过体积上限抛 ImageSaveException', () {
      expect(
        () => ImageGallerySaver.downloadImageBytes(
          Uri.parse('https://a/1.jpg'),
          fetcher: (_) async => Uint8List(ImageGallerySaver.maxBytes + 1),
        ),
        throwsA(isA<ImageSaveException>()),
      );
    });
  });

  group('saveImageToGallery', () {
    test('下载 → 写临时文件 → 调 saveImage，返回 content uri', () async {
      final saved = await ImageGallerySaver.saveImageToGallery(
        'https://a/1.jpg',
        now: DateTime(2026, 9, 30, 14, 25, 30),
        fetcher: (_) async => Uint8List.fromList([9, 9, 9]),
        tempDir: () async => tempDir,
      );

      expect(saved, 'content://media/external/images/media/42');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveImage');
      final args = Map<Object?, Object?>.from(calls.single.arguments as Map);
      expect((args['fileName'] as String).endsWith('.jpg'), isTrue);
      // 传给原生的临时文件必须真实存在且内容一致
      final tmp = File(args['path'] as String);
      expect(tmp.existsSync(), isTrue);
      expect(tmp.readAsBytesSync(), [9, 9, 9]);
    });

    test('原生抛 PlatformException → 包装成 ImageSaveException', () {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'SAVE_FAILED', message: '磁盘满了');
      });
      expect(
        () => ImageGallerySaver.saveImageToGallery(
          'https://a/1.jpg',
          now: DateTime(2026),
          fetcher: (_) async => Uint8List.fromList([1]),
          tempDir: () async => tempDir,
        ),
        throwsA(
          isA<ImageSaveException>().having((e) => e.message, 'message', '磁盘满了'),
        ),
      );
    });

    test('非 http(s) 地址直接拒绝，不发起下载', () async {
      await expectLater(
        ImageGallerySaver.saveImageToGallery(
          'file:///etc/passwd',
          fetcher: (_) async => Uint8List.fromList([1]),
          tempDir: () async => tempDir,
        ),
        throwsA(isA<ImageSaveException>()),
      );
      expect(calls, isEmpty);
    });
  });
}
