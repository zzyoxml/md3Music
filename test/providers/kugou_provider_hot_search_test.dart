import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/fake_secure_storage.dart';

/// 只回 /search/hot 的替身：计数 + 可控成败。
class _HotSearchAdapter implements HttpClientAdapter {
  int hotRequests = 0;
  bool shouldFail = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.contains('/search/hot')) {
      hotRequests++;
      if (shouldFail) {
        return ResponseBody.fromString(
          '{"status":0,"msg":"transport_error"}',
          502,
          headers: {Headers.contentTypeHeader: ['application/json']},
        );
      }
      return ResponseBody.fromString(
        '{"status":1,"data":{"list":['
        '{"name":"热搜榜","keywords":[{"keyword":"茶汤"},{"keyword":"雨爱"}]},'
        '{"name":"飙升榜","keywords":[{"keyword":"寻屿"}]}]}}',
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HotSearchAdapter adapter;
  late HttpClientAdapter previousAdapter;
  late KugouProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    adapter = _HotSearchAdapter();
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
    provider = KugouProvider();
  });

  tearDown(() {
    provider.dispose();
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    uninstallFakeSecureStorage();
  });

  group('KugouProvider.loadHotSearch', () {
    test('成功后 notifier 变 ready 并带出榜单词', () async {
      await provider.loadHotSearch();

      expect(provider.hotSearchState.value.status, HotSearchStatus.ready);
      expect(provider.hotSearchState.value.boards.first.keywords, ['茶汤', '雨爱']);
      expect(provider.hotSearchState.value.error, isNull);
    });

    test('非 idle 后重复调用不再发请求（进页只拉一次）', () async {
      await provider.loadHotSearch();
      await provider.loadHotSearch();

      expect(adapter.hotRequests, 1);
    });

    test('失败态将错误留在 notifier，不污染全局 error 与 isLoading', () async {
      adapter.shouldFail = true;
      await provider.loadHotSearch();

      expect(provider.hotSearchState.value.status, HotSearchStatus.failed);
      expect(provider.hotSearchState.value.error, isNotNull);
      // 关键回归：热搜失败绝不能把搜索结果区打成「搜索失败」
      expect(provider.error, isNull);
      expect(provider.isLoading, isFalse);
    });

    test('forceRefresh 重试会真的再打一次接口', () async {
      await provider.loadHotSearch();
      await provider.loadHotSearch(forceRefresh: true);

      expect(adapter.hotRequests, 2);
      expect(provider.hotSearchState.value.status, HotSearchStatus.ready);
    });
  });
}
