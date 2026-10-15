import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/home_discover_progress_store.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/fake_secure_storage.dart';

/// `/home/discover`（首页刷歌推荐）在 Provider 层的游标 / 去重 / 通知行为。
///
/// 这个上游**没有 page/offset**，唯一的翻页依据是客户端自己数的
/// `today_play_num`（今日已播歌曲数）。于是"刷到第几"完全由 Provider 承担，
/// 一旦游标推进算错，表现就是刷着刷着开始重复出歌；一旦并列表时不换新 List
/// 实例，详情页那个 `Selector` 永远等不到值变化，滑到底部什么也不发生。
/// 这两件事都不会在静态分析里暴露，只能靠这里的断言守住。
void main() {
  // SharedPreferences 的 mock 与 dio 的拦截都依赖测试绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter originalAdapter;
  late _HomeDiscoverApiAdapter adapter;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    adapter = _HomeDiscoverApiAdapter();
    final apiClient = KugouApiClient();
    originalAdapter = apiClient.dio.httpClientAdapter;
    apiClient.dio.httpClientAdapter = adapter;
    // 账号列表落在 flutter_secure_storage 上，不装假实现的话 setLoginCookies
    // 会 MissingPluginException，switchAccount 直接在 switchToUser 那步返回
    // noCredentials（根本走不到断点重置那行）。
    installFakeSecureStorage();
    // KugouApiClient._onRequest 会先等本地 Rust 服务器 ready，没 ready 就直接
    // reject（connectionError「本地音乐服务尚未就绪」），请求根本走不到我们
    // 装的 httpClientAdapter。测试里没有真服务器，必须手动把它标成 ready。
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = originalAdapter;
    uninstallFakeSecureStorage();
  });

  group('刷歌游标与去重', () {
    late KugouProvider provider;

    setUp(() => provider = KugouProvider());
    tearDown(() => provider.dispose());

    test('首屏用游标 0 请求，且只拿到 4 条', () async {
      await provider.getHomeDiscover();

      expect(adapter.requestedPagesizes, [4]);
      expect(adapter.requestedTodayPlayNums, [0]);
      expect(provider.homeDiscoverSongs, hasLength(4));
    });

    test('续拉把游标推上去：next today_play_num = 已消费总数', () async {
      await provider.getHomeDiscover();
      expect(provider.homeDiscoverSongs, hasLength(4));

      await provider.fetchMoreHomeDiscover(minCount: 4);

      // 首屏消费了 4 首，下一次就该拿 4 去要下一批。
      expect(adapter.requestedTodayPlayNums.last, 4);
      expect(provider.homeDiscoverSongs, hasLength(4 + 30));
    });

    test('服务端整批重放同一批歌时 seen 拦掉，列表不出现重复', () async {
      await provider.getHomeDiscover();
      final firstBatch = provider.homeDiscoverSongs.map((e) => e.hash).toList();

      // 让上游开始重放与首屏完全相同的 4 首。
      adapter.replayHashes = firstBatch;
      final fresh = await provider.fetchMoreHomeDiscover(minCount: 4);

      // 一条新歌都没凑到，且没有把重复项塞进列表。
      expect(fresh, isEmpty);
      expect(provider.homeDiscoverSongs, hasLength(4));
      expect(
        provider.homeDiscoverSongs.map((e) => e.hash).toList(),
        firstBatch,
      );
    });

    test('重放无果时游标会自己往前推，而不是死循环问同一个窗口', () async {
      await provider.getHomeDiscover();
      final firstBatch = provider.homeDiscoverSongs.map((e) => e.hash).toList();
      adapter.replayHashes = firstBatch;

      await provider.fetchMoreHomeDiscover(minCount: 4);

      // maxAttempts=3 → 首次之外还试 2 次，游标每轮 +30。
      expect(adapter.requestedTodayPlayNums, [0, 4, 34, 64]);
    });

    test('列表每批都换成新实例 —— Selector 靠引用变化才重建', () async {
      await provider.getHomeDiscover();
      final before = provider.homeDiscoverSongs;

      await provider.fetchMoreHomeDiscover(minCount: 4);
      final after = provider.homeDiscoverSongs;

      // 详情页是 Selector<KugouProvider, List<KugouSongDetail>>，比较的是 ==。
      // 同一个实例原地 add 的话引用不变、比较恒等，新歌就永远画不出来。
      expect(identical(before, after), isFalse);
      expect(after.length, greaterThan(before.length));
    });

    test('续拉会通知监听者（它不走 loading 计数器边沿）', () async {
      var notified = 0;
      provider.addListener(() => notified++);

      await provider.getHomeDiscover();
      final afterFirst = notified;

      await provider.fetchMoreHomeDiscover(minCount: 4);
      expect(notified, greaterThan(afterFirst));
    });

    test('下拉刷新不清游标：重新请求时 today_play_num 仍是已消费总数', () async {
      await provider.getHomeDiscover();
      await provider.fetchMoreHomeDiscover(minCount: 4);
      final cursorBeforeRefresh = adapter.requestedTodayPlayNums.length;

      // forceRefresh 只绕过 5 分钟 TTL，不该把游标拨回 0。
      await provider.getHomeDiscover(forceRefresh: true);

      expect(adapter.requestedTodayPlayNums[cursorBeforeRefresh], 34);
      // 刷新拿到的是新歌，不是把首屏那 4 首又端回来。
      expect(provider.homeDiscoverSongs.length, greaterThan(4 + 30));
    });

    test('clearMemoryCache 只清展示列表，游标与断点仍在', () async {
      await provider.getHomeDiscover();
      await provider.fetchMoreHomeDiscover(minCount: 4);

      provider.clearMemoryCache();
      expect(provider.homeDiscoverSongs, isEmpty);

      // 重新拉取时游标从上次的地方继续，而不是从头刷。
      final before = adapter.requestedTodayPlayNums.length;
      await provider.getHomeDiscover();
      expect(adapter.requestedTodayPlayNums[before], 34);
    });
  });

  group('断点持久化与账号隔离', () {
    // [HomeDiscoverProgressStore] 的进程内缓存是**有意**的（一次进程只读一次，
    // 见它的类注释），所以这里不去断言"换个 Provider 实例会回读磁盘"——那不是
    // 它承诺的行为。改为直接查落盘的真实内容，以及换账号时是否被清干净。
    test('游标与 seen 确实落盘', () async {
      final provider = KugouProvider();
      await provider.getHomeDiscover();
      // save 是 fire-and-forget，等它把 key 写完。
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(HomeDiscoverProgressStore.prefKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['cursor'], 4);
      expect((decoded['seen'] as List<dynamic>), hasLength(4));

      provider.dispose();
    });

    test('换账号会丢弃断点：新账号从头刷，不接旧账号的游标', () async {
      final provider = KugouProvider();
      await provider.getHomeDiscover();
      await provider.fetchMoreHomeDiscover(minCount: 4);
      adapter.requestedTodayPlayNums.clear();
      await provider.apiClient.setLoginCookies('token_a', 'user_a');
      await provider.apiClient.setLoginCookies('token_b', 'user_b');

      await provider.switchAccount('user_b');

      // 断点已重置，重新拉取时 today_play_num 回到 0。
      await provider.getHomeDiscover(forceRefresh: true);
      expect(adapter.requestedTodayPlayNums.single, 0);

      provider.dispose();
    });
  });
}

