import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/providers/blacklist_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _BlacklistApiAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _BlacklistApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
  });

  tearDown(() {
    uninstallFakeSecureStorage();
  });

  group('列表拉取与解析', () {
    test('第一页解析 song_k/song_v（n/m/t），键集合与 total 就位', () async {
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      await provider.load('song');

      expect(adapter.listQueries, hasLength(1));
      expect(adapter.listQueries.first['label'], 'song');
      expect(adapter.listQueries.first['page'], '1');
      expect(adapter.listQueries.first['pagesize'], '30');

      final entries = provider.entries('song');
      expect(entries, hasLength(2));
      expect(entries[0].key, 'hash-a');
      expect(entries[0].name, 'N - hash-a');
      expect(entries[0].mixSongId, '${'hash-a'.hashCode}');
      expect(entries[0].label, 'song');
      // 时间取 value 内 t
      expect(entries[0].createdAtSec, 1700000000);
      expect(provider.totalOf('song'), 2);
      expect(provider.isLoaded('song'), isTrue);
      // total(2) <= page*pagesize(30) → 已拉满
      expect(provider.isFullyLoaded('song'), isTrue);
      expect(provider.hasMore('song'), isFalse);
      // createdAtText 用本地时区日期（与登录设备测试同款防时区写法）
      final localDate = DateTime.fromMillisecondsSinceEpoch(
        1700000000 * 1000,
      );
      expect(
        entries[0].createdAtText,
        '${localDate.year}-${localDate.month.toString().padLeft(2, '0')}-'
        '${localDate.day.toString().padLeft(2, '0')}',
      );
    });

    test('statusFor：present / absent（拉满后）/ unknown（未拉满）', () async {
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      // 未加载时既非 present 也非 absent
      expect(provider.statusFor('song', 'hash-a'), BlacklistStatus.unknown);

      await provider.load('song');

      expect(provider.statusFor('song', 'hash-a'), BlacklistStatus.present);
      expect(provider.statusFor('song', 'hash-x'), BlacklistStatus.absent);
      // 桶之间互不干扰：singer 未加载
      expect(provider.statusFor('singer', '3520'), BlacklistStatus.unknown);
    });

    test('多页时 loadMore 追加，hasMore 与 fullyLoaded 翻转', () async {
      adapter.listResponse = _pageResponse(
        label: 'song',
        page: 1,
        pagesize: 30,
        total: 35,
        keys: [for (var i = 0; i < 30; i++) 'hash-$i'],
      );
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      await provider.load('song');
      expect(provider.entries('song'), hasLength(30));
      expect(provider.hasMore('song'), isTrue);
      expect(provider.statusFor('song', 'hash-31'), BlacklistStatus.unknown);

      adapter.listResponse = _pageResponse(
        label: 'song',
        page: 2,
        pagesize: 30,
        total: 35,
        keys: ['hash-30', 'hash-31', 'hash-32', 'hash-33', 'hash-34'],
      );
      await provider.loadMore('song');

      expect(adapter.listQueries, hasLength(2));
      expect(adapter.listQueries.last['page'], '2');
      expect(provider.entries('song'), hasLength(35));
      expect(provider.hasMore('song'), isFalse);
      expect(provider.isFullyLoaded('song'), isTrue);
      expect(provider.statusFor('song', 'hash-31'), BlacklistStatus.present);
    });

    test('ensureFullyLoaded 按大页循环拉满并去重', () async {
      adapter.listResponseBuilder = (options) {
        final page =
            int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
        if (page <= 1) {
          return _pageResponse(
            label: 'song',
            page: 1,
            pagesize: 500,
            total: 600,
            keys: [for (var i = 0; i < 500; i++) 'hash-$i'],
          );
        }
        return _pageResponse(
          label: 'song',
          page: 2,
          pagesize: 500,
          total: 600,
          keys: [for (var i = 500; i < 600; i++) 'hash-$i'],
        );
      };
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      await provider.ensureFullyLoaded('song');

      // total=600 → 500/页 两页（页大小用 500，服务端上限）
      expect(adapter.listQueries, hasLength(2));
      expect(adapter.listQueries.first['pagesize'], '500');
      expect(adapter.listQueries.last['page'], '2');
      expect(adapter.listQueries.last['pagesize'], '500');
      expect(provider.entries('song'), hasLength(600));
      expect(provider.isFullyLoaded('song'), isTrue);
    });

    test('业务失败（token 失效）置 error 且不置 loaded', () async {
      adapter.listResponse = const {
        'status': 0,
        'error_code': 20010,
        'msg': '请先登录',
      };
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      await provider.load('song');

      expect(provider.isLoaded('song'), isFalse);
      expect(provider.errorOf('song'), isNotNull);
      expect(provider.entries('song'), isEmpty);
    });

    test('缓存复用：已加载后 load 不再请求，force 才重拉', () async {
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      await provider.load('song');
      await provider.load('song');
      expect(adapter.listQueries, hasLength(1));

      await provider.load('song', force: true);
      expect(adapter.listQueries, hasLength(2));
    });
  });

  group('编辑', () {
    test('addSong：小写 hash 入参请求 + 条目补录入桶 + 状态翻转', () async {
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      final ok = await provider.addSong(
        hash: 'ABCDEF0123',
        name: 'A - Song',
        mixSongId: '32100650',
      );

      expect(ok, isTrue);
      expect(adapter.editQueries, hasLength(1));
      expect(adapter.editQueries.first['hash'], 'abcdef0123');
      expect(adapter.editQueries.first['mixsongid'], '32100650');
      expect(adapter.editQueries.first['name'], 'A - Song');
      expect(adapter.editQueries.first.containsKey('isDelete'), isFalse);
      expect(adapter.editQueries.first['label'], 'song');

      expect(provider.entries('song'), hasLength(1));
      expect(provider.entries('song').first.key, 'abcdef0123');
      expect(provider.statusFor('song', 'abcdef0123'), BlacklistStatus.present);
    });

    test('addSinger：singerid 请求 + singer 桶就位', () async {
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      final ok = await provider.addSinger(singerId: '3520', name: '周杰伦');

      expect(ok, isTrue);
      expect(adapter.editQueries.first['label'], 'singer');
      expect(adapter.editQueries.first['singerid'], '3520');
      expect(provider.statusFor('singer', '3520'), BlacklistStatus.present);
    });

    test('addSong 业务失败返回 false 且不入桶', () async {
      adapter.editResponse = const {'status': 0, 'error_code': 1};
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      final ok = await provider.addSong(hash: 'abc');

      expect(ok, isFalse);
      expect(provider.entries('song'), isEmpty);
      expect(provider.statusFor('song', 'abc'), BlacklistStatus.unknown);
    });

    test('remove：带 isDelete=1 请求，成功后本地移除并 force 重拉对齐', () async {
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);
      await provider.load('song');
      expect(provider.entries('song'), hasLength(2));

      // 移除成功后服务端只剩 hash-b（force 重拉返回新列表）
      adapter.editResponse = const {'status': 1, 'error_code': 0, 'data': '操作成功'};
      adapter.listResponse = _pageResponse(
        label: 'song',
        page: 1,
        pagesize: 30,
        total: 1,
        keys: ['hash-b'],
      );

      final ok = await provider.remove(provider.entries('song').first);

      expect(ok, isTrue);
      expect(adapter.editQueries, hasLength(1));
      expect(adapter.editQueries.first['hash'], 'hash-a');
      expect(adapter.editQueries.first['isDelete'], '1');
      expect(adapter.editQueries.first['name'], 'N - hash-a');
      expect(
        adapter.editQueries.first['mixsongid'],
        '${'hash-a'.hashCode}',
      );
      // force 重拉已对齐
      expect(provider.entries('song').map((e) => e.key), ['hash-b']);
      expect(provider.totalOf('song'), 1);
    });
  });

  group('登录态联动', () {
    test('syncLoginState：登录态/账号翻转时清空缓存，同态保持', () async {
      final provider = BlacklistProvider();
      addTearDown(provider.dispose);

      await provider.load('song');
      expect(provider.entries('song'), hasLength(2));

      // 同态（未登录→未登录，userid 均为 null）不重置
      provider.syncLoginState(loggedIn: false, userid: null);
      expect(provider.entries('song'), hasLength(2));

      // 登录翻转 → 重置
      provider.syncLoginState(loggedIn: true, userid: '10086');
      expect(provider.entries('song'), isEmpty);
      expect(provider.isLoaded('song'), isFalse);

      // 换号（userid 变化）→ 重置
      await provider.load('song');
      provider.syncLoginState(loggedIn: true, userid: '20001');
      expect(provider.isLoaded('song'), isFalse);
    });
  });
}

