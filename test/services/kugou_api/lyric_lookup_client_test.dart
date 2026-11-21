import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/services/kugou_api/lyric_lookup_result.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late String originalBaseUrl;
  var searchStatus = HttpStatus.ok;
  Object? searchBody = const {'candidates': <Object>[]};
  Object? lyricBody = const {
    'data': {'decodeContent': '[00:01.00]fixture lyric'},
  };
  FutureOr<(int, Object?)> Function(RequestOptions)? respondOverride;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    KugouApiClient.markServerReady();
    client = KugouApiClient();
    await client.clearCookies();
    originalBaseUrl = KugouEndpoints.baseUrl;
    client.updateBaseUrl('http://lyric-fixture.invalid');
    client.dio.httpClientAdapter = _LyricFixtureAdapter((options) {
      if (respondOverride != null) return respondOverride!(options);
      if (options.path == KugouEndpoints.searchLyric) {
        return (searchStatus, searchBody);
      }
      if (options.path == KugouEndpoints.lyric) {
        return (HttpStatus.ok, lyricBody);
      }
      return (HttpStatus.notFound, const <String, Object?>{});
    });
  });

  tearDownAll(() async {
    client.updateBaseUrl(originalBaseUrl);
    client.dio.close(force: true);
  });

  setUp(() {
    respondOverride = null;
    searchStatus = HttpStatus.ok;
    searchBody = const {'candidates': <Object>[]};
    lyricBody = const {
      'data': {'decodeContent': '[00:01.00]fixture lyric'},
    };
  });

  test('成功搜索且候选为空才映射为 notFound', () async {
    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.notFound);
  });

  test('HTTP服务暂时不可用映射为 transientFailure', () async {
    searchStatus = HttpStatus.serviceUnavailable;
    searchBody = const {'error': 'temporary'};

    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.transientFailure);
  });

  test('格式错误的候选响应映射为 invalidData', () async {
    searchBody = const {'candidates': 'not-a-list'};

    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.invalidData);
  });

  test('有效歌词内容映射为 found 并保留正文', () async {
    searchBody = const {
      'candidates': [
        {'id': 'lyric-1', 'accesskey': 'fixture-key'},
      ],
    };

    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.found);
    expect(result.lyric?.decodedContent, '[00:01.00]fixture lyric');
  });

  for (final fastFormat in ['lrc', 'krc']) {
    test('$fastFormat 首包立即可用，不等待另一格式慢请求', () async {
      final slow = Completer<(int, Object?)>();
      final first = Completer<void>();
      respondOverride = (options) {
        if (options.path == KugouEndpoints.searchLyric) {
          return (200, {'candidates': [{'id': 'main', 'accesskey': 'key'}]});
        }
        if (options.queryParameters['fmt'] != fastFormat) return slow.future;
        return (200, {'data': {'decodeContent': '[00:01.00]fast lyric'}});
      };
      var completed = false;
      final request = client.getLyricResult('hash', onProgress: (lyric) {
        if (!first.isCompleted) first.complete();
        expect(lyric.displayLyric, contains('fast lyric'));
      }).then((result) { completed = true; return result; });
      await first.future.timeout(const Duration(seconds: 2));
      expect(completed, isFalse, reason: '慢请求尚未完成，正文已经交给页面');
      slow.complete((200, {'data': {'decodeContent': '[00:01.00]fast lyric'}}));
      expect((await request).status, LyricLookupStatus.found);
    });
  }

  test('备用翻译慢请求不阻塞正文，完成后仍保留翻译', () async {
    final translation = Completer<(int, Object?)>();
    final translationRequested = Completer<void>();
    final first = Completer<KugouLyric>();
    respondOverride = (options) {
      if (options.path == KugouEndpoints.searchLyric) {
        return (200, {'candidates': [
          {'id': 'main', 'accesskey': 'key'}, {'id': 'translated', 'accesskey': 'key'},
        ]});
      }
      if (options.queryParameters['id'] == 'translated') {
        translationRequested.complete();
        return translation.future;
      }
      return (200, {'data': {'decodeContent': '[1000,1000]<0,1000,0>original'}});
    };
    final request = client.getLyricResult('hash', onProgress: (lyric) {
      if (!first.isCompleted) first.complete(lyric);
    });
    await translationRequested.future.timeout(const Duration(seconds: 2));
    expect((await first.future).displayLyric, contains('original'));
    final language = base64Encode(utf8.encode(jsonEncode({'content': [
      {'language': 0, 'lyricContent': [['中文翻译']]},
    ]})));
    translation.complete((200, {'data': {
      'decodeContent': '[language:$language]\n[1000,1000]<0,1000,0>original',
    }}));
    expect((await request).lyric?.translatedContent, contains('中文翻译'));
  });
}

class _LyricFixtureAdapter implements HttpClientAdapter {
  _LyricFixtureAdapter(this.respond);

  final FutureOr<(int, Object?)> Function(RequestOptions options) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (statusCode, body) = await respond(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
