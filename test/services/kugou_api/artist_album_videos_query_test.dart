// 钉住真实回归：getArtistAlbums / getArtistVideos 必须用 query key `id` 传歌手 ID。
// Rust 侧 /artist/albums 与 /artist/videos（kugou_api_server/rust/src/modules/artist.rs）
// 都只读 q["id"] 作为上游 author_id，历史上客户端传 'singerid' 会让上游永远收不到歌手 ID。
// 同时钉住 page/pagesize/sort/tag 的默认值与透传。
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    KugouApiClient.markServerReady();
    client = KugouApiClient();
    await client.clearCookies();
    captured.clear();
    // KugouApiClient 是私有单例，无法注入 mock，按仓内既有手法整体替换
    // dio.httpClientAdapter（见 test/providers/kugou_provider_test.dart），
    // 并在 tearDown 里还原，防污染其他测试。
    originalAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _RecordingAdapter(captured);
    originalBaseUrl = KugouEndpoints.baseUrl;
    client.updateBaseUrl('http://artist-query-fixture.invalid');
  });

  tearDown(() {
    client.dio.httpClientAdapter = originalAdapter;
    client.updateBaseUrl(originalBaseUrl);
    uninstallFakeSecureStorage();
  });

  group('getArtistAlbums query 参数', () {
    test('显式参数：id 而非 singerid，并带 page/pagesize/sort', () async {
      await client.getArtistAlbums(
        '123',
        page: 2,
        pagesize: 30,
        sort: 'new',
      );

      expect(captured, hasLength(1));
      final q = captured.single.queryParameters;
      expect(q['id'], '123');
      expect(q.containsKey('singerid'), isFalse);
      expect(q['page'], 2);
      expect(q['pagesize'], 30);
      expect(q['sort'], 'new');
    });

    test('默认 sort=hot 会写进 query（实现里 sort 非空才加入，默认值应存在）', () async {
      await client.getArtistAlbums('123');

      final q = captured.single.queryParameters;
      expect(q['sort'], 'hot');
      expect(q['page'], 1);
      expect(q['pagesize'], 30);
      expect(q['id'], '123');
      expect(q.containsKey('singerid'), isFalse);
    });
  });

  group('getArtistVideos query 参数', () {
    test('显式参数：id 而非 singerid，并带 page/pagesize/tag', () async {
      await client.getArtistVideos(
        '456',
        page: 3,
        pagesize: 20,
        tag: 'live',
      );

      expect(captured, hasLength(1));
      final q = captured.single.queryParameters;
      expect(q['id'], '456');
      expect(q.containsKey('singerid'), isFalse);
      expect(q['page'], 3);
      expect(q['pagesize'], 20);
      expect(q['tag'], 'live');
    });

    test('默认 tag=all 始终随 query 下发', () async {
      await client.getArtistVideos('456');

      final q = captured.single.queryParameters;
      expect(q['tag'], 'all');
      expect(q['page'], 1);
      expect(q['pagesize'], 30);
    });
  });

  test('两个请求分别命中 /artist/albums 与 /artist/videos 路径', () async {
    await client.getArtistAlbums('1');
    await client.getArtistVideos('1');

    expect(captured, hasLength(2));
    expect(captured[0].path, KugouEndpoints.artistAlbums);
    expect(captured[1].path, KugouEndpoints.artistVideos);
  });
}

/// 记录型假适配器：把每次 fetch 的 RequestOptions 存进列表，
/// 返回对 KugouArtistAlbums / KugouArtistVideos 双口径都可解析的最小合法 JSON。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.captured);

  final List<RequestOptions> captured;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'data': {'list': []},
        'total': 0,
        'status': 1,
        'err_code': 0,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
