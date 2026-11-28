import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:md3music/data/db/listen_stats_db.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 听歌统计本地库：建表/插入回读、有效播放判定口径、账号隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;
  late String dbPath;
  late ListenStatsDb db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    await client.clearCookies();
    // 全部用例走 dbPath 注入，绕开 path_provider 插件
    tmpDir = await Directory.systemTemp.createTemp('listen_stats_test');
    dbPath = '${tmpDir.path}${Platform.pathSeparator}listen_stats.db';
    db = ListenStatsDb(dbPath: dbPath);
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

  group('建表与插入回读', () {
    test('插入后按 validOnly 两种口径回读计数', () async {
      await db.insertRecord(
        songId: 's1',
        mixsongid: 'mx1',
        title: '歌一',
        artist: '歌手A',
        album: '专辑A',
        durationMs: 200000,
        playedMs: 150000,
        playedAt: 1700000000000,
        endReason: 'completed',
        valid: true,
      );
      await db.insertRecord(
        title: '歌二',
        playedMs: 30000,
        valid: false,
      );

      expect(await db.countByUser(validOnly: true), 1);
      expect(await db.countByUser(validOnly: false), 2);
    });

    test('未登录记录落在空 user_id 下且可回读', () async {
      await db.insertRecord(title: '本地歌', playedMs: 60000, valid: true);
      expect(await db.countByUser(validOnly: true), 1);
      expect(await db.countByUser(validOnly: false), 1);
    });

    test('close 后再次操作自动重开（懒开库幂等）', () async {
      await db.insertRecord(title: '歌', playedMs: 1000, valid: true);
      await db.close();
      await db.insertRecord(title: '歌', playedMs: 1000, valid: true);
      expect(await db.countByUser(validOnly: false), 2);
    });
  });

  group('isValidPlay 口径（Last.fm：过半或 4 分钟兜底）', () {
    test('已知时长：过半有效、不足半无效', () {
      expect(ListenStatsDb.isValidPlay(100000, 200000), isTrue,
          reason: '恰好一半计入');
      expect(ListenStatsDb.isValidPlay(99999, 200000), isFalse);
      expect(ListenStatsDb.isValidPlay(200000, 200000), isTrue);
    });

    test('已知时长但不足半时 240s 兜底仍有效', () {
      // 10 分钟长曲只听了 4 分钟整：未过半但达到兜底线
      expect(ListenStatsDb.isValidPlay(240000, 600000), isTrue);
      expect(ListenStatsDb.isValidPlay(239999, 600000), isFalse);
    });

    test('时长 null 或 0：仅按 240s 兜底', () {
      expect(ListenStatsDb.isValidPlay(240000, null), isTrue);
      expect(ListenStatsDb.isValidPlay(239999, null), isFalse);
      expect(ListenStatsDb.isValidPlay(240000, 0), isTrue);
      expect(ListenStatsDb.isValidPlay(239999, 0), isFalse);
    });
  });

  group('跨账号隔离', () {
    test('切账号后计数隔离，切回后数据延续', () async {
      final client = KugouApiClient();
      await client.setLoginCookies('t', 'u1');
      await db.insertRecord(title: '歌一', playedMs: 1000, valid: true);
      expect(await db.countByUser(validOnly: false), 1);

      // 切到 u2：句柄级校验重开，写入落在 u2 名下
      await client.setLoginCookies('t', 'u2');
      await db.insertRecord(title: '歌二', playedMs: 2000, valid: true);
      await db.insertRecord(title: '歌三', playedMs: 3000, valid: false);
      expect(await db.countByUser(validOnly: false), 2,
          reason: 'u2 只看到自己的记录');
      expect(await db.countByUser(validOnly: true), 1);

      // 切回 u1：旧数据保留可延续
      await client.setLoginCookies('t', 'u1');
      expect(await db.countByUser(validOnly: false), 1);
    });

    test('resetForAccountSwitch 关闭句柄后按新账号统计正确', () async {
      final client = KugouApiClient();
      await client.setLoginCookies('t', 'u1');
      await db.insertRecord(title: '歌一', playedMs: 1000, valid: true);

      await db.resetForAccountSwitch();
      await client.setLoginCookies('t', 'u2');
      await db.insertRecord(title: '歌二', playedMs: 1000, valid: true);

      expect(await db.countByUser(validOnly: false), 1);
      await client.setLoginCookies('t', 'u1');
      expect(await db.countByUser(validOnly: false), 1);
    });
  });
}
