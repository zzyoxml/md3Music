// KugouProvider 新歌速递（/top/song）的状态契约。
//
// 钉住六条容易在重构中被悄悄改掉的行为：
//   ① 首屏取满一页（30 首）并把 pagesize 原样下发
//   ② **空榜不盖 TTL**——请求成功但榜面为空时，下次进页必须仍然重试
//      （若实现顺手写了 `_dataTimestamps['newSong']`，第二次调用会被 5 分钟 TTL 跳过，
//       发现页就会连续 5 分钟只显示一个空区块；这条只能靠"数请求次数"来防）
//   ③ 取到非空榜才盖 TTL：TTL 内重复调用不打网络，`forceRefresh` 才打
//   ④ `fetchMoreNewSongs` 只返回真正新并入的那批；短页即榜单到底
//   ⑤ 跨页按 hash 去重，但**空 hash 保留**（与刷歌 ingest 路径的有意分歧）
//   ⑥ `clearMemoryCache()` 把整组状态回到「未取过」
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/fake_secure_storage.dart';

/// 一页的哈希列表：正好填满 `newSongPageSize`（30 首），hasMore 保持 true。
List<String> fullPage(int page) => List<String>.generate(
  KugouProvider.newSongPageSize,
  (i) => 'P${page}_S${i + 1}',
);

/// 只回 /top/song 的替身：按 query 里的 `page` 返回不同榜面，其余路径 404。
class _TopSongAdapter implements HttpClientAdapter {
  /// page → 该页的歌曲 hash 列表；未配置的页返回空榜（`data: []`）。
  /// 列表里出现空串即「上游没给 hash 字段」的新歌，用于钉住 ⑤。
  final Map<int, List<String>> pages = <int, List<String>>{};

