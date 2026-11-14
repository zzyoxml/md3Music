import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:md3music/services/kugou_api/lyric_lookup_result.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('暂时断网后歌词查询不负缓存，下一次请求可恢复', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();

    final client = KugouApiClient();
    await client.clearCookies();
    final originalBaseUrl = KugouEndpoints.baseUrl;
    final originalAdapter = client.dio.httpClientAdapter;
    final adapter = _TransientLyricAdapter();
    client.updateBaseUrl('http://provider-lyric-fixture.invalid');
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final provider = KugouProvider();
    try {
      final failed = await provider.getLyricResult('fixture-hash', fmt: 'krc');

      expect(failed.status, LyricLookupStatus.transientFailure);
      expect(provider.lyric, isNull);

      final recovered = await provider.getLyricResult(
        'fixture-hash',
        fmt: 'krc',
      );

      expect(recovered.status, LyricLookupStatus.found);
      expect(recovered.lyric?.decodedContent, '[00:01.00]Recovered lyric');
      expect(provider.lyric?.decodedContent, '[00:01.00]Recovered lyric');
      expect(provider.error, isNull);
      expect(adapter.searchRequestCount, 2);
      expect(adapter.lyricRequestCount, 1);
    } finally {
      provider.dispose();
      client.updateBaseUrl(originalBaseUrl);
      client.dio.httpClientAdapter = originalAdapter;
      uninstallFakeSecureStorage();
    }
  });

  test('同键的两个歌词消费者共享一次Provider请求并分别收到结果', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();

    final client = KugouApiClient();
    await client.clearCookies();
    final originalBaseUrl = KugouEndpoints.baseUrl;
    final originalAdapter = client.dio.httpClientAdapter;
    final adapter = _DeduplicatedLyricAdapter();
    client.updateBaseUrl('http://provider-lyric-dedup.invalid');
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final provider = KugouProvider();
    try {
      final first = provider.getLyricResult('shared-hash', fmt: 'krc');
      final second = provider.getLyricResult('shared-hash', fmt: 'krc');
      await adapter.lyricRequested.future.timeout(const Duration(seconds: 2));

      expect(adapter.searchRequestCount, 1);
      expect(adapter.lyricRequestCount, 1);

      adapter.completeLyric();
      final results = await Future.wait([first, second]);
      expect(results.map((result) => result.status), [
        LyricLookupStatus.found,
        LyricLookupStatus.found,
      ]);
      expect(results.map((result) => result.lyric?.decodedContent), [
        '[00:01.00]Shared lyric',
        '[00:01.00]Shared lyric',
      ]);
      expect(provider.lyric?.decodedContent, '[00:01.00]Shared lyric');
    } finally {
      provider.dispose();
      client.updateBaseUrl(originalBaseUrl);
      client.dio.httpClientAdapter = originalAdapter;
      uninstallFakeSecureStorage();
    }
  });

  test('共享歌词请求及中途加入的消费者都立即收到正文首包', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    await client.clearCookies();
    final originalBaseUrl = KugouEndpoints.baseUrl;
    final originalAdapter = client.dio.httpClientAdapter;
    final adapter = _DeduplicatedLyricAdapter(progressive: true);
    client.updateBaseUrl('http://provider-lyric-progress.invalid');
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();
    final provider = KugouProvider(registerDeviceOnStart: false);
    final firstProgress = Completer<void>();
    final secondProgress = Completer<void>();
    try {
      final first = provider.getLyricResult('shared-hash', onProgress: (_) {
        if (!firstProgress.isCompleted) firstProgress.complete();
      });
      await firstProgress.future.timeout(const Duration(seconds: 2));
      final second = provider.getLyricResult('shared-hash', onProgress: (_) {
        if (!secondProgress.isCompleted) secondProgress.complete();
      });
      await secondProgress.future.timeout(const Duration(seconds: 2));
      expect(provider.lyric?.decodedContent, contains('First lyric'));
      expect(adapter.searchRequestCount, 1);
      adapter.completeLyric();
      expect((await first).isFound, isTrue);
      expect((await second).isFound, isTrue);
      expect(adapter.lyricRequestCount, 2);
    } finally {
      provider.dispose();
      client.updateBaseUrl(originalBaseUrl);
      client.dio.httpClientAdapter = originalAdapter;
      uninstallFakeSecureStorage();
    }
  });

  test('无词负缓存命中且forceRefresh会重新请求', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();

    final client = KugouApiClient();
    await client.clearCookies();
    final originalBaseUrl = KugouEndpoints.baseUrl;
    final originalAdapter = client.dio.httpClientAdapter;
    final adapter = _NegativeCacheLyricAdapter();
    client.updateBaseUrl('http://provider-lyric-negative.invalid');
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final provider = KugouProvider();
    try {
      final first = await provider.getLyricResult('negative-hash', fmt: 'krc');
      final cached = await provider.getLyricResult('negative-hash', fmt: 'krc');
      expect(first.status, LyricLookupStatus.notFound);
      expect(cached.status, LyricLookupStatus.notFound);
      expect(adapter.searchRequestCount, 1);

      final refreshed = await provider.getLyricResult(
        'negative-hash',
        fmt: 'krc',
        forceRefresh: true,
      );
      expect(refreshed.status, LyricLookupStatus.found);
      expect(refreshed.lyric?.decodedContent, '[00:01.00]Refreshed lyric');
      expect(adapter.searchRequestCount, 2);
      expect(adapter.lyricRequestCount, 1);
    } finally {
      provider.dispose();
      client.updateBaseUrl(originalBaseUrl);
      client.dio.httpClientAdapter = originalAdapter;
      uninstallFakeSecureStorage();
    }
  });

  test('A→B→A时第一轮迟到歌词不能覆盖A的新查询结果', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();

    final client = KugouApiClient();
    await client.clearCookies();
    final originalBaseUrl = KugouEndpoints.baseUrl;
    final originalAdapter = client.dio.httpClientAdapter;
    final adapter = _AbaLyricAdapter();
    client.updateBaseUrl('http://provider-lyric-aba.invalid');
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final provider = KugouProvider();
    try {
      final firstA = provider.getLyricResult(
        'same-song-hash',
        songName: 'Track',
        fmt: 'krc',
      );
      await adapter.oldLyricRequested.future.timeout(
        const Duration(seconds: 2),
      );

      final songB = await provider.getLyricResult(
        'song-b-hash',
        songName: 'Song B',
        fmt: 'krc',
      );
      expect(songB.lyric?.decodedContent, '[00:01.00]Song B');
      expect(provider.lyric?.decodedContent, '[00:01.00]Song B');

      final secondA = await provider.getLyricResult(
        'same-song-hash',
        songName: 'Track refreshed',
        fmt: 'krc',
      );
      expect(secondA.lyric?.decodedContent, '[00:01.00]Song A refreshed');
      expect(provider.lyric?.decodedContent, '[00:01.00]Song A refreshed');

      adapter.completeOldLyric();
      final lateFirstA = await firstA;
      expect(lateFirstA.lyric?.decodedContent, '[00:01.00]Song A old');
      expect(provider.lyric?.decodedContent, '[00:01.00]Song A refreshed');
    } finally {
      provider.dispose();
      client.updateBaseUrl(originalBaseUrl);
      client.dio.httpClientAdapter = originalAdapter;
      uninstallFakeSecureStorage();
    }
  });
}

