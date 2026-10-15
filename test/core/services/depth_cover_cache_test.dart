import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/depth_cover_cache.dart';

void main() {
  late Directory tmpDir;
  setUp(() async => tmpDir = await Directory.systemTemp.createTemp('depth_cache_test'));
  tearDown(() async => tmpDir.delete(recursive: true));

  test('cacheKey 对相同 uri 稳定、对不同 uri 不同', () {
    expect(DepthCoverCache.cacheKey('https://a/1.jpg'),
        DepthCoverCache.cacheKey('https://a/1.jpg'));
    expect(DepthCoverCache.cacheKey('https://a/1.jpg'),
        isNot(DepthCoverCache.cacheKey('https://a/2.jpg')));
  });

  test('层目录不存在 → getLayers 返回 null 且不抛异常', () async {
    final c = DepthCoverCache(baseDirOverride: tmpDir.path);
    final r = await c.getCachedLayers(DepthCoverCache.cacheKey('https://a/1.jpg'));
    expect(r, isNull);
  });

  test('saveLayers 后 getLayers 返回层路径；LRU 淘汰按上限生效', () async {
    final c = DepthCoverCache(baseDirOverride: tmpDir.path, maxEntries: 2);
    for (final key in ['k1', 'k2', 'k3']) {
      final dir = Directory('${tmpDir.path}/$key')..createSync(recursive: true);
      for (var i = 0; i < 3; i++) {
        File('${dir.path}/layer$i.png').writeAsBytesSync([1]);
      }
      await c.recordLayers(key, [0, 1, 2].map((i) => '${dir.path}/layer$i.png').toList());
    }
    expect(await c.getCachedLayers('k1'), isNull, reason: '超出 maxEntries=2，最旧的 k1 被淘汰');
    expect(await c.getCachedLayers('k3'), isNotNull);
  });

  test('recordDepth 后 getCachedDepth 返回路径、std 与封面源路径；未记录返回 null', () async {
    final c = DepthCoverCache(baseDirOverride: tmpDir.path);
    final key = 'kd1';
    final dir = Directory('${tmpDir.path}/$key')..createSync(recursive: true);
    File('${dir.path}/depth.png').writeAsBytesSync([1]);
    expect(await c.getCachedDepth(key), isNull, reason: '未 record 前不应可见');
    await c.recordDepth(key, '${dir.path}/depth.png', 0.21, '${dir.path}/cover.img');
    final r = await c.getCachedDepth(key);
    expect(r, isNotNull);
    expect(r!['depth'], endsWith('depth.png'));
    expect(r['depthStd'], closeTo(0.21, 1e-6));
    expect(r['cover'], endsWith('cover.img'));
  });

  test('recordDepth 带 bgFill 时拷贝 bg_fill.png 且 getCachedDepth 返回路径；旧条目向后兼容',
      () async {
    final c = DepthCoverCache(baseDirOverride: tmpDir.path);
    // 新条目：recordDepth 显式带 bgFillPath
    final dir = Directory('${tmpDir.path}/kb1')..createSync(recursive: true);
    File('${dir.path}/depth_src.png').writeAsBytesSync([1]);
    File('${dir.path}/bg_src.png').writeAsBytesSync([2]);
    await c.recordDepth('kb1', '${dir.path}/depth_src.png', 0.21,
        '${dir.path}/cover.img', bgFillPath: '${dir.path}/bg_src.png');
    final r1 = await c.getCachedDepth('kb1');
    expect(r1!['bgFill'], endsWith('bg_fill.png'));
    expect(File(r1['bgFill'] as String).existsSync(), isTrue,
        reason: 'bg_fill.png 必须已拷贝进缓存目录');

    // 旧条目：只 record depth（不带 bgFill）→ bgFill 为 null 但条目仍命中
    final dir2 = Directory('${tmpDir.path}/kb2')..createSync(recursive: true);
    File('${dir2.path}/depth.png').writeAsBytesSync([1]);
    await c.recordDepth('kb2', '${dir2.path}/depth.png', 0.30,
        '${dir2.path}/cover.img');
    final r2 = await c.getCachedDepth('kb2');
    expect(r2!['bgFill'], isNull);
    expect(r2['depth'], endsWith('depth.png'));
    expect(r2['cover'], endsWith('cover.img'));

    // inpaint 来源标记：带值入 meta，不带则无键（旧条目兼容）
    expect(r1['inpaint'], isNull, reason: 'kb1 未传 inpaintSource');
    final dir3 = Directory('${tmpDir.path}/kb3')..createSync(recursive: true);
    File('${dir3.path}/depth.png').writeAsBytesSync([1]);
    File('${dir3.path}/bg.png').writeAsBytesSync([3]);
    await c.recordDepth('kb3', '${dir3.path}/depth.png', 0.25,
        '${dir3.path}/cover.img',
        bgFillPath: '${dir3.path}/bg.png', inpaintSource: 'migan');
    final r3 = await c.getCachedDepth('kb3');
    expect(r3!['inpaint'], 'migan');
  });

  test('cacheSizeBytes 统计全部文件；clearCache 清空但保留根目录', () async {
    final c = DepthCoverCache(baseDirOverride: tmpDir.path);
    final dir = Directory('${tmpDir.path}/kz')..createSync(recursive: true);
    File('${dir.path}/a.png').writeAsBytesSync(List.filled(100, 0));
    File('${dir.path}/b.png').writeAsBytesSync(List.filled(200, 0));
    expect(await c.cacheSizeBytes(), 300);

    await c.clearCache();
    expect(await c.cacheSizeBytes(), 0);
    expect(tmpDir.existsSync(), isTrue, reason: '根目录保留，只清子项');
  });
}
