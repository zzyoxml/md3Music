// test/modules/player/artist_photo_controller_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/am_artist_photo_cover.dart';
import 'package:md3music/modules/player/artist_photo_service.dart';

/// 按 hash 返回不同写真集的假服务（KugouEndpoints.baseUrl 有默认值，
/// 注入 fetcher 即可完全脱离网络——与 09d705d 的既有测试手法一致）。
ArtistPhotoService _service(Map<String, List<String>> byHash) =>
    ArtistPhotoService(
      fetcher: (uri) async {
        final urls = byHash[uri.queryParameters['hash']] ?? const <String>[];
        if (urls.isEmpty) return '{"status":1,"data":[]}';
        return '{"status":1,"data":[[{"imgs":{"320":['
            '${urls.map((u) => '{"sizable_portrait":"$u"}').join(',')}'
            ']}}]]}';
      },
    );

void main() {
  test('加载有图 → hasImages=true、currentUrl=首图、恰好通知一次', () async {
    final c = ArtistPhotoController(
      service: _service({
        'h1': ['https://p/a.jpg', 'https://p/b.jpg'],
      }),
    );
    addTearDown(c.dispose);
    var n = 0;
    c.addListener(() => n++);
    await c.setHash('h1', intervalSeconds: 60);
    expect(c.hasImages, isTrue);
    expect(c.currentUrl.value, 'https://p/a.jpg');
    expect(n, 1); // 清空阶段不通知（false→false），落地翻转才通知
  });

  test('无图歌曲 → hasImages=false、currentUrl=null、不通知', () async {
    final c = ArtistPhotoController(service: _service({}));
    addTearDown(c.dispose);
    var n = 0;
    c.addListener(() => n++);
    // hash 唯一：'h1' 已被上面用例写进 static 缓存，复用会同步命中出图
    await c.setHash('h-noimages', intervalSeconds: 60);
    expect(c.hasImages, isFalse);
    expect(c.currentUrl.value, isNull);
    expect(n, 0);
  });

  test('切歌：有图 → 无图，先清空并通知回 false', () async {
    final c = ArtistPhotoController(
      service: _service({
        'h1': ['https://p/a.jpg'],
        'h2': const <String>[],
      }),
    );
    addTearDown(c.dispose);
    await c.setHash('h1', intervalSeconds: 60);
    var n = 0;
    c.addListener(() => n++);
    await c.setHash('h2', intervalSeconds: 60);
    expect(c.hasImages, isFalse);
    expect(c.currentUrl.value, isNull);
    expect(n, 1);
  });

  test('轮播 tick 只更新 currentUrl，不 notifyListeners', () async {
    final c = ArtistPhotoController(
      service: _service({
        'h1': ['https://p/a.jpg', 'https://p/b.jpg'],
      }),
    );
    addTearDown(c.dispose);
    await c.setHash('h1', intervalSeconds: 1);
    var n = 0;
    c.addListener(() => n++);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(c.currentUrl.value, 'https://p/b.jpg');
    expect(n, 0);
  });

  test('dispose 停掉轮播 Timer（AGENTS.md 第 10 节：驱动必须能停）', () async {
    final c = ArtistPhotoController(
      service: _service({
        'h1': ['https://p/a.jpg', 'https://p/b.jpg'],
      }),
    );
    await c.setHash('h1', intervalSeconds: 1);
    c.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    // dispose 后 Timer 已停：值停留在首图（若停不掉会被翻到 b，且访问已 dispose
    // 的 ValueNotifier 会抛异常 → 用例失败）
    expect(c.currentUrl.value, 'https://p/a.jpg');
  });

  test('切歌竞态：旧 hash 的迟到响应被丢弃', () async {
    final h1 = Completer<String>();
    final h2 = Completer<String>();
    final c = ArtistPhotoController(
      service: ArtistPhotoService(
        fetcher: (uri) =>
            uri.queryParameters['hash'] == 'h1' ? h1.future : h2.future,
      ),
    );
    addTearDown(c.dispose);
    unawaited(c.setHash('h1', intervalSeconds: 60));
    unawaited(c.setHash('h2', intervalSeconds: 60));
    h2.complete(
      '{"status":1,"data":[[{"imgs":{"320":'
      '[{"sizable_portrait":"https://p/h2.jpg"}]}}]]}',
    );
    h1.complete(
      '{"status":1,"data":[[{"imgs":{"320":'
      '[{"sizable_portrait":"https://p/h1.jpg"}]}}]]}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.currentUrl.value, 'https://p/h2.jpg');
  });

  // 注意：缓存是 static，跨用例共享——hash 必须每个用例唯一（h1 已被前面用例用过）。
  test('静态缓存：新实例同 hash 同步命中，不再请求网络', () async {
    var fetches = 0;
    final service = ArtistPhotoService(fetcher: (uri) async {
      fetches++;
      return '{"status":1,"data":[[{"imgs":{"320":'
          '[{"sizable_portrait":"https://p/cached.jpg"}]}}]]}';
    });
    final first = ArtistPhotoController(service: service);
    addTearDown(first.dispose);
    await first.setHash('cache-hit', intervalSeconds: 60);
    expect(first.hasImages, isTrue);
    expect(fetches, 1);

    // 模拟拖拽覆盖层的第二个实例：setHash 完成即同步出图，fetcher 不再被调
    final second = ArtistPhotoController(service: service);
    addTearDown(second.dispose);
    final done = second.setHash('cache-hit', intervalSeconds: 60);
    expect(second.currentUrl.value, 'https://p/cached.jpg');
    expect(second.hasImages, isTrue);
    await done;
    expect(fetches, 1);
  });

  test('静态缓存：空结果不进缓存（无图歌曲仍会重试）', () async {
    var fetches = 0;
    final service = ArtistPhotoService(fetcher: (_) async {
      fetches++;
      return '{"status":1,"data":[]}';
    });
    final a = ArtistPhotoController(service: service);
    final b = ArtistPhotoController(service: service);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.setHash('cache-miss', intervalSeconds: 60);
    await b.setHash('cache-miss', intervalSeconds: 60);
    expect(fetches, 2);
  });

  test('setInterval：按新间隔重起轮播，不重拉图、不通知', () async {
    final c = ArtistPhotoController(
      service: _service({
        'h-interval': ['https://p/a.jpg', 'https://p/b.jpg'],
      }),
    );
    addTearDown(c.dispose);
    // 先按 60 秒起：1.2 秒内不翻页
    await c.setHash('h-interval', intervalSeconds: 60);
    expect(c.currentUrl.value, 'https://p/a.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(c.currentUrl.value, 'https://p/a.jpg');

    // 播放中改设置页「轮播间隔」→ 重起定时器后 1.2 秒内应已翻页
    var n = 0;
    c.addListener(() => n++);
    c.setInterval(1);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(c.currentUrl.value, 'https://p/b.jpg');
    expect(n, 0);
  });

  test('setInterval：无图 / 单图时无事可做（不抛、不翻页）', () async {
    final c = ArtistPhotoController(
      service: _service({
        'h-interval-one': ['https://p/only.jpg'],
      }),
    );
    addTearDown(c.dispose);
    await c.setHash('h-interval-one', intervalSeconds: 60);
    c.setInterval(1);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(c.currentUrl.value, 'https://p/only.jpg');
  });

  test('seedFromCache：首帧空态同步填充，不通知、不改 hash', () async {
    final service = _service({
      'seed-h': ['https://p/a.jpg', 'https://p/b.jpg'],
    });
    final warmer = ArtistPhotoController(service: service);
    addTearDown(warmer.dispose);
    await warmer.setHash('seed-h', intervalSeconds: 60); // 填缓存

    final fresh = ArtistPhotoController(service: service);
    addTearDown(fresh.dispose);
    var n = 0;
    fresh.addListener(() => n++);
    fresh.seedFromCache('seed-h');
    expect(fresh.hasImages, isTrue);
    expect(fresh.currentUrl.value, 'https://p/a.jpg');
    expect(fresh.hash, isEmpty); // 不改 _hash：post-frame setHash 照常走完并起轮播
    expect(n, 0); // 不通知
    // 已有图时再 seed（切歌路径）不覆盖、不抛
    fresh.seedFromCache('other-h');
    expect(fresh.currentUrl.value, 'https://p/a.jpg');
  });
}
