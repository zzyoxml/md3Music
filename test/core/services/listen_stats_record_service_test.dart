import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:md3music/core/services/listen_stats_record_service.dart';
import 'package:md3music/core/services/playback_duration_tracker.dart';
import 'package:md3music/data/db/listen_stats_db.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 听歌统计播放记录服务：净时长结算、有效播放判定、本地歌记录、
/// 切歌配对、暂停/seek 不计时、同曲重复 start 幂等。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;
  late String dbPath;
  late ListenStatsDb db;
  late ListenStatsRecordService service;
  late int clockMs;

  Song onlineSong(String id, {String? mxid, Duration? duration}) {
    final mx = mxid ?? 'mx-$id';
    return Song(
      id: id,
      title: '歌$id',
      artist: '歌手$id',
      album: '专辑$id',
      duration: duration ?? const Duration(minutes: 3),
      isOnline: true,
      albumAudioId: mx,
    );
  }

  Song localSong(String id, {Duration? duration}) {
    return Song(
      id: 'local:///$id.flac',
      title: '本地$id',
      artist: '本地歌手$id',
      album: '本地专辑$id',
      duration: duration ?? const Duration(minutes: 3),
      isOnline: false,
      albumAudioId: null,
    );
  }

  /// 另开一条只读连接回读表内容（ListenStatsDb 未暴露行查询，
  /// 字段级断言走第二个连接；Windows 下多连接读空闲库安全）。
  Future<List<Map<String, Object?>>> rows() async {
    final reader = await databaseFactory.openDatabase(dbPath);
    final result = await reader.query('play_records');
    await reader.close();
    return result;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    await client.clearCookies();
    // 开关镜像是静态字段：跨用例必须复位，否则前一个用例关掉的开关
    // 会泄漏到后续用例（服务实例每用例新建，但镜像全局共享）。
    ListenStatsRecordService.recordingEnabled.value = true;
    // 全部用例走 dbPath 注入，绕开 path_provider 插件
    tmpDir = await Directory.systemTemp.createTemp('listen_stats_svc_test');
    dbPath = '${tmpDir.path}${Platform.pathSeparator}listen_stats.db';
    db = ListenStatsDb(dbPath: dbPath);
    clockMs = 1700000000000;
    // 每个用例独立实例（服务本体是单例，测试用构造注入 db + 假时钟）
    service = ListenStatsRecordService(
      db: db,
      tracker: PlaybackDurationTracker(nowMillis: () => clockMs),
    );
  });

  tearDown(() async {
    uninstallFakeSecureStorage();
    // Windows 文件锁：先关库再删临时目录
    await db.close();
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结论
    }
  });

  group('入库与有效播放判定', () {
    test('在线歌净播放过半 → 入库且 valid=true，字段与元数据一致', () async {
      // 3 分钟的歌恰好听满一半（90000ms）：Last.fm 口径 valid=true
      await service.onSongStarted(song: onlineSong('s1'), playing: true);
      clockMs += 90000;
      await service.onSongEnded(reason: PlaybackEndReason.completed);

      expect(await db.countByUser(validOnly: true), 1);
      expect(await db.countByUser(validOnly: false), 1);
      final row = (await rows()).single;
      expect(row['song_id'], 's1');
      expect(row['mixsongid'], 'mx-s1');
      expect(row['title'], '歌s1');
      expect(row['artist'], '歌手s1');
      expect(row['album'], '专辑s1');
      expect(row['duration_ms'], 180000);
      expect(row['played_ms'], 90000);
      expect(row['end_reason'], 'completed');
      expect(row['valid'], 1);
    });

    test('净播放未过半且不足 4 分钟 → 入库但 valid=false', () async {
      await service.onSongStarted(song: onlineSong('s2'), playing: true);
      clockMs += 30000;
      await service.onSongEnded();

      expect(await db.countByUser(validOnly: false), 1);
      expect(await db.countByUser(validOnly: true), 0);
      final row = (await rows()).single;
      expect(row['valid'], 0);
      expect(row['played_ms'], 30000);
    });

    test('未登录同样入库（空 user_id 下可回读）', () async {
      // setUp 未 setLoginCookies：ListenStatsDb 内部落空 user_id
      await service.onSongStarted(song: onlineSong('anon'), playing: true);
      clockMs += 90000;
      await service.onSongEnded();
      expect(await db.countByUser(validOnly: true), 1);
    });
  });

  group('本地歌记录', () {
    test('isOnline=false 且无 albumAudioId 的本地歌也入库（mixsongid 为空）',
        () async {
      // 10 分钟长曲听满 4 分钟兜底线：valid=true
      await service.onSongStarted(
        song: localSong('a', duration: const Duration(minutes: 10)),
        playing: true,
      );
      clockMs += 240000;
      await service.onSongEnded();

      expect(await db.countByUser(validOnly: true), 1);
      final row = (await rows()).single;
      expect(row['song_id'], 'local:///a.flac');
      expect(row['mixsongid'], isNull);
      expect(row['title'], '本地a');
      expect(row['valid'], 1);
    });
  });

  group('切歌配对', () {
    test('显式 end(switched) → start B：两段各自成记录', () async {
      await service.onSongStarted(song: onlineSong('A'), playing: true);
      clockMs += 30000;
      await service.onSongEnded(reason: PlaybackEndReason.switched);
      await service.onSongStarted(song: onlineSong('B'), playing: true);
      clockMs += 30000;
      await service.onSongEnded();

      final all = await rows();
      expect(all, hasLength(2));
      expect(all[0]['song_id'], 'A');
      expect(all[0]['end_reason'], 'switched');
      expect(all[0]['played_ms'], 30000);
      expect(all[1]['song_id'], 'B');
      expect(all[1]['end_reason'], 'completed');
    });

    test('不显式 end 直接 start B：A 段在 onSongStarted 内按 switched 结算',
        () async {
      await service.onSongStarted(song: onlineSong('A'), playing: true);
      clockMs += 30000;
      await service.onSongStarted(song: onlineSong('B'), playing: true);
      clockMs += 30000;
      await service.onSongEnded();

      final all = await rows();
      expect(all, hasLength(2));
      expect(all[0]['song_id'], 'A',
          reason: 'A 段元数据不被 B 覆盖（先取段再覆盖元数据）');
      expect(all[0]['title'], '歌A');
      expect(all[0]['end_reason'], 'switched');
      expect(all[1]['song_id'], 'B');
    });
  });

  group('计时口径', () {
    test('暂停期间不计时：20s 挂起只出声 6s → played_ms=6000', () async {
      await service.onSongStarted(song: onlineSong('p1'), playing: true);
      clockMs += 5000;
      service.onPlayingChanged(false);
      clockMs += 20000;
      service.onPlayingChanged(true);
      clockMs += 1000;
      await service.onSongEnded();

      final row = (await rows()).single;
      expect(row['played_ms'], 6000);
    });

    test('seek 不产生额外时长也不丢已播时长', () async {
      await service.onSongStarted(song: onlineSong('k1'), playing: true);
      clockMs += 5000;
      service.onSeek();
      clockMs += 1000;
      await service.onSongEnded();

      final row = (await rows()).single;
      expect(row['played_ms'], 6000);
    });

    test('同曲重复 start 幂等：不重置计段、只产生一条记录', () async {
      await service.onSongStarted(song: onlineSong('d1'), playing: true);
      clockMs += 10000;
      // 同一首歌重复 start（段尚未结算）：不应清零已累计时长
      await service.onSongStarted(song: onlineSong('d1'), playing: true);
      clockMs += 10000;
      await service.onSongEnded();

      final all = await rows();
      expect(all, hasLength(1));
      expect(all.single['played_ms'], 20000);
    });

    test('零净播放不落库', () async {
      // 缓冲中切歌（playing=false 登记，随后立即结算）：无净播放
      await service.onSongStarted(song: onlineSong('z1'), playing: false);
      await service.onSongEnded();
      // 注意不能用只读连接回读：全程无插入时表尚未建，改走计数口径
      expect(await db.countByUser(validOnly: false), 0);
    });
  });

  group('「听歌统计记录」开关', () {
    test('镜像关闭时 onSongStarted/onSongEnded 均不入库', () async {
      // 持久层与镜像同步关（镜像只在实例首次 start 时播种一次，
      // 之后不再回读；这里两处一致模拟设置页已关完的状态）
      SharedPreferences.setMockInitialValues({
        'settings_listen_stats_recording_enabled': false,
      });
      ListenStatsRecordService.recordingEnabled.value = false;
      await service.onSongStarted(song: onlineSong('off1'), playing: true);
      clockMs += 90000; // 即使够 Last.fm 口径也不记
      await service.onSongEnded();

      expect(await db.countByUser(validOnly: false), 0);
    });

    test('持久层预置关闭 → 首次 start 播种镜像并 no-op', () async {
      SharedPreferences.setMockInitialValues({
        'settings_listen_stats_recording_enabled': false,
      });
      // 新建服务实例走真实播种路径（syncRecordingEnabledFromPrefs 每实例一次）
      final seeded = ListenStatsRecordService(
        db: db,
        tracker: PlaybackDurationTracker(nowMillis: () => clockMs),
      );
      await seeded.onSongStarted(song: onlineSong('seed1'), playing: true);
      clockMs += 90000;
      await seeded.onSongEnded();
      expect(await db.countByUser(validOnly: false), 0);
    });

    test('收听中途关开关：当前段结算但不入库（用户关闭意图优先）', () async {
      await service.onSongStarted(song: onlineSong('mid1'), playing: true);
      clockMs += 60000;
      // 模拟设置页关闭开关：先写镜像再 discard（与 settings_page 同序）
      ListenStatsRecordService.recordingEnabled.value = false;
      service.discard();
      await service.onSongEnded();
      expect(await db.countByUser(validOnly: false), 0);

      // 重新打开后恢复正常入库
      ListenStatsRecordService.recordingEnabled.value = true;
      await service.onSongStarted(song: onlineSong('mid2'), playing: true);
      clockMs += 90000;
      await service.onSongEnded();
      expect(await db.countByUser(validOnly: false), 1);
      final row = (await rows()).single;
      expect(row['song_id'], 'mid2');
    });

    test('关闭期间不 start 段：重开后不把关闭间隔补记进新歌', () async {
      await service.onSongStarted(song: onlineSong('gap1'), playing: true);
      clockMs += 30000;
      await service.onSongEnded(reason: PlaybackEndReason.switched);
      ListenStatsRecordService.recordingEnabled.value = false;
      // 关闭期间切歌：no-op，不登记计时段
      await service.onSongStarted(song: onlineSong('gap2'), playing: true);
      clockMs += 120000;
      ListenStatsRecordService.recordingEnabled.value = true;
      await service.onSongEnded();

      // 只有 gap1 一条；gap2 段从未开启，关闭期间时长不得借尸还魂
      final all = await rows();
      expect(all, hasLength(1));
      expect(all.single['song_id'], 'gap1');
      expect(all.single['played_ms'], 30000);
    });
  });
}
