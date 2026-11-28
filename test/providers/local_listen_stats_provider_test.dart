import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:md3music/data/db/listen_stats_db.dart';
import 'package:md3music/providers/local_listen_stats_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../test_helpers/fake_secure_storage.dart';

/// 带查询计数的桩库：验证缓存版本命中时不再重复聚合查询。
class _CountingDb extends ListenStatsDb {
  _CountingDb({required String super.dbPath});

  int countByUserCalls = 0;
  int topTracksQueries = 0;

  @override
  Future<int> countByUser({required bool validOnly}) {
    countByUserCalls++;
    return super.countByUser(validOnly: validOnly);
  }

  @override
  Future<List<Map<String, Object?>>> topTracks({
    int? startMs,
    int? endMs,
    int limit = 10,
    bool validOnly = true,
  }) {
    topTracksQueries++;
    return super.topTracks(
      startMs: startMs,
      endMs: endMs,
      limit: limit,
      validOnly: validOnly,
    );
  }
}

/// 本地听歌统计 Provider：时间范围聚合、Top 排序与归桶、缓存版本、跨账号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;
  late _CountingDb db;
  late LocalListenStatsProvider provider;
  late KugouApiClient client;

  final now = DateTime.now();
  int daysAgoMs(int d) =>
      now.subtract(Duration(days: d)).millisecondsSinceEpoch;

  /// 账号 u1 的流水（daysAgo=0 表示"现在"）。时间窗差异、跨月、
  /// 未知艺人/专辑归桶、重逢（歌七隔 10 天再听）都埋在这份流水里。
  final fixtures = <({
    String title,
    String? artist,
    String? album,
    int daysAgo,
    int playedMs,
    int? durationMs,
    bool valid,
  })>[
    (title: '歌一', artist: '歌手A', album: '专辑A', daysAgo: 1, playedMs: 120000, durationMs: 200000, valid: true),
    (title: '歌一', artist: '歌手A', album: '专辑A', daysAgo: 2, playedMs: 120000, durationMs: 200000, valid: true),
    (title: '歌一', artist: '歌手A', album: '专辑A', daysAgo: 3, playedMs: 120000, durationMs: 200000, valid: true),
    (title: '歌二', artist: '歌手A', album: '专辑B', daysAgo: 2, playedMs: 100000, durationMs: 200000, valid: true),
    (title: '歌二', artist: '歌手A', album: '专辑B', daysAgo: 3, playedMs: 100000, durationMs: 200000, valid: true),
    (title: '歌三', artist: '歌手B', album: '专辑B', daysAgo: 20, playedMs: 150000, durationMs: 300000, valid: true),
    (title: '歌四', artist: '歌手C', album: '专辑C', daysAgo: 100, playedMs: 200000, durationMs: 300000, valid: true),
    (title: '歌五', artist: '歌手D', album: '专辑D', daysAgo: 400, playedMs: 100000, durationMs: 200000, valid: true),
    // 无艺人/专辑：归"未知艺人/未知专辑"桶（本地歌常见形态）
    (title: '本地歌', artist: null, album: null, daysAgo: 1, playedMs: 300000, durationMs: null, valid: true),
    // 无效播放（不足半长且不足 4 分钟）：所有 validOnly 口径外
    (title: '歌六', artist: '歌手E', album: '专辑E', daysAgo: 1, playedMs: 30000, durationMs: 200000, valid: false),
    // 重逢：同曲隔 10 天再听
    (title: '歌七', artist: '歌手F', album: '专辑F', daysAgo: 10, playedMs: 60000, durationMs: 100000, valid: true),
    (title: '歌七', artist: '歌手F', album: '专辑F', daysAgo: 0, playedMs: 60000, durationMs: 100000, valid: true),
  ];

  /// 有效流水条数（= overview 的 plays 全量口径）。
  final validPlays = fixtures.where((f) => f.valid).length;

  /// 有效流水的净时长合计（毫秒）。
  final validPlayedMs =
      fixtures.where((f) => f.valid).fold(0, (s, f) => s + f.playedMs);

  /// 时间窗内（daysAgo <= n）的有效条数。
  int playsWithin(int n) =>
      fixtures.where((f) => f.valid && f.daysAgo <= n).length;

  Future<void> seedU1() async {
    for (final f in fixtures) {
      await db.insertRecord(
        songId: 'sid-${f.title}-${f.daysAgo}',
        title: f.title,
        artist: f.artist,
        album: f.album,
        durationMs: f.durationMs,
        playedMs: f.playedMs,
        playedAt: daysAgoMs(f.daysAgo),
        endReason: 'switched',
        valid: f.valid,
      );
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    await client.clearCookies();
    await client.setLoginCookies('t', 'u1');
    // 全部用例走 dbPath 注入，绕开 path_provider 插件
    tmpDir = await Directory.systemTemp.createTemp('local_stats_provider_test');
    db = _CountingDb(
      dbPath: '${tmpDir.path}${Platform.pathSeparator}listen_stats.db',
    );
    provider = LocalListenStatsProvider(db: db);
  });

  tearDown(() async {
    // Windows 文件锁：先关库再删临时目录
    await db.close();
    uninstallFakeSecureStorage();
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结论
    }
  });

  group('ListenStatsDb 聚合查询', () {
    test('topTracks：次数降序，并列按净时长、key 升序；代表演唱者正确', () async {
      await seedU1();
      final rows = await db.topTracks();
      // 歌七 2 次（120000）；count=1 组按净时长降序：本地歌 300000 >
      // 歌四 200000 > 歌三 150000 > 歌五 100000
      expect(rows.map((r) => r['key']).toList(), [
        '歌一',
        '歌二',
        '歌七',
        '本地歌',
        '歌四',
        '歌三',
        '歌五',
      ]);
      final g1 = rows.first;
      expect(g1['count'], 3);
      expect(g1['playedMs'], 360000);
      expect(g1['repArtist'], '歌手A');
      expect(g1['isUnknown'], false);
    });

    test('topArtists：NULL/空艺人归"未知艺人"桶并标记 isUnknown', () async {
      await seedU1();
      final rows = await db.topArtists();
      final names = rows.map((r) => r['key']).toList();
      expect(names.first, '歌手A', reason: '5 次（歌一 3 + 歌二 2）居首');
      expect(names, contains('未知艺人'));
      final unknown = rows.firstWhere((r) => r['key'] == '未知艺人');
      expect(unknown['isUnknown'], true);
      expect(unknown['count'], 1);
      expect(unknown['playedMs'], 300000);
      expect(unknown['repTitle'], '本地歌');
      // 代表作：歌手A 名下歌一（净时长 360000ms）压过歌二（200000ms）
      expect(rows.first['repTitle'], '歌一');
      expect(rows.first['isUnknown'], false);
    });

    test('topAlbums：同名专辑跨曲目合并，NULL 归"未知专辑"桶', () async {
      await seedU1();
      final rows = await db.topAlbums();
      // 专辑A 3 次 360000；专辑B = 歌二 2 次 + 歌三 1 次 = 3 次 350000
      expect(rows[0]['key'], '专辑A');
      expect(rows[0]['count'], 3);
      expect(rows[0]['playedMs'], 360000);
      expect(rows[1]['key'], '专辑B');
      expect(rows[1]['count'], 3);
      expect(rows[1]['playedMs'], 350000);
      final unknown = rows.firstWhere((r) => r['key'] == '未知专辑');
      expect(unknown['isUnknown'], true);
      expect(unknown['count'], 1);
    });

    test('overview：总次数/时长/活跃天/曲目/艺人，随时间窗收窄递减', () async {
      await seedU1();
      final all = await db.overview();
      expect(all.plays, validPlays, reason: '有效播放 11 条');
      expect(all.playedMs, validPlayedMs);
      expect(all.activeDays, 8, reason: 'd0..d3 / d10 / d20 / d100 / d400 共 8 个自然日');
      expect(all.distinctTracks, 7);
      expect(all.distinctArtists, 6, reason: '歌手A-F 共 5 位 + 未知一档');

      // 时间窗（滚动）：week 7 条 → month 9 条 → year 10 条（歌五在 400 天前）
      expect((await db.overview(startMs: daysAgoMs(7))).plays, playsWithin(7));
      expect(
        (await db.overview(startMs: daysAgoMs(30))).plays,
        playsWithin(30),
      );
      expect(
        (await db.overview(startMs: daysAgoMs(365))).plays,
        playsWithin(365),
      );
    });

    test('validOnly 差异：无效播放只计入 false 口径', () async {
      await seedU1();
      expect(await db.countByUser(validOnly: false), fixtures.length);
      expect(await db.countByUser(validOnly: true), validPlays);
      final allInvalid = await db.topTracks(validOnly: false);
      expect(allInvalid.map((r) => r['key']), contains('歌六'));
      expect(
        (await db.topTracks()).map((r) => r['key']),
        isNot(contains('歌六')),
      );
      expect(
        (await db.overview(validOnly: false)).plays,
        validPlays + 1,
        reason: '歌六一条无效播放',
      );
    });

    test('monthlyTrends：按本地自然月聚合（yyyyMM 升序），期望由流水推导', () async {
      await seedU1();
      final points = await db.monthlyTrends();
      final expected = <int, List<int>>{}; // ym -> [count, playedMs]
      for (final f in fixtures) {
        if (!f.valid) continue;
        final t = DateTime.fromMillisecondsSinceEpoch(daysAgoMs(f.daysAgo));
        final ym = t.year * 100 + t.month;
        final prev = expected[ym] ?? const <int>[0, 0];
        expected[ym] = <int>[prev[0] + 1, prev[1] + f.playedMs];
      }
      final yms = expected.keys.toList()..sort();
      expect(points.map((p) => p.month).toList(), yms);
      for (final p in points) {
        expect(p.count, expected[p.month]![0], reason: 'month=${p.month} 次数');
        expect(
          p.playedMs,
          expected[p.month]![1],
          reason: 'month=${p.month} 时长',
        );
      }
    });

    test('longestStreak：今天往前连续 4 天（d0..d3），孤日不连', () async {
      await seedU1();
      expect(await db.longestStreak(), 4);
    });

    test('rediscovery：同曲隔 ≥7 天再听计一次（歌七隔 10 天）', () async {
      await seedU1();
      expect(await db.rediscovery(), 1);
      // 收紧到 11 天以上：歌七的 10 天间隔不再达标
      expect(await db.rediscovery(minGapDays: 11), 0);
    });
  });

  group('LocalListenStatsProvider', () {
    test('四个时间范围各自聚合：week/month/year/all 递增', () async {
      await seedU1();
      provider.setRange(LocalListenStatsRange.week);
      await provider.load();
      expect(provider.overview.plays, playsWithin(7));
      expect(
        provider.topTracks.map((e) => e.key).toList(),
        ['歌一', '歌二', '本地歌', '歌七'],
      );
      expect(provider.topArtists.first.key, '歌手A');
      expect(provider.topAlbums.first.key, '专辑A');
      // 周窗内活跃天 = 今天 + 前 3 天
      expect(provider.overview.activeDays, 4);

      provider.setRange(LocalListenStatsRange.month);
      await provider.load();
      expect(provider.overview.plays, playsWithin(30));

      provider.setRange(LocalListenStatsRange.year);
      await provider.load();
      expect(provider.overview.plays, playsWithin(365));

      provider.setRange(LocalListenStatsRange.all);
      await provider.load();
      expect(provider.overview.plays, validPlays);
      expect(provider.overview.playedMs, validPlayedMs);
      expect(provider.overview.distinctTracks, 7);
      expect(provider.topTracks, hasLength(fixtures.where((f) => f.valid).map((f) => f.title).toSet().length));
    });

    test('monthlyTrends getter 与库层口径一致（all 范围）', () async {
      await seedU1();
      provider.setRange(LocalListenStatsRange.all);
      await provider.load();
      final dbPoints = await db.monthlyTrends();
      expect(provider.monthlyTrends, hasLength(dbPoints.length));
      for (var i = 0; i < dbPoints.length; i++) {
        expect(provider.monthlyTrends[i].month, dbPoints[i].month);
        expect(provider.monthlyTrends[i].count, dbPoints[i].count);
        expect(provider.monthlyTrends[i].playedMs, dbPoints[i].playedMs);
      }
    });

    test('缓存版本：记录数未变命中缓存，新增播放/force 才重查', () async {
      await seedU1();
      await provider.load();
      expect(db.topTracksQueries, 1);
      // 版本未变：直接命中缓存，不触发聚合查询
      await provider.load();
      expect(db.topTracksQueries, 1, reason: '版本一致不重查');
      expect(provider.topTracks, isNotEmpty);
      // 新播放入库 → countByUser 版本变化 → 重新聚合
      await db.insertRecord(
        title: '歌新',
        artist: '歌手A',
        playedMs: 120000,
        durationMs: 200000,
        playedAt: daysAgoMs(0),
        valid: true,
      );
      await provider.load();
      expect(db.topTracksQueries, 2, reason: '版本变化触发重查');
      expect(
        provider.topTracks.map((e) => e.key),
        contains('歌新'),
      );
      // force：跳过版本比对强制重查
      await provider.load(force: true);
      expect(db.topTracksQueries, 3);
    });

    test('跨账号：syncLoginState 清缓存，各账号统计隔离且可切回延续', () async {
      await seedU1();
      provider.setRange(LocalListenStatsRange.all);
      await provider.load();
      expect(provider.overview.plays, validPlays);

      // 切到 u2：新账号只看到自己的 1 条记录
      await client.setLoginCookies('t', 'u2');
      provider.syncLoginState(loggedIn: true, userid: 'u2');
      await db.insertRecord(
        title: 'u2的歌',
        artist: '歌手Z',
        playedMs: 120000,
        durationMs: 200000,
        playedAt: daysAgoMs(0),
        valid: true,
      );
      await provider.load();
      expect(provider.overview.plays, 1);
      expect(provider.topTracks.single.key, 'u2的歌');

      // 切回 u1：数据延续
      await client.setLoginCookies('t', 'u1');
      provider.syncLoginState(loggedIn: true, userid: 'u1');
      await provider.load();
      expect(provider.overview.plays, validPlays);
    });

    test('setRange 同值 no-op，切换后异步触发重载', () async {
      await seedU1();
      provider.setRange(LocalListenStatsRange.all);
      await provider.load();
      final loaded = provider.topTracks;
      provider.setRange(LocalListenStatsRange.all);
      await provider.load();
      expect(provider.selectedRange, LocalListenStatsRange.all);
      expect(provider.topTracks, loaded, reason: '同范围不重载，结果不变');
    });
  });
}