class _TransientLyricAdapter implements HttpClientAdapter {
  int searchRequestCount = 0;
  int lyricRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == KugouEndpoints.searchLyric) {
      searchRequestCount++;
      if (searchRequestCount == 1) {
        return _response({'error': 'temporary'}, 503);
      }
      return _response({
        'candidates': [
          {'id': 'fixture-lyric-id', 'accesskey': 'fixture-access-key'},
        ],
      });
    }

    if (options.path == KugouEndpoints.lyric) {
      lyricRequestCount++;
      return _response({
        'data': {'decodeContent': '[00:01.00]Recovered lyric'},
      });
    }

    return _response(<String, Object?>{});
  }

  ResponseBody _response(Object body, [int statusCode = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        statusCode,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

class _AbaLyricAdapter implements HttpClientAdapter {
  final Completer<void> oldLyricRequested = Completer<void>();
  final Completer<ResponseBody> _oldLyricResponse = Completer<ResponseBody>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == KugouEndpoints.searchLyric) {
      final hash = options.queryParameters['hash'];
      final lyricId = switch (hash) {
        'same-song-hash' when !oldLyricRequested.isCompleted => 'song-a-old',
        'same-song-hash' => 'song-a-refreshed',
        'song-b-hash' => 'song-b',
        _ => 'unexpected-song',
      };
      return _response({
        'candidates': [
          {'id': lyricId, 'accesskey': 'fixture-key'},
        ],
      });
    }

    if (options.path == KugouEndpoints.lyric) {
      final lyricId = options.queryParameters['id'];
      if (lyricId == 'song-a-old') {
        oldLyricRequested.complete();
        return _oldLyricResponse.future;
      }
      final text = switch (lyricId) {
        'song-b' => '[00:01.00]Song B',
        'song-a-refreshed' => '[00:01.00]Song A refreshed',
        _ => '[00:01.00]Unexpected song',
      };
      return _response({
        'data': {'decodeContent': text},
      });
    }

    return _response(<String, Object?>{});
  }

  void completeOldLyric() {
    _oldLyricResponse.complete(
      _response({
        'data': {'decodeContent': '[00:01.00]Song A old'},
      }),
    );
  }

  ResponseBody _response(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: const {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _DeduplicatedLyricAdapter implements HttpClientAdapter {
  _DeduplicatedLyricAdapter({this.progressive = false});
  final bool progressive;
  final Completer<void> lyricRequested = Completer<void>();
  final Completer<ResponseBody> _lyricResponse = Completer<ResponseBody>();
  int searchRequestCount = 0;
  int lyricRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == KugouEndpoints.searchLyric) {
      searchRequestCount++;
      return _response({
        'candidates': [
          {'id': 'shared-id', 'accesskey': 'fixture-key'},
        ],
      });
    }
    if (options.path == KugouEndpoints.lyric) {
      lyricRequestCount++;
      if (progressive && options.queryParameters['fmt'] == 'lrc') {
        return _response({'data': {'decodeContent': '[00:01.00]First lyric'}});
      }
      lyricRequested.complete();
      return _lyricResponse.future;
    }
    return _response(<String, Object?>{});
  }

  void completeLyric() {
    _lyricResponse.complete(
      _response({
        'data': {'decodeContent': '[00:01.00]Shared lyric'},
      }),
    );
  }

  ResponseBody _response(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: const {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _NegativeCacheLyricAdapter implements HttpClientAdapter {
  int searchRequestCount = 0;
  int lyricRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == KugouEndpoints.searchLyric) {
      searchRequestCount++;
      if (searchRequestCount == 1) {
        return _response({'candidates': <Object>[]});
      }
      return _response({
        'candidates': [
          {'id': 'refreshed-id', 'accesskey': 'fixture-key'},
        ],
      });
    }
    if (options.path == KugouEndpoints.lyric) {
      lyricRequestCount++;
      return _response({
        'data': {'decodeContent': '[00:01.00]Refreshed lyric'},
      });
    }
    return _response(<String, Object?>{});
  }

  ResponseBody _response(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: const {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
