import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_download_cache.dart';

void main() {
  Future<Directory> mkTemp() =>
      Directory.systemTemp.createTemp('remote_cache_test');

  test('ensureDownloaded 首次下载后二次命中同一路径', () async {
    var downloads = 0;
    final cache = RemoteDownloadCache(
      tempDir: await mkTemp(),
      downloader: (remotePath, destFile) async {
        downloads++;
        await destFile.writeAsBytes(List.filled(10, 1));
      },
    );
    addTearDown(cache.dispose);

    final p1 = await cache.ensureDownloaded('cfg1', '/music/a.mp3');
    expect(p1, isNotNull);
    expect(File(p1!).existsSync(), isTrue);
    expect(downloads, 1);

    // 二次请求命中缓存：返回同一路径且不重复下载
    final p2 = await cache.ensureDownloaded('cfg1', '/music/a.mp3');
    expect(p2, p1);
    expect(downloads, 1);
  });

  test('缓存超阈值按最旧清理，之后重新下载', () async {
    var downloads = 0;
    final cache = RemoteDownloadCache(
      tempDir: await mkTemp(),
      maxBytes: 100,
      downloader: (_, dest) async {
        downloads++;
        await dest.writeAsBytes(List.filled(60, 1));
      },
    );
    addTearDown(cache.dispose);

    final a = await cache.ensureDownloaded('cfg1', '/a.mp3');
    expect(a, isNotNull);
    // 保证两次下载的修改时间有先后，LRU 判定确定
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final b = await cache.ensureDownloaded('cfg1', '/b.mp3');
    expect(b, isNotNull);
    expect(downloads, 2);

    // 总量 120 > 100：最旧的 a 被清理
    expect(File(a!).existsSync(), isFalse);

    // 再次请求 a：缓存已失效 → 重新下载
    final a2 = await cache.ensureDownloaded('cfg1', '/a.mp3');
    expect(a2, isNotNull);
    expect(downloads, 3);
    expect(File(a2!).existsSync(), isTrue);
  });
}