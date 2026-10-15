// 钉住 getTopSong 的 query 参数契约。
//
// 为什么必须钉：Rust 侧 `/top/song`（kugou_api_server/rust/src/modules/top.rs:182-195）
// 只读这三个 query key —— `type` → 上游 `rank_id`（默认 21608 = 新歌速递）、
// `page`（默认 1）、`pagesize`（默认 30）。历史上 Dart 桩只发 `page`，
// 于是 rank_id 永远是默认值、翻页也翻不动；参数名一旦写错，服务端会静默回退默认值，
// 客户端看不出异常，只能从 query 层面锁死。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late HttpClientAdapter originalAdapter;
  late String originalBaseUrl;
  final captured = <RequestOptions>[];
  late _TopSongQueryAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    KugouApiClient.markServerReady();
    client = KugouApiClient();
    await client.clearCookies();
    captured.clear();
    // KugouApiClient 是私有单例，无法注入 mock，按仓内既有手法整体替换
    // dio.httpClientAdapter（见 test/services/kugou_api/artist_album_videos_query_test.dart），
    // 并在 tearDown 里还原，防污染其他测试。
    originalAdapter = client.dio.httpClientAdapter;
    adapter = _TopSongQueryAdapter(captured);
    client.dio.httpClientAdapter = adapter;
    originalBaseUrl = KugouEndpoints.baseUrl;
    client.updateBaseUrl('http://top-song-query-fixture.invalid');
  });

  tearDown(() {
    client.dio.httpClientAdapter = originalAdapter;
    client.updateBaseUrl(originalBaseUrl);
    uninstallFakeSecureStorage();
  });

  group('getTopSong query 参数', () {
    test('默认值：page=1 / type=21608 / pagesize=30 三者齐发', () async {
      await client.getTopSong();

      expect(captured, hasLength(1));
      final q = captured.single.queryParameters;
      expect(q['page'], 1);
      expect(q['type'], 21608);
      expect(q['pagesize'], 30);
    });

    test('显式参数逐一原样透传（不做任何换算或裁剪）', () async {
      await client.getTopSong(page: 3, type: 21612, pagesize: 12);

      expect(captured, hasLength(1));
      final q = captured.single.queryParameters;
      expect(q['page'], 3);
      expect(q['type'], 21612);
      expect(q['pagesize'], 12);
    });

    test('命中 /top/song 路径', () async {
      await client.getTopSong();

      expect(captured.single.path, KugouEndpoints.topSong);
      expect(KugouEndpoints.topSong, '/top/song');
    });

    test('成功响应按 {data:[歌…]} 数组形态解析成 KugouSongDetail 列表', () async {
      final songs = await client.getTopSong();

      // 替身回的是 EchoMusic 实测形态（data 即数组），必须解析出 2 首；
      // 返回类型是 List<KugouSongDetail>?，非 null 才说明 _get 走通了 200 分支。
      expect(songs, isNotNull);
      expect(songs, hasLength(2));
      expect(songs!.first.hash, 'HASH_Q_1');
    });

    test('服务端非 2xx → 返回 null（不是空列表），调用方据此区分失败与空榜', () async {
      // 契约要点：`null` = 请求失败、`[]` = 榜面确实为空。
      // KugouProvider.getNewSongs 只有在前者才写 _error，后者才把 hasMore 置 false，
      // 两者混用会把网络故障伪装成「榜单到底了」。
      adapter.statusCode = 502;
      adapter.body = '{"status":0,"error_code":50023,"msg":"upstream_error"}';

      expect(await client.getTopSong(), isNull);
      expect(captured, hasLength(1));
    });

    test('200 但响应体不是 JSON 对象 → 返回 null', () async {
      // `_get` 的 200 分支要求 `response.data is Map<String, dynamic>`；
      // 顶层数组（`[]`）会被解成 List，于是落到 "Non-200 or non-map" 分支返回 null。
      // 用合法 JSON 而不是坏文本，避免依赖 dio 对 FormatException 的处理方式。
      adapter.body = '{"data": []}';
      expect(await client.getTopSong(), isNotNull);

      adapter.body = '[]';
      expect(await client.getTopSong(), isNull);
      expect(captured, hasLength(2));
    });
  });
}

/// 记录型假适配器：存下每次 fetch 的 RequestOptions，默认回「两条歌曲的合法榜面」。
/// statusCode / body 可按用例改写，用来覆盖非 2xx 与非对象响应。
class _TopSongQueryAdapter implements HttpClientAdapter {
  _TopSongQueryAdapter(this.captured);

  final List<RequestOptions> captured;

  int statusCode = 200;
  String contentType = Headers.jsonContentType;

  String body = jsonEncode({
    'status': 1,
    'error_code': 0,
    'data': <Map<String, dynamic>>[
      <String, dynamic>{
        'hash': 'HASH_Q_1',
        'songname': '查询歌曲一',
        'singername': '歌手一',
        'time_length': 180,
      },
      <String, dynamic>{
        'hash': 'HASH_Q_2',
        'songname': '查询歌曲二',
        'singername': '歌手二',
        'time_length': 200,
      },
    ],
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    return ResponseBody.fromString(body, statusCode, headers: {
      Headers.contentTypeHeader: [contentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
