import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 5 个新增歌单写端点的**请求形状**测试。
///
/// 这些端点大多走 GET + URL query（除了封面上传走 POST + JSON body），
/// 参数名或取值写错不会报错，只会被上游静默拒绝或写错数据，故逐个固化。
///
/// 同时固化 `noCache: true`：本地 Rust 服务器对 200 响应有 120s apicache，
/// 写操作命中缓存等于「点了没反应」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _RecorderAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _RecorderAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.setLoginCookies('token-abc', '10086');
  });

  tearDown(() {
    uninstallFakeSecureStorage();
  });

  test('sortPlaylists 下发 total_ver / data', () async {
    adapter.response = const {'status': 1};
    await client.sortPlaylists('11|0|0,22|1|0', totalVer: 9);

    final r = adapter.requests.single;
    expect(r.path, '/playlist/sort');
    expect(r.query['total_ver'], 9);
    expect(r.query['data'], '11|0|0,22|1|0');
    expect(r.bypassedCache, isTrue);
  });

  test('setPlaylistCover 下发 total_ver / type / data', () async {
    adapter.response = const {'status': 1};
    await client.setPlaylistCover('11|0|stdmusic/a.jpg', totalVer: 9, type: 0);

    final r = adapter.requests.single;
    expect(r.path, '/playlist/pic');
    expect(r.query['total_ver'], 9);
    expect(r.query['type'], 0);
    expect(r.query['data'], '11|0|stdmusic/a.jpg');
    expect(r.bypassedCache, isTrue);
  });

  test('uploadPlaylistCover 走 POST + JSON body，只传本地文件路径', () async {
    adapter.response = const {'status': 1, 'FileName': '20260914120505590883.jpg'};
    final result = await client.uploadPlaylistCover('/tmp/cover.jpg');

    final r = adapter.requests.single;
    expect(r.path, '/playlist/pic/upload');
    expect(r.method, 'POST');
    expect(r.body, {
      'file': '/tmp/cover.jpg',
      'type': 'custom',
      'extendName': '.jpg',
    });
    // 返回值必须把 FileName 原样带出来（调用方要靠它拼 custom/<FileName>）
    expect(result?['FileName'], '20260914120505590883.jpg');
    expect(r.bypassedCache, isTrue);
  });

  test('updatePlaylistInfo 全字段下发', () async {
    adapter.response = const {'status': 1};
    await client.updatePlaylistInfo(
      listid: '11',
      totalVer: 9,
      type: 0,
      name: '我的新歌单',
      sort: 1,
      tags: '华语,流行',
      intro: '好听',
      pic: 'custom/20260914120505590883.jpg',
    );

    final r = adapter.requests.single;
    expect(r.path, '/playlist/update');
    // 逐个断言业务字段（不断言整张 map：noCache 还会额外注入 t= 时间戳，
    // 那是拦截器行为，见下一个用例）
    expect(r.query['listid'], '11');
    expect(r.query['total_ver'], 9);
    expect(r.query['type'], 0);
    expect(r.query['sort'], 1);
    expect(r.query['tags'], '华语,流行');
    expect(r.query['intro'], '好听');
    expect(r.query['name'], '我的新歌单');
    expect(r.query['pic'], 'custom/20260914120505590883.jpg');
    expect(r.bypassedCache, isTrue);
  });

  test('写接口同时带 t= 时间戳（apicache 命中时可能跳过参数比对）', () async {
    adapter.response = const {'status': 1};
    await client.updatePlaylistInfo(listid: '11', totalVer: 9, name: 'N');

    // _onRequest 的 noCache 分支除 bypass 头外还会补 t=，两者缺一都可能
    // 让写操作命中本地 120s 缓存而「点了没反应」
    expect(adapter.requests.single.query['t'], isA<int>());
  });

  test('updatePlaylistInfo：name / pic 传 null 时不下发该键', () async {
    adapter.response = const {'status': 1};
    await client.updatePlaylistInfo(listid: '11', totalVer: 9);

    final q = adapter.requests.single.query;
    // 空 name 会被上游当成「改名成空」，是不可逆的静默损坏
    expect(q.containsKey('name'), isFalse);
    expect(q.containsKey('pic'), isFalse);
    // tags / intro 相反：恒在，空串即清空
    expect(q['tags'], '');
    expect(q['intro'], '');
    expect(q['sort'], 0);
    expect(q['type'], 0);
  });

  test('updatePlaylistInfo：name / pic 传空串同样不下发', () async {
    adapter.response = const {'status': 1};
    await client.updatePlaylistInfo(
      listid: '11',
      totalVer: 9,
      name: '',
      pic: '',
    );
    final q = adapter.requests.single.query;
    expect(q.containsKey('name'), isFalse);
    expect(q.containsKey('pic'), isFalse);
  });

  test('updatePlaylistInfo：isPri 显式下发，缺省不下发', () async {
    // v4 modify_list 官方恒发 is_pri；缺省时由 Rust 侧决定是否插入，
    // Dart 侧只在调用方明确知道隐私态时才传（编辑页传歌单当前值）。
    adapter.response = const {'status': 1};
    await client.updatePlaylistInfo(listid: '11', totalVer: 9, isPri: true);
    expect(adapter.requests.single.query['is_pri'], 1);

    adapter.requests.clear();
    await client.updatePlaylistInfo(listid: '11', totalVer: 9);
    expect(adapter.requests.single.query.containsKey('is_pri'), isFalse);
  });

  test('updatePlaylistInfo 成功后从响应刷新 total_ver 乐观锁', () async {
    // v4 响应 data.total_ver 是 +1 后的新列表级版本；不刷新的话，
    // 紧接着的第二次编辑会用过期的 version 被上游拒。
    client.lastKnownPlaylistTotalVer = 0;
    adapter.response = const {
      'status': 1,
      'data': {'total_ver': 120, 'pre_total_ver': 119},
    };
    await client.updatePlaylistInfo(listid: '11', totalVer: 119);
    expect(client.lastKnownPlaylistTotalVer, 120);

    // 失败响应不得改动已知版本
    adapter.response = const {'status': 0, 'error_code': 20017};
    await client.updatePlaylistInfo(listid: '11', totalVer: 120);
    expect(client.lastKnownPlaylistTotalVer, 120);
  });

  test('getUserPlaylist 从响应记录 total_ver，供后续写接口当乐观锁', () async {
    // 先清成 0，确认确实是这次调用写进去的
    client.lastKnownPlaylistTotalVer = 0;
    adapter.response = const {
      'status': 1,
      'data': {
        'total_ver': 33,
        'info': [],
      },
    };
    await client.getUserPlaylist();
    expect(client.lastKnownPlaylistTotalVer, 33);

    // 失败响应（无 total_ver）不得把已知版本抹成 0
    adapter.response = const {'status': 0};
    await client.getUserPlaylist();
    expect(client.lastKnownPlaylistTotalVer, 33,
        reason: '失败响应不应清空已知版本号');
  });

  test('新建歌单（隐私）下发 is_pri=1 且绕过缓存', () async {
    adapter.response = const {'status': 1, 'data': {'listid': 77}};
    await client.createPlaylist('隐私歌单', isPri: 1);

    final r = adapter.requests.single;
    expect(r.path, '/playlist/add');
    expect(r.query['is_pri'], 1);
    expect(r.query['name'], '隐私歌单');
    expect(r.bypassedCache, isTrue);
  });
}

/// 捕获到的单个请求。
class _RecordedRequest {
  final String path;
  final String method;
  final Map<String, dynamic> query;
  final Object? body;
  final bool bypassedCache;

  const _RecordedRequest({
    required this.path,
    required this.method,
    required this.query,
    required this.body,
    required this.bypassedCache,
  });
}

/// 假适配器：记录每个请求的 method / path / query / body 与 apicache bypass 头。
class _RecorderAdapter implements HttpClientAdapter {
  final List<_RecordedRequest> requests = [];

  Map<String, dynamic> response = const {'status': 1};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object? body = options.data;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      final raw = [for (final c in chunks) ...c];
      if (raw.isNotEmpty) {
        try {
          body = jsonDecode(utf8.decode(raw));
        } catch (_) {
          body = raw;
        }
      }
    }

    requests.add(
      _RecordedRequest(
        path: options.uri.path,
        method: options.method,
        query: Map<String, dynamic>.from(options.queryParameters),
        body: body,
        // _onRequest 打的是请求级 header（不是 extra），apicache 中间件认这个头
        bypassedCache:
            options.headers['x-apicache-bypass'] == '1',
      ),
    );

    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
