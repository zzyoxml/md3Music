import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/listen_stats_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

import '../test_helpers/fake_secure_storage.dart';

/// /user/listen · /user/history 响应结构未文档化：本文件用防御式解析的
/// 多形态样例（info/list/songs 数组、嵌套 song 层、字段别名）锁定解析行为，
/// 实调确认真实字段后可收窄候选集，但不应破坏这些兜底。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _ListenApiAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _ListenApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
  });

  tearDown(() {
    uninstallFakeSecureStorage();
  });

  // ==================== 模型防御式解析 ====================

  group('KugouListenRanking.fromJson 防御式解析', () {
    test('data.lists 数组（2026-10-11 实机确认真值键）+ count 字段', () {
      // 实机样本的数据层结构：data_date/servertime/lists/total_history/
      // total_week/hide_mixsongids（条目级字段以真实非空响应为准，此处用别名样例）
      final ranking = KugouListenRanking.fromJson(
        {
          'status': 1,
          'error_code': 0,
          'data': {
            'data_date': 20240629,
            'servertime': 1791731336,
            'lists': [
              {
                'hash': 'hash-a',
                'filename': '歌手A - 歌一',
                'count': 12,
              },
              {'hash': 'hash-b', 'ori_audio_name': '歌二', 'count': 3},
            ],
            'total_history': 3,
            'total_week': 0,
            'hide_mixsongids': <Object?>[],
          },
        },
        type: 1,
      );
      expect(ranking.ok, isTrue);
      expect(ranking.type, 1);
      expect(ranking.songs, hasLength(2));
      expect(ranking.songs[0].song.id, 'hash-a');
      expect(ranking.songs[0].playCount, 12);
      expect(ranking.songs[1].song.title, contains('歌二'));
      expect(ranking.songs[1].playCount, 3);
    });

    test('实机确认的空响应形态：lists 空数组 + ok=true（不是失败）', () {
      final ranking = KugouListenRanking.fromJson(
        const {
          'data': {
            'data_date': 20240629,
            'servertime': 1791731336,
            'lists': <Object?>[],
            'total_history': 3,
            'total_week': 0,
            'hide_mixsongids': <Object?>[],
          },
          'status': 1,
          'error_code': 0,
        },
      );
      expect(ranking.ok, isTrue);
      expect(ranking.songs, isEmpty);
    });

    test('data.info 数组 + count 字段（防御式候选）', () {
      final ranking = KugouListenRanking.fromJson(
        {
          'status': 1,
          'error_code': 0,
          'data': {
            'info': [
              {
                'hash': 'hash-a',
                'filename': '歌手A - 歌一',
                'count': 12,
              },
              {'hash': 'hash-b', 'ori_audio_name': '歌二', 'count': 3},
            ],
          },
        },
        type: 1,
      );
      expect(ranking.ok, isTrue);
      expect(ranking.type, 1);
      expect(ranking.songs, hasLength(2));
      expect(ranking.songs[0].song.id, 'hash-a');
      expect(ranking.songs[0].playCount, 12);
      expect(ranking.songs[1].song.title, contains('歌二'));
      expect(ranking.songs[1].playCount, 3);
    });

    test('data.list 数组 + play_count 别名 + 嵌套 song 层', () {
      final ranking = KugouListenRanking.fromJson(
        const {
          'data': {
            'list': [
              {
                'song': {
                  'hash': 'hash-c',
                  'songname': '歌三',
                  'author_name': '歌手C',
                  'play_count': 7,
                },
              },
            ],
          },
        },
      );
      expect(ranking.songs, hasLength(1));
      expect(ranking.songs[0].song.id, 'hash-c');
      expect(ranking.songs[0].song.artist, '歌手C');
      expect(ranking.songs[0].playCount, 7);
    });

    test('count 缺失 → playCount 为 null（UI 只显示排名）', () {
      final ranking = KugouListenRanking.fromJson(
        const {
          'data': {
            'songs': [
              {'hash': 'hash-d', 'name': '歌四'},
            ],
          },
        },
      );
      expect(ranking.songs, hasLength(1));
      expect(ranking.songs[0].playCount, isNull);
    });

    test('业务失败（error_code 非 0）→ ok=false 且 songs 空', () {
      final ranking = KugouListenRanking.fromJson(
        const {'status': 0, 'error_code': 20010, 'data': null},
      );
      expect(ranking.ok, isFalse);
      expect(ranking.songs, isEmpty);
    });

    test('无数组结构 → songs 空（不抛异常）', () {
      final ranking = KugouListenRanking.fromJson(const {'status': 1});
      expect(ranking.ok, isTrue);
      expect(ranking.songs, isEmpty);
    });
  });

  group('KugouHistorySnapshot.fromJson 防御式解析', () {
    test('data.lists（实机确认键）条目 + timestamp 归一化（毫秒→秒）+ bp 游标', () {
      final snapshot = KugouHistorySnapshot.fromJson(
        const {
          'status': 1,
          'error_code': 0,
          'data': {
            'lists': [
              {'hash': 'h1', 'filename': '歌一', 'timestamp': 1700000000123},
              {'hash': 'h2', 'songname': '歌二', 'timestamp': 1700000000},
            ],
            'bp': 'next-cursor-1',
          },
        },
      );
      expect(snapshot.ok, isTrue);
      expect(snapshot.entries, hasLength(2));
      expect(snapshot.entries[0].song.id, 'h1');
      // 毫秒归一化为秒
      expect(snapshot.entries[0].timestampSec, 1700000000);
      expect(snapshot.entries[1].timestampSec, 1700000000);
      expect(snapshot.nextBp, 'next-cursor-1');
      expect(snapshot.hasMore, isTrue);
    });

    test('data.list 条目（防御式候选）+ timestamp 归一化', () {
      final snapshot = KugouHistorySnapshot.fromJson(
        const {
          'status': 1,
          'error_code': 0,
          'data': {
            'list': [
              {'hash': 'h1', 'filename': '歌一', 'timestamp': 1700000000123},
              {'hash': 'h2', 'songname': '歌二', 'timestamp': 1700000000},
            ],
            'bp': 'next-cursor-1',
          },
        },
      );
      expect(snapshot.ok, isTrue);
      expect(snapshot.entries, hasLength(2));
      expect(snapshot.entries[0].song.id, 'h1');
      // 毫秒归一化为秒
      expect(snapshot.entries[0].timestampSec, 1700000000);
      expect(snapshot.entries[1].timestampSec, 1700000000);
      expect(snapshot.nextBp, 'next-cursor-1');
      expect(snapshot.hasMore, isTrue);
    });

    test('无游标 → hasMore=false', () {
      final snapshot = KugouHistorySnapshot.fromJson(
        const {
          'data': {
            'list': [
              {'hash': 'h1', 'filename': '歌一'},
            ],
          },
        },
      );
      expect(snapshot.nextBp, isNull);
      expect(snapshot.hasMore, isFalse);
    });

    test('空页：entries 空 + 有游标 → 空数组是合法结果', () {
      final snapshot = KugouHistorySnapshot.fromJson(
        const {
          'data': {'list': [], 'bp': 'cursor-end'},
        },
      );
      expect(snapshot.entries, isEmpty);
      expect(snapshot.hasMore, isTrue);
    });
  });

  // ==================== Provider 拉取与翻页 ====================

  group('ListenStatsProvider', () {
    /// 构造 /user/history 的歌曲条目（实机确认结构：songs[] + 嵌套 info{} + pc/ot）。
    Map<String, dynamic> historyItem(
      String hash, {
      required String name,
      required String artist,
      int pc = 1,
      int ot = 0,
      String? album,
    }) =>
        {
          'mxid': hash.hashCode & 0x7fffffff,
          'ot': ot,
          'pc': pc,
          'op': 1,
          'sr': 0,
          'info': {
            'name': name,
            'singername': artist,
            'hash': hash,
            'timelen': 200000,
            'mixsongid': hash.hashCode & 0x7fffffff,
            if (album != null) 'album_name': album,
          },
        };

    test('loadRanking：由历史聚合派生双榜 + 缓存复用（第二次不发请求）', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'songs': [
              historyItem('h1', name: '歌一', artist: '歌手A', pc: 5, ot: now - 3600),
              historyItem('h2', name: '歌二', artist: '歌手B', pc: 9, ot: now - 7200),
            ],
          },
        },
      ];
      await provider.loadRanking(0);

      expect(adapter.historyQueries, isNotEmpty);
      // 全部累计按 pc 降序（歌二 9 > 歌一 5）
      expect(provider.rankingSongs(1), hasLength(2));
      expect(provider.rankingSongs(1).first.song.id, 'h2');
      expect(provider.rankingSongs(1).first.playCount, 9);
      // 两条都在一周内 → 周榜同集合
      expect(provider.rankingSongs(0), hasLength(2));
      expect(provider.isRankingLoaded(0), isTrue);
      expect(provider.isRankingLoaded(1), isTrue);
      expect(provider.rankingError(0), isNull);

      final queriesBefore = adapter.historyQueries.length;
      await provider.loadRanking(0);
      expect(adapter.historyQueries, hasLength(queriesBefore), reason: '缓存复用');
    });

    test('最近一周窗口过滤：7 天前的记录只进全部累计榜', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'songs': [
              historyItem('w1', name: '周歌', artist: '歌手A', pc: 3, ot: now - 100),
              historyItem(
                'o1',
                name: '老歌',
                artist: '歌手B',
                pc: 30,
                ot: now - 9 * 24 * 3600,
              ),
            ],
          },
        },
      ];
      await provider.loadRanking(0);

      expect(provider.rankingSongs(0), hasLength(1));
      expect(provider.rankingSongs(0).first.song.id, 'w1');
      expect(provider.rankingSongs(1), hasLength(2));
      // 全部累计按次数：老歌 30 居首
      expect(provider.rankingSongs(1).first.song.id, 'o1');
    });

    test('同曲多条目合并：pc 取最大、ot 取最新', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'songs': [
              historyItem('dup', name: '重复歌', artist: '歌手A', pc: 2, ot: now - 999999),
              historyItem('dup', name: '重复歌', artist: '歌手A', pc: 7, ot: now - 60),
            ],
          },
        },
      ];
      await provider.loadRanking(0);

      expect(provider.rankingSongs(1), hasLength(1), reason: '同 hash 合并');
      expect(provider.rankingSongs(1).first.playCount, 7, reason: 'pc 取最大');
      expect(provider.rankingSongs(0), hasLength(1), reason: 'ot 取最新落在一周窗口');
    });

    test('排行翻页深度：最多 3 页，游标耗尽即停', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      Map<String, dynamic> page(String id, String bp) => {
            'status': 1,
            'data': {
              'songs': [historyItem(id, name: '歌$id', artist: '歌手', pc: 1, ot: now - 60)],
              if (bp.isNotEmpty) 'bp': bp,
            },
          };
      // 提供 5 页，但 provider 只应取 3 页
      adapter.historyResponses = [
        page('p1', 'c1'),
        page('p2', 'c2'),
        page('p3', 'c3'),
        page('p4', 'c4'),
        page('p5', ''),
      ];
      await provider.loadRanking(0);

      expect(adapter.historyQueries, hasLength(3),
          reason: 'rankingMaxHistoryPages=3');
      expect(provider.rankingSongs(1), hasLength(3));
    });

    test('历史业务失败：排行置 error 不置 loaded（区分空与失败）', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      adapter.historyResponses = [
        {'status': 0, 'error_code': 20010},
      ];
      await provider.loadRanking(0);

      expect(provider.isRankingLoaded(0), isFalse);
      expect(provider.rankingError(0), isNotNull);
      expect(provider.rankingSongs(0), isEmpty);
    });

    test('loadHistory + loadMoreHistory：bp 游标翻页拼接', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'list': [
              {'hash': 'h1', 'filename': '歌一', 'timestamp': 1700000000},
            ],
            'bp': 'cursor-1',
          },
        },
        {
          'status': 1,
          'data': {
            'list': [
              {'hash': 'h2', 'filename': '歌二', 'timestamp': 1700000100},
              {'hash': 'h3', 'filename': '歌三', 'timestamp': 1700000200},
            ],
            'bp': 'cursor-2',
          },
        },
      ];
      await provider.loadHistory();

      expect(adapter.historyQueries, hasLength(1));
      expect(adapter.historyQueries.first.containsKey('bp'), isFalse,
          reason: '首页不带 bp');
      expect(provider.historyEntries, hasLength(1));
      expect(provider.historyHasMore, isTrue);

      await provider.loadMoreHistory();

      expect(adapter.historyQueries, hasLength(2));
      expect(adapter.historyQueries.last['bp'], 'cursor-1');
      // 客户端按 ot 降序排序（服务端顺序不可依赖）：h3(200) > h2(100) > h1(0)
      expect(provider.historyEntries.map((e) => e.song.id), ['h3', 'h2', 'h1']);
      expect(provider.historyHasMore, isTrue);
    });

    test('历史按播放时间降序排序（服务端顺序不可依赖）', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      // 模拟实机观察到的乱序：新记录散落在旧记录之间
      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'songs': [
              historyItem('mid', name: '中', artist: 'A', ot: 1700000500),
              historyItem('today', name: '今天', artist: 'A', ot: 1700009999),
              historyItem('old', name: '老', artist: 'B', ot: 1700000000),
              historyItem('no-ts', name: '无时间', artist: 'C'),
            ],
          },
        },
      ];
      await provider.loadHistory();

      expect(
        provider.historyEntries.map((e) => e.song.id).toList(),
        ['today', 'mid', 'old', 'no-ts'],
        reason: 'ot 降序；无时间戳沉底',
      );
    });

    test('翻页空页 → 停止（hasMore=false）', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'list': [
              {'hash': 'h1', 'filename': '歌一'},
            ],
            'bp': 'cursor-1',
          },
        },
        {
          'status': 1,
          'data': {'list': []},
        },
      ];
      await provider.loadHistory();
      await provider.loadMoreHistory();

      expect(provider.historyEntries, hasLength(1));
      expect(provider.historyHasMore, isFalse);
    });

    test('loadMoreHistory 在无游标时为空操作', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'list': [
              {'hash': 'h1', 'filename': '歌一'},
            ],
          },
        },
      ];
      await provider.loadHistory();
      expect(provider.historyHasMore, isFalse);

      await provider.loadMoreHistory();
      expect(adapter.historyQueries, hasLength(1));
    });

    test('syncLoginState：账号翻转清空缓存', () async {
      final provider = ListenStatsProvider();
      addTearDown(provider.dispose);

      await provider.loadRanking(0);
      await provider.loadHistory();
      expect(provider.isRankingLoaded(0), isTrue);
      expect(provider.historyLoaded, isTrue);

      provider.syncLoginState(loggedIn: true, userid: '10086');

      expect(provider.isRankingLoaded(0), isFalse);
      expect(provider.historyLoaded, isFalse);
      expect(provider.historyEntries, isEmpty);
      // 同参数重复同步不清
      provider.syncLoginState(loggedIn: true, userid: '10086');
      expect(provider.historyLoaded, isFalse);
    });
  });

  // ==================== 统计聚合纯函数 ====================

  group('computeListenStats', () {
    Song songOf(
      String id, {
      String artist = '歌手A',
      String album = '专辑一',
      String? artistId,
    }) =>
        Song(
          id: id,
          title: '歌$id',
          artist: artist,
          album: album,
          duration: const Duration(seconds: 180),
          artistId: artistId,
        );

    test('次数合计 + 歌手/专辑聚合 + 高频歌曲排序', () {
      final agg = computeListenStats(
        weekSongs: [
          KugouRankedSong(song: songOf('w1'), playCount: 10),
          KugouRankedSong(song: songOf('w2'), playCount: 5),
        ],
        allTimeSongs: [
          KugouRankedSong(song: songOf('t1'), playCount: 30),
          KugouRankedSong(
            song: songOf('t2', artist: '歌手A、歌手B'),
            playCount: 20,
          ),
          KugouRankedSong(
            song: songOf('t3', artist: '歌手C', album: '专辑二'),
            playCount: 40,
          ),
        ],
        historyEntries: const [],
      );

      expect(agg.weekTotalPlays, 15);
      expect(agg.weekSongCount, 2);
      expect(agg.totalPlays, 90);
      expect(agg.totalSongCount, 3);
      // 歌手聚合：歌手A = 30 + 20 = 50（多歌手拆分），歌手B = 20
      expect(agg.topArtists.first.name, '歌手A');
      expect(agg.topArtists.first.plays, 50);
      expect(agg.topArtists.first.songCount, 2);
      // 专辑聚合：专辑一 = 30 + 20 = 50 > 专辑二 40
      expect(agg.topAlbum!.name, '专辑一');
      expect(agg.topAlbum!.plays, 50);
      expect(agg.topAlbum!.songCount, 2);
      // 高频歌曲按次数降序
      expect(agg.topSongs.first.song.id, 't3');
      expect(agg.topSongs, hasLength(3));
    });

    test('7 天柱状图与时段偏好（历史时间戳聚合，7 天窗口含空天）', () {
      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final agg = computeListenStats(
        weekSongs: const [],
        allTimeSongs: const [],
        historyEntries: [
          // 今天 3 点（凌晨桶）与 15 点（下午桶）
          KugouHistoryEntry(
            song: songOf('h1'),
            timestampSec: todayStart
                .add(const Duration(hours: 3))
                .millisecondsSinceEpoch ~/
                1000,
          ),
          KugouHistoryEntry(
            song: songOf('h2'),
            timestampSec: todayStart
                .add(const Duration(hours: 15))
                .millisecondsSinceEpoch ~/
                1000,
          ),
          // 3 天前
          KugouHistoryEntry(
            song: songOf('h3'),
            timestampSec: todayStart
                .subtract(const Duration(days: 3))
                .millisecondsSinceEpoch ~/
                1000,
          ),
          // 8 天前（窗外，不计入 7 天但计入时段）
          KugouHistoryEntry(
            song: songOf('h4'),
            timestampSec: todayStart
                .subtract(const Duration(days: 8))
                .millisecondsSinceEpoch ~/
                1000,
          ),
        ],
      );

      expect(agg.historyTimeAvailable, isTrue);
      expect(agg.historySampleCount, 4);
      expect(agg.last7Days, hasLength(7));
      expect(agg.last7Days.last.plays, 2, reason: '今天 2 条');
      expect(agg.last7Days[3].plays, 1, reason: '3 天前 1 条');
      expect(agg.last7Days[2].plays, 0, reason: '4 天前无记录');
      // 时段：3 点→凌晨；15 点→下午；3 天前与 8 天前均按 0 点→凌晨
      expect(agg.timeBuckets[0], 3, reason: '凌晨：h1(3点) + h3(0点) + h4(0点)');
      expect(agg.timeBuckets[2], 1, reason: '下午 15 点');
    });

    test('无时间戳 → historyTimeAvailable=false（UI 降级隐藏）', () {
      final agg = computeListenStats(
        weekSongs: const [],
        allTimeSongs: const [],
        historyEntries: [
          KugouHistoryEntry(
            song: Song(
              id: 'x',
              title: 't',
              artist: 'a',
              album: 'b',
              duration: const Duration(seconds: 60),
            ),
          ),
        ],
      );
      expect(agg.historyTimeAvailable, isFalse);
      expect(agg.historySampleCount, 0);
    });
  });
}

/// /user/listen + /user/history 的 Dio adapter mock。
class _ListenApiAdapter implements HttpClientAdapter {
  /// /user/listen 响应体（测试可改写）
  Map<String, dynamic> listenResponse = {
    'status': 1,
    'error_code': 0,
    'data': {
      'info': [
        {'hash': 'hash-a', 'filename': '歌手A - 歌一', 'count': 12},
        {'hash': 'hash-b', 'songname': '歌二', 'count': 3},
      ],
    },
  };

  /// /user/history 按调用次序弹出的响应队列
  List<Map<String, dynamic>> historyResponses = [];

  final List<Map<String, String>> listenQueries = [];
  final List<Map<String, String>> historyQueries = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/user/listen') {
      listenQueries.add(options.uri.queryParameters);
      return _json(listenResponse);
    }
    if (path == '/user/history') {
      historyQueries.add(options.uri.queryParameters);
      if (historyResponses.isNotEmpty) {
        return _json(historyResponses.removeAt(0));
      }
      return _json(const {
        'status': 1,
        'data': {'list': []},
      });
    }
    // 其余路径（refreshUserInfo 的用户信息等）统一空对象
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