  int topSongRequests = 0;
  final List<int> requestedPages = <int>[];
  final List<int> requestedPageSizes = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.uri.path.contains('/top/song')) {
      return ResponseBody.fromString('{}', 404);
    }
    topSongRequests++;
    final page = int.parse(options.queryParameters['page'].toString());
    requestedPages.add(page);
    requestedPageSizes.add(
      int.parse(options.queryParameters['pagesize'].toString()),
    );

    // EchoMusic 实测形态：data 本身就是歌曲数组。
    final data = <Map<String, dynamic>>[
      for (final hash in pages[page] ?? const <String>[])
        <String, dynamic>{
          'hash': hash,
          'songname': '新歌 $hash',
          'singername': '歌手 $hash',
          'time_length': 180,
        },
    ];
    return ResponseBody.fromString(
      jsonEncode({'status': 1, 'error_code': 0, 'data': data}),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TopSongAdapter adapter;
  late HttpClientAdapter previousAdapter;
  late KugouProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    adapter = _TopSongAdapter();
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
    provider = KugouProvider();
  });

  tearDown(() {
    provider.dispose();
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    uninstallFakeSecureStorage();
  });

  group('KugouProvider.getNewSongs 首屏', () {
    test('① 取满一页 30 首，hasMore 为真，pagesize=30 随请求下发', () async {
      adapter.pages[1] = fullPage(1);

      await provider.getNewSongs();

      expect(adapter.topSongRequests, 1);
      expect(adapter.requestedPages, [1]);
      expect(adapter.requestedPageSizes, [30]);
      expect(KugouProvider.newSongPageSize, 30);
      expect(provider.newSongs, hasLength(30));
      expect(provider.newSongs.first.hash, 'P1_S1');
      // 榜单到底没有显式标记，只能靠"这一页够不够满"推断。
      expect(provider.newSongHasMore, isTrue);
    });

    test('② 空榜不盖 TTL：第二次非强制调用仍然真的再打一次接口', () async {
      // pages 不配 → 替身回 {"status":1,"data":[]}，即"请求成功、榜面为空"。
      await provider.getNewSongs();

      expect(adapter.topSongRequests, 1);
      expect(provider.newSongs, isEmpty);
      expect(provider.newSongHasMore, isFalse);

      // 本用例的要点：空结果不许写时间戳，否则这次调用会被 TTL 直接跳过。
      await provider.getNewSongs();
      expect(adapter.topSongRequests, 2, reason: '空榜不该享受 TTL');
    });

    test('③ 取到非空榜才盖 TTL：TTL 内重复调用不打网络，forceRefresh 才打', () async {
      adapter.pages[1] = fullPage(1);

      await provider.getNewSongs();
      expect(adapter.topSongRequests, 1);

      await provider.getNewSongs();
      expect(adapter.topSongRequests, 1, reason: '5 分钟 TTL 内应直接复用');
      expect(provider.newSongs, hasLength(30));

      await provider.getNewSongs(forceRefresh: true);
      expect(adapter.topSongRequests, 2);
      // 强制刷新要把列表重建回第 1 页，不能把上一批再并一遍。
      expect(provider.newSongs, hasLength(30));
    });
  });

  group('KugouProvider.fetchMoreNewSongs 翻页', () {
    test('④ 追加第 2 页并只返回新增；短页即到底，到底后不再打网络', () async {
      adapter.pages[1] = fullPage(1);
      adapter.pages[2] = <String>['P2_S1', 'P2_S2', 'P2_S3'];

      await provider.getNewSongs();

      final fresh = await provider.fetchMoreNewSongs();

      // 返回值只含新并入的那批（契约同 fetchMoreHomeDiscover）。
      expect(fresh.map((s) => s.hash), ['P2_S1', 'P2_S2', 'P2_S3']);
      expect(provider.newSongs, hasLength(33));
      expect(provider.newSongs.last.hash, 'P2_S3');
      expect(adapter.requestedPages, [1, 2]);
      expect(adapter.requestedPageSizes, [30, 30]);

      // 第 2 页 3 条 < 30 → 判定榜单到底。
      expect(provider.newSongHasMore, isFalse);

      final hitsBefore = adapter.topSongRequests;
      expect(await provider.fetchMoreNewSongs(), isEmpty);
      expect(adapter.topSongRequests, hitsBefore, reason: '到底后不该再打接口');
      expect(provider.newSongs, hasLength(33));
    });

    test('⑤ 跨页按 hash 去重；空 hash 的新歌保留（与刷歌 ingest 有意不同）', () async {
      adapter.pages[1] = fullPage(1);
      adapter.pages[2] = <String>[
        'P1_S1', // 与第 1 页重复 → 必须被 seen 挡掉
        '', // 上游没给 hash → 保留（照抄刷歌的"空 hash 即丢弃"会整批变空）
        'P2_FRESH',
      ];

      await provider.getNewSongs();
      final fresh = await provider.fetchMoreNewSongs();

      expect(fresh.map((s) => s.hash), ['', 'P2_FRESH']);
      expect(provider.newSongs, hasLength(32));
      expect(
        provider.newSongs.where((s) => s.hash == 'P1_S1'),
        hasLength(1),
        reason: '跨页重复的 hash 不能出现两次',
      );
      expect(
        provider.newSongs.where((s) => s.hash.isEmpty),
        hasLength(1),
        reason: '空 hash 只是不进 seen，绝不能被丢弃',
      );
    });
  });

  group('KugouProvider.clearMemoryCache 对新歌速递的影响', () {
    test('⑥ 清缓存把列表/页码/seen/TTL 一起归零，下次进页重新请求', () async {
      adapter.pages[1] = fullPage(1);

      await provider.getNewSongs();
      expect(provider.newSongs, hasLength(30));

      provider.clearMemoryCache();
      expect(provider.newSongs, isEmpty);
      // 回到「未取过」：hasMore 复位，否则清完缓存后翻页永远回不来。
      expect(provider.newSongHasMore, isTrue);

      await provider.getNewSongs();
      expect(adapter.topSongRequests, 2, reason: 'TTL 时间戳已随缓存清除');
      // seen 也必须一起清掉，否则重取的第 1 页会被去重成空列表。
      expect(provider.newSongs, hasLength(30));
    });
  });
}
