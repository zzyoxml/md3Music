import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/local_artwork_cache.dart';

void main() {
  test('同一路径的并发读取合并成一次，并缓存成功结果', () async {
    final result = Completer<Uint8List?>();
    var reads = 0;
    final cache = LocalArtworkCache.forTesting(
      reader: (_) {
        reads++;
        return result.future;
      },
    );

    final first = cache.getArtwork('/music/cover.flac');
    final second = cache.getArtwork('/music/cover.flac');
    expect(reads, 1);

    final bytes = Uint8List.fromList([1, 2, 3]);
    result.complete(bytes);
    expect(await first, same(bytes));
    expect(await second, same(bytes));
    expect(await cache.getArtwork('/music/cover.flac'), same(bytes));
    expect(reads, 1);
  });

  test('字节预算驱逐旧项，超预算单张只供当前调用者使用', () async {
    final reads = <String, int>{};
    final cache = LocalArtworkCache.forTesting(
      cacheByteLimit: 4,
      reader: (path) async {
        reads.update(path, (count) => count + 1, ifAbsent: () => 1);
        return Uint8List(path == 'large' ? 5 : 3);
      },
    );

    await cache.getArtwork('large');
    await cache.getArtwork('large');
    expect(reads['large'], 2);

    await cache.getArtwork('old');
    await cache.getArtwork('new');
    await cache.getArtwork('old');
    expect(reads['old'], 2);
    expect(reads['new'], 1);
  });

  test('条目数上限生效且命中会刷新LRU访问顺序', () async {
    final reads = <String, int>{};
    final cache = LocalArtworkCache.forTesting(
      cacheLimit: 2,
      cacheByteLimit: 100,
      reader: (path) async {
        reads.update(path, (count) => count + 1, ifAbsent: () => 1);
        return Uint8List.fromList([path.codeUnitAt(0)]);
      },
    );

    await cache.getArtwork('a');
    await cache.getArtwork('b');
    await cache.getArtwork('a'); // 命中后 a 成为最近使用项。
    await cache.getArtwork('c'); // 应逐出 b。
    await cache.getArtwork('a');
    await cache.getArtwork('b');

    expect(reads, {'a': 1, 'b': 2, 'c': 1});
  });

  test('clear后迟到的读取结果不会写回新缓存代次', () async {
    final staleResult = Completer<Uint8List?>();
    var reads = 0;
    final cache = LocalArtworkCache.forTesting(
      reader: (_) {
        reads++;
        return reads == 1
            ? staleResult.future
            : Future.value(Uint8List.fromList([2]));
      },
    );

    final pending = cache.getArtwork('/music/cover.flac');
    cache.clear();
    staleResult.complete(Uint8List.fromList([1]));
    expect(await pending, [1]);

    expect(await cache.getArtwork('/music/cover.flac'), [2]);
    expect(reads, 2);
  });

  test('clear后旧读取完成不会移除同路径的新in-flight请求', () async {
    final staleResult = Completer<Uint8List?>();
    final currentResult = Completer<Uint8List?>();
    var reads = 0;
    final cache = LocalArtworkCache.forTesting(
      reader: (_) {
        reads++;
        return reads == 1 ? staleResult.future : currentResult.future;
      },
    );

    final stale = cache.getArtwork('/music/cover.flac');
    cache.clear();
    final current = cache.getArtwork('/music/cover.flac');
    final duplicate = cache.getArtwork('/music/cover.flac');
    expect(reads, 2);

    staleResult.complete(Uint8List.fromList([1]));
    expect(await stale, [1]);
    final currentBytes = Uint8List.fromList([2]);
    currentResult.complete(currentBytes);
    expect(await current, same(currentBytes));
    expect(await duplicate, same(currentBytes));
    expect(reads, 2);
  });

  group('入口路径归一（播放页封面空白 bug 的回归）', () {
    test('file:// + percent 编码的入参：读的必须是归一后的磁盘路径', () async {
      // 播放解析把 localPath 回写成 `Uri.file(raw)`（中文/空格 percent 编码），
      // 而 `File('file://...')` 恒不存在 → 播放页封面恒为占位符。归一化必须
      // 发生在读盘之前，而不是让 `File()` 去猜。
      final seen = <String>[];
      final cache = LocalArtworkCache.forTesting(
        reader: (path) async {
          seen.add(path);
          return Uint8List.fromList([7]);
        },
      );

      final bytes = await cache.getArtwork(
        'file:///storage/emulated/0/Music/%E6%99%B4%E5%A4%A9.mp3',
      );

      expect(bytes, isNotNull);
      expect(seen, hasLength(1));
      expect(seen.single, isNot(contains('file://')));
      expect(seen.single, isNot(contains('%')));
      expect(seen.single, endsWith('晴天.mp3'));
    });

    test('同一文件经裸路径与 file:// 两种入参只读一次盘、共用一份字节', () async {
      // 列表用曲库对象（裸路径）、播放页用回写后的 file:// —— 同一张封面若各读
      // 一次盘、各占一个缓存位，就等于把 LRU 预算砍半且重复解码。
      //
      // 裸路径按平台取（Windows 的 `Uri.file` 会把 `/music/a.mp3` 解析成
      // `\music\a.mp3`，两者在 Windows 上本就不是同一条易读路径，断言会假红）。
      final raw = Platform.isWindows ? r'C:\music\a.mp3' : '/music/a.mp3';
      var reads = 0;
      final cache = LocalArtworkCache.forTesting(
        reader: (_) async {
          reads++;
          return Uint8List.fromList([1, 2, 3]);
        },
      );

      final bare = await cache.getArtwork(raw);
      final fromUri = await cache.getArtwork(Uri.file(raw).toString());

      expect(reads, 1);
      expect(fromUri, same(bare));
    });

    test('content:// 入参：dart:io 读不了，直接 null 且不调用 reader', () async {
      // 该 URI 由原生链解码，Dart 侧保持「无内嵌封面」语义（不抛错、不占缓存位）。
      var reads = 0;
      final cache = LocalArtworkCache.forTesting(
        reader: (_) async {
          reads++;
          return Uint8List.fromList([1]);
        },
      );

      expect(
        await cache.getArtwork('content://media/external/audio/albumart/1'),
        isNull,
      );
      expect(reads, 0);
    });

    test('空串 / file:// 无路径：null 且不调用 reader', () async {
      var reads = 0;
      final cache = LocalArtworkCache.forTesting(
        reader: (_) async {
          reads++;
          return Uint8List.fromList([1]);
        },
      );

      expect(await cache.getArtwork(''), isNull);
      expect(await cache.getArtwork('file://'), isNull);
      expect(reads, 0);
    });
  });
}