Map<String, dynamic> _pageResponse({
  required String label,
  required int page,
  required int pagesize,
  required int total,
  required List<String> keys,
}) {
  final isSong = label != 'singer';
  return {
    'status': 1,
    'error_code': 0,
    'data': {
      'label': label,
      'source': isSong ? 3 : 4,
      'page': page,
      'pagesize': pagesize,
      'total': total,
      'items': [
        for (final key in keys)
          isSong
              ? {
                  'song_k': key,
                  'song_v':
                      '{"n":"N - $key","m":"${key.hashCode}","t":"1700000000"}',
                  't': 1700000000,
                }
              : {
                  'singer_k': key,
                  'singer_v': '{"n":"歌手$key","t":"1700000000"}',
                  't': 1700000000,
                },
      ],
    },
  };
}

class _BlacklistApiAdapter implements HttpClientAdapter {
  /// /blacklist/list 响应体（测试可改写）
  Map<String, dynamic> listResponse = _pageResponse(
    label: 'song',
    page: 1,
    pagesize: 30,
    total: 2,
    keys: ['hash-a', 'hash-b'],
  );

  /// 按请求动态构建响应（多页场景用；设置后优先生效）
  Map<String, dynamic> Function(RequestOptions options)? listResponseBuilder;

  /// /blacklist 编辑响应体
  Map<String, dynamic> editResponse = const {
    'status': 1,
    'error_code': 0,
    'data': '操作成功',
  };

  final List<Map<String, String>> listQueries = [];
  final List<Map<String, String>> editQueries = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/blacklist/list') {
      listQueries.add(
        options.uri.queryParameters.map((k, v) => MapEntry(k, v)),
      );
      final builder = listResponseBuilder;
      if (builder != null) {
        return _json(builder(options));
      }
      return _json(listResponse);
    }
    if (path == '/blacklist') {
      editQueries.add(
        options.uri.queryParameters.map((k, v) => MapEntry(k, v)),
      );
      return _json(editResponse);
    }
    return _json(const {});
  }

  ResponseBody _json(Map<String, dynamic> obj) => ResponseBody.fromString(
        jsonEncode(obj),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
