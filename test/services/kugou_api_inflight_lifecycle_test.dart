import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/local_server_lifecycle.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('服务停止不重放已越过拦截器的请求，Dio返回原请求结果', () async {
    SharedPreferences.setMockInitialValues({});
    final originalBaseUrl = KugouEndpoints.baseUrl;
    final client = KugouApiClient();
    final adapter = _DelayedResponseAdapter();
    final starting = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(starting);
    client.updateBaseUrl('http://inflight.invalid');
    client.dio.httpClientAdapter = adapter;

    try {
      await client.clearCookies();
      final request = client.dio.get<Map<String, dynamic>>('/fixture');
      await adapter.requestStarted.future.timeout(const Duration(seconds: 3));

      final stopping = KugouApiClient.markServerStopping();
      KugouApiClient.markServerStopped(stopping);
      adapter.complete({'ok': true});

      final response = await request;
      expect(response.data, {'ok': true});
      expect(adapter.requestCount, 1);
      expect(KugouApiClient.localServerState, LocalServerState.stopped);
    } finally {
      adapter.close(force: true);
      client.dio.close(force: true);
      client.updateBaseUrl(originalBaseUrl);
      final stopping = KugouApiClient.markServerStopping();
      KugouApiClient.markServerStopped(stopping);
    }
  });
}

class _DelayedResponseAdapter implements HttpClientAdapter {
  final requestStarted = Completer<void>();
  final _response = Completer<ResponseBody>();
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestCount++;
    if (!requestStarted.isCompleted) requestStarted.complete();
    return _response.future;
  }

  void complete(Map<String, Object> body) {
    _response.complete(
      ResponseBody.fromBytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {
    if (!_response.isCompleted) {
      _response.completeError(StateError('adapter closed before response'));
    }
  }
}
