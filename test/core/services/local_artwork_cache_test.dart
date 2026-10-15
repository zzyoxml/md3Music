import 'dart:async';
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
}
