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
    originalAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _AlbumSongsAdapter(captured);
    originalBaseUrl = KugouEndpoints.baseUrl;
    client.updateBaseUrl('http://album-pagination-fixture.invalid');
  });

  tearDown(() {
    client.dio.httpClientAdapter = originalAdapter;
    client.updateBaseUrl(originalBaseUrl);
    uninstallFakeSecureStorage();
  });

  test('专辑歌曲按页加载，覆盖超过 100 首的专辑', () async {
    final result = await client.getAlbumSongsAll('album-125');

    expect(result, isNotNull);
    expect(result!.songs, hasLength(125));
    expect(result.total, 125);
    expect(captured, hasLength(5));
    expect(captured.map((request) => request.queryParameters['page']), [
      1,
      2,
      3,
      4,
      5,
    ]);
    expect(
      captured.every((request) => request.path == KugouEndpoints.albumSongs),
      isTrue,
    );
    expect(
      captured.every(
        (request) => request.queryParameters['album_id'] == 'album-125',
      ),
      isTrue,
    );
  });
}

class _AlbumSongsAdapter implements HttpClientAdapter {
  _AlbumSongsAdapter(this.captured);

  final List<RequestOptions> captured;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    final page = int.parse(options.queryParameters['page'].toString());
    final start = (page - 1) * 30;
    final count = (125 - start).clamp(0, 30);
    return ResponseBody.fromString(
      jsonEncode({
        'data': {
          'total': 125,
          'songs': List.generate(
            count,
            (index) => {
              'hash': 'hash-${start + index}',
              'songname': 'song-${start + index}',
            },
          ),
        },
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
