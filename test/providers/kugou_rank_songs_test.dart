import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late KugouProvider provider;
  late KugouApiClient api;
  late HttpClientAdapter previousAdapter;
  late _RankAdapter adapter;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    KugouApiClient.markServerReady();
    api = KugouApiClient();
    previousAdapter = api.dio.httpClientAdapter;
    adapter = _RankAdapter();
    api.dio.httpClientAdapter = adapter;
    provider = KugouProvider(registerDeviceOnStart: false);
  });

  tearDown(() {
    provider.dispose();
    api.dio.httpClientAdapter = previousAdapter;
  });

  test('A→B→A 每次展示与当前请求对应的榜单', () async {
    await provider.getRankSongs(rankId: 'A');
    expect(provider.rankSongs.single.songName, 'A');
    await provider.getRankSongs(rankId: 'B');
    expect(provider.rankSongs.single.songName, 'B');
    await provider.getRankSongs(rankId: 'A');
    expect(provider.rankSongs.single.songName, 'A');
    expect(adapter.calls.map((call) => call.rankId), ['A', 'B', 'A']);
  });

  test('相同rankId但不同rankCid不是同一份新鲜缓存', () async {
    await provider.getRankSongs(rankId: 'A', rankCid: 1);
    await provider.getRankSongs(rankId: 'A', rankCid: 2);
    expect(adapter.calls.map((call) => call.rankCid), [1, 2]);
    expect(provider.rankSongs.single.songName, 'A-cid-2');
  });

  test('同一榜单首屏缓存新鲜时重复调用不重复请求', () async {
    await provider.getRankSongs(rankId: 'A');
    await provider.getRankSongs(rankId: 'A');
    expect(adapter.calls.map((call) => call.page), [1]);
  });

  test('分页结果覆盖共享列表后，首屏调用必须重新拉完整榜单', () async {
    await provider.getRankSongs(rankId: 'A');
    await provider.getRankSongs(rankId: 'A', page: 2, pagesize: 1);
    expect(adapter.calls.map((call) => call.page), [1, 2]);
    await provider.getRankSongs(rankId: 'A');
    expect(adapter.calls.map((call) => call.page), [1, 2, 1]);
  });

  test('晚返回的旧榜单请求不能覆盖新榜单', () async {
    final oldResponse = Completer<ResponseBody>();
    adapter.delayedRank = 'A';
    adapter.delayedResponse = oldResponse;
    final oldRequest = provider.getRankSongs(rankId: 'A');
    await Future<void>.delayed(Duration.zero);
    await provider.getRankSongs(rankId: 'B');
    expect(provider.rankSongs.single.songName, 'B');
    oldResponse.complete(_songResponse('A', count: 30));
    await oldRequest;
    expect(provider.rankSongs.single.songName, 'B');
    expect(adapter.calls.where((call) => call.rankId == 'A'), hasLength(1));
  });

  test('失败不保留旧榜单也不缓存失败，后续调用会重试', () async {
    await provider.getRankSongs(rankId: 'A');
    adapter.failNext = true;
    await provider.getRankSongs(rankId: 'B');
    expect(provider.rankSongs, isEmpty);
    expect(provider.error, isNotNull);
    await provider.getRankSongs(rankId: 'B');
    expect(provider.rankSongs.single.songName, 'B');
    expect(adapter.calls.where((call) => call.rankId == 'B'), hasLength(2));
  });
}

class _RankAdapter implements HttpClientAdapter {
  final calls = <({String rankId, int rankCid, int page})>[];
  String? delayedRank;
  Completer<ResponseBody>? delayedResponse;
  bool failNext = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.path.endsWith('/rank/audio')) {
      return ResponseBody.fromString('{"status":1,"data":{}}', 200);
    }
    final rankId = options.queryParameters['rankid'].toString();
    final rankCid = int.parse(options.queryParameters['rank_cid'].toString());
    final page = int.parse(options.queryParameters['page'].toString());
    calls.add((rankId: rankId, rankCid: rankCid, page: page));
    if (failNext) {
      failNext = false;
      return ResponseBody.fromString('{}', 500);
    }
    if (rankId == delayedRank && delayedResponse != null) {
      return delayedResponse!.future;
    }
    return _songResponse(rankCid == 0 ? rankId : '$rankId-cid-$rankCid');
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _songResponse(String name, {int count = 1}) => ResponseBody.fromString(
  jsonEncode({
    'status': 1,
    'data': {
      'songlist': List.generate(count, (index) {
        final songName = count == 1 ? name : '$name-$index';
        return {'hash': songName, 'songname': songName};
      }),
    },
  }),
  200,
  headers: {Headers.contentTypeHeader: ['application/json']},
);