/// 只认 `/home/discover`，按调用次序产出可预测的歌曲批次。
class _HomeDiscoverApiAdapter implements HttpClientAdapter {
  /// 每次请求记录的 `today_play_num`，供断言游标推进。
  final List<int> requestedTodayPlayNums = [];
  final List<int> requestedPagesizes = [];

  /// 非空时上游开始重放这批 hash（模拟服务端不认 today_play_num 的情况）。
  List<String>? replayHashes;

  int _batch = 0;
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 只处理刷歌。KugouApiClient 构造时还会发一次 /register/dev，把它也算进
    // 游标记录里会让断言多出一条 today_play_num=-1 的噪声。
    if (!options.path.contains('/home/discover')) {
      return ResponseBody.fromString(
        jsonEncode({'status': 1, 'data': <String, dynamic>{}}),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }

    final todayPlayNum = int.tryParse(
      '${options.queryParameters['today_play_num']}',
    );
    final pagesize = int.tryParse('${options.queryParameters['pagesize']}') ?? 4;
    requestedTodayPlayNums.add(todayPlayNum ?? -1);
    requestedPagesizes.add(pagesize);

    final replay = replayHashes;
    final List<Map<String, dynamic>> songs;
    if (replay != null) {
      songs = replay
          .map((h) => {'hash': h, 'song_name': '重放_$h', 'filename': '重放_$h'})
          .toList();
    } else {
      songs = List.generate(pagesize, (i) {
        _index++;
        return {
          'hash': 'batch${_batch}_song$_index',
          'song_name': '歌$_index',
          'album_name': '专辑${_batch}',
          'album_id': '${1000 + _batch}',
          'timelength': 200000,
        };
      });
      _batch++;
    }

    return ResponseBody.fromString(
      jsonEncode({
        'status': 1,
        'data': {'song_list': songs},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
