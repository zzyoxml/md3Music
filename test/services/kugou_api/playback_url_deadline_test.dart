import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late String originalBaseUrl;
  late int requests;
  late bool adapterCanceled;
  late Completer<void> requestStarted;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    client = KugouApiClient();
    await client.clearCookies();
    originalBaseUrl = KugouEndpoints.baseUrl;
    client.updateBaseUrl('http://playback-deadline.invalid');
    client.dio.httpClientAdapter = _HangingAdapter(
      onRequest: () {
        requests++;
        if (!requestStarted.isCompleted) requestStarted.complete();
      },
      onCanceled: () => adapterCanceled = true,
    );
  });

  tearDownAll(() async {
    client.updateBaseUrl(originalBaseUrl);
    client.dio.close(force: true);
    final generation = KugouApiClient.markServerStopping();
    KugouApiClient.markServerStopped(generation);
  });

  setUp(() {
    requests = 0;
    adapterCanceled = false;
    requestStarted = Completer<void>();
  });

  test('URL解析总截止取消在途HTTP并阻止剩余回退请求', () async {
    final resultFuture = client.getSongUrlWithFallback(
      'fixture-hash',
      totalTimeout: const Duration(milliseconds: 250),
    );
    await requestStarted.future.timeout(const Duration(seconds: 2));
    final result = await resultFuture;

    expect(result, isNull);
    expect(requests, 1);
    expect(adapterCanceled, isTrue);
  });

  test('上游持续返回503时降级链有限结束且不伪造播放地址', () async {
    client.dio.httpClientAdapter = _StatusAdapter(
      statusCode: 503,
      onRequest: () => requests++,
    );

    final result = await client.getSongUrlWithFallback(
      'fixture-hash',
      quality: '128',
      totalTimeout: const Duration(seconds: 2),
    );

    expect(result, isNull);
    expect(requests, 3);
  });

  test('本地服务过载响应后立即停止音质和试听回退', () async {
    client.dio.httpClientAdapter = _StatusAdapter(
      statusCode: 503,
      body: '{"error":"local_server_busy","retryable":true}',
      onRequest: () => requests++,
    );
    final failures = <PlaybackUrlLocalFailure>[];

    final result = await client.getSongUrlWithFallback(
      'fixture-hash',
      quality: 'high',
      totalTimeout: const Duration(seconds: 2),
      onLocalFailure: failures.add,
    );

    expect(result, isNull);
    expect(requests, 1);
    expect(failures, [PlaybackUrlLocalFailure.serverBusy]);
  });

  test('本地服务无响应时归类为不可用并停止后续回退', () async {
    client.updateBaseUrl('http://127.0.0.1:8080');
    client.dio.httpClientAdapter = _ConnectionErrorAdapter(
      onRequest: () => requests++,
    );
    final failures = <PlaybackUrlLocalFailure>[];

    final result = await client.getSongUrlWithFallback(
      'fixture-hash',
      quality: 'high',
      totalTimeout: const Duration(seconds: 2),
      onLocalFailure: failures.add,
    );

    expect(result, isNull);
    expect(requests, 1);
    expect(failures, [PlaybackUrlLocalFailure.serverUnavailable]);
  });
}

class _HangingAdapter implements HttpClientAdapter {
  _HangingAdapter({required this.onRequest, required this.onCanceled});

  final void Function() onRequest;
  final void Function() onCanceled;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    onRequest();
    final response = Completer<ResponseBody>();
    cancelFuture?.then((_) {
      onCanceled();
      if (!response.isCompleted) {
        response.completeError(
          DioException(requestOptions: options, type: DioExceptionType.cancel),
        );
      }
    });
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter({
    required this.statusCode,
    required this.onRequest,
    this.body = '{}',
  });

  final int statusCode;
  final void Function() onRequest;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onRequest();
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ConnectionErrorAdapter implements HttpClientAdapter {
  _ConnectionErrorAdapter({required this.onRequest});

  final void Function() onRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    onRequest();
    return Future<ResponseBody>.error(
      DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}
