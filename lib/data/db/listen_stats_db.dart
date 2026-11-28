import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, OpenDatabaseOptions, databaseFactoryFfi, sqfliteFfiInit;

import '../../services/kugou_api/kugou_api_client.dart';

bool _dbFactoryReady = false;

/// 确保 sqflite 数据库工厂在当前平台可用。
///
/// - Web：不支持 sqflite 本地库，直接返回（调用方不应在 Web 使用听歌统计）。
/// - Windows/Linux 桌面：sqflite 无原生插件，改用 FFI 实现
///   （`sqfliteFfiInit()` 注册 sqlite3 动态库查找逻辑，并把全局
///   [databaseFactory] 换成 `databaseFactoryFfi`）。
/// - Android/iOS 移动端：sqflite 自带平台实现，不做任何改动。
///
/// 幂等：工厂切换只执行一次，重复调用直接返回。
Future<void> ensureDbFactory() async {
  if (kIsWeb) return;
  if (_dbFactoryReady) return;
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _dbFactoryReady = true;
  }
  // 移动端无需处理：sqflite 平台实现即默认工厂。
}

/// 听歌统计本地数据库（SQLite，非单例）。
///
/// 每条播放记录带 `user_id` 实现账号隔离：写入时实时取当前酷狗账号，
/// 查询按当前账号过滤；跨账号数据保留在同一库中，切回账号统计可延续。
///
/// 与 [HistoryRepository] 不同，这里没有内存缓存/单例约束，
/// 允许多实例（测试通过 [ListenStatsDb] 注入临时路径绕开 path_provider）。
class ListenStatsDb {
  ListenStatsDb({String? dbPath}) : _dbPathOverride = dbPath;

  /// 测试注入的库文件路径；null 时使用应用支持目录下的默认路径。
  final String? _dbPathOverride;

  Database? _db;

  /// 当前句柄归属的账号（开库时记录，操作前校验）。
  String? _dbUser;

  String get _userId {
    final uid = KugouApiClient().userid;
    return (uid == null || uid.isEmpty) ? '' : uid;
  }

  /// 默认库路径：应用支持目录/listen_stats.db（与播放游标文件同目录策略，
  /// 参考 player_state_repository.dart 的 _cursorFile）。
  Future<String> _defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}listen_stats.db';
  }

  /// 懒开库：首次操作时打开；账号变化则关闭旧句柄重开。
  Future<Database> _open() async {
    final user = _userId;
    if (_db != null) {
      if (_dbUser == user) return _db!;
      // 句柄级校验：登录态切换后旧句柄归属已过期，关闭重开，
      // 避免把 A 账号的写入/查询落在 B 账号的会话上。
      await _db!.close();
      _db = null;
      _dbUser = null;
    }
    await ensureDbFactory();
    final path = _dbPathOverride ?? await _defaultPath();
    _db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: _onCreate,
      ),
    );
    _dbUser = user;
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE play_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        song_id TEXT,
        mixsongid TEXT,
        title TEXT NOT NULL,
        artist TEXT,
        album TEXT,
        duration_ms INTEGER,
        played_ms INTEGER NOT NULL,
        played_at INTEGER NOT NULL,
        end_reason TEXT,
        valid INTEGER NOT NULL
      )
    ''');
    // 常用查询形态：按账号按时间范围/倒序取记录
    await db.execute(
      'CREATE INDEX idx_play_records_user_time '
      'ON play_records(user_id, played_at)',
    );
    // 有效播放统计：按账号过滤 valid 后计数/聚合
    await db.execute(
      'CREATE INDEX idx_play_records_user_valid_time '
      'ON play_records(user_id, valid, played_at)',
    );
  }

  /// 写入一条播放记录。
  ///
  /// [playedAt] 缺省取当前毫秒时间戳；`user_id` 在写入瞬间实时取当前账号。
  Future<void> insertRecord({
    String? songId,
    String? mixsongid,
    required String title,
    String? artist,
    String? album,
    int? durationMs,
    required int playedMs,
    int? playedAt,
    String? endReason,
    required bool valid,
  }) async {
    final db = await _open();
    await db.insert('play_records', <String, Object?>{
      'user_id': _userId,
      'song_id': songId,
      'mixsongid': mixsongid,
      'title': title,
      'artist': artist,
      'album': album,
      'duration_ms': durationMs,
      'played_ms': playedMs,
      'played_at': playedAt ?? DateTime.now().millisecondsSinceEpoch,
      'end_reason': endReason,
      'valid': valid ? 1 : 0,
    });
  }

  /// 统计当前账号的记录条数。[validOnly] 为 true 时只数有效播放。
  Future<int> countByUser({required bool validOnly}) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM play_records '
      'WHERE user_id = ?${validOnly ? ' AND valid = 1' : ''}',
      <Object?>[_userId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 关闭数据库句柄（幂等，已关闭时为 no-op）。
  Future<void> close() async {
    final db = _db;
    if (db == null) return;
    _db = null;
    _dbUser = null;
    await db.close();
  }

  /// 账号切换时的显式重置钩子：关闭当前句柄，下一次操作会按新账号重开。
  ///
  /// 不删除任何数据——账号隔离依赖 `user_id` 字段过滤，各账号的统计
  /// 各自保留，切回账号后可延续。这里只负责丢弃可能过期归属的句柄。
  Future<void> resetForAccountSwitch() async {
    await close();
  }

  // ==================== 聚合查询（听歌统计页数据源） ====================
  //
  // 全部带 user_id 过滤（走 [KugouApiClient.userid]，与写入同一账号口径），
  // 时间范围为左闭右开 [startMs, endMs)，[validOnly] 控制是否只算有效播放。

  /// 拼装公共过滤条件（账号 + 有效 + 时间窗）。
  /// 返回 (where 片段, 位置参数)，由各查询自行嵌入 SQL。
  (String, List<Object?>) _rangeCond({
    int? startMs,
    int? endMs,
    bool validOnly = true,
  }) {
    final sb = StringBuffer('user_id = ?');
    final args = <Object?>[_userId];
    if (validOnly) sb.write(' AND valid = 1');
    if (startMs != null) {
      sb.write(' AND played_at >= ?');
      args.add(startMs);
    }
    if (endMs != null) {
      sb.write(' AND played_at < ?');
      args.add(endMs);
    }
    return (sb.toString(), args);
  }

  /// Top 榜通用实现：按 [column]（title/artist/album）GROUP BY 聚合。
  ///
  /// - 排序：count DESC、sum(played_ms) DESC，末位以 key 升序保证确定性；
  /// - artist/album 为 NULL 或空串的记录**归入 [unknownLabel] 桶**
  ///   （"未知艺人"/"未知专辑"）而非排除，保证总次数/时长口径完整，
  ///   并在返回行 `isUnknown = true` 标记；
  /// - 每行附带"代表曲目"元数据（repTitle/repArtist）：该组内累计净播放
  ///   时长最长的一首歌（并列取最近播放），UI 展示"歌手 - 代表作"用。
  Future<List<Map<String, Object?>>> _topBy({
    required String column,
    String? unknownLabel,
    required int? startMs,
    required int? endMs,
    required int limit,
    required bool validOnly,
  }) async {
    assert(
      column == 'title' || column == 'artist' || column == 'album',
      '聚合维度仅限 title/artist/album',
    );
    final db = await _open();
    final (cond, args) =
        _rangeCond(startMs: startMs, endMs: endMs, validOnly: validOnly);
    final rows = await db.rawQuery(
      'SELECT $column AS bucket, COUNT(*) AS cnt, '
      'COALESCE(SUM(played_ms), 0) AS total_ms '
      'FROM play_records WHERE $cond GROUP BY $column',
      args,
    );
    // NULL/空串归桶在 Dart 侧合并（避免 SQL 占位符顺序与 NULL 分组的麻烦）：
    // 同名桶（如 artist 的 NULL 行与 '' 行）合并计数并置 unknown 标记。
    final merged = <String, ({int count, int playedMs, bool unknown})>{};
    for (final r in rows) {
      final raw = r['bucket'] as String?;
      final isUnknown =
          unknownLabel != null && (raw == null || raw.trim().isEmpty);
      if (raw == null && !isUnknown) continue; // title 维度理论不出现，防御
      final key = isUnknown ? unknownLabel : raw!;
      final cnt = r['cnt'] as int;
      final totalMs = r['total_ms'] as int;
      final prev = merged[key];
      merged[key] = prev == null
          ? (count: cnt, playedMs: totalMs, unknown: isUnknown)
          : (
              count: prev.count + cnt,
              playedMs: prev.playedMs + totalMs,
              unknown: prev.unknown || isUnknown,
            );
    }
    final keys = merged.keys.toList()
      ..sort((a, b) {
        final byCount = merged[b]!.count.compareTo(merged[a]!.count);
        if (byCount != 0) return byCount;
        final byMs = merged[b]!.playedMs.compareTo(merged[a]!.playedMs);
        if (byMs != 0) return byMs;
        return a.compareTo(b);
      });
    final result = <Map<String, Object?>>[];
    for (final key in keys.take(limit)) {
      final agg = merged[key]!;
      // unknown 桶的原始值是 NULL/空串，代表曲目按"该列缺失"条件取
      final rep = await _repTrack(
        column: column,
        rawKey: agg.unknown ? null : key,
        cond: cond,
        args: args,
      );
      result.add(<String, Object?>{
        'key': key,
        'count': agg.count,
        'playedMs': agg.playedMs,
        'repTitle': rep?['title'] as String?,
        'repArtist': rep?['artist'] as String?,
        'isUnknown': agg.unknown,
      });
    }
    return result;
  }

  /// 取某分组下"代表曲目"：组内按 title 再聚合，取净播放时长最长的一首
  /// （并列取最近播放）。[rawKey] 为 null 表示 NULL/空串桶。
  Future<Map<String, Object?>?> _repTrack({
    required String column,
    required String? rawKey,
    required String cond,
    required List<Object?> args,
  }) async {
    final db = await _open();
    final keyCond = rawKey == null
        ? "($column IS NULL OR TRIM($column) = '')"
        : '$column = ?';
    final rows = await db.rawQuery(
      'SELECT title, artist FROM play_records '
      'WHERE $cond AND $keyCond '
      'GROUP BY title ORDER BY SUM(played_ms) DESC, MAX(played_at) DESC LIMIT 1',
      rawKey == null ? args : <Object?>[...args, rawKey],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 按曲目聚合的 Top 榜（key=曲名，count=次数，playedMs=净时长，
  /// repArtist=代表演唱者）。
  Future<List<Map<String, Object?>>> topTracks({
    int? startMs,
    int? endMs,
    int limit = 10,
    bool validOnly = true,
  }) {
    return _topBy(
      column: 'title',
      startMs: startMs,
      endMs: endMs,
      limit: limit,
      validOnly: validOnly,
    );
  }

  /// 按艺人聚合的 Top 榜（NULL/空艺人归"未知艺人"桶并标记 isUnknown，
  /// repTitle=代表作）。
  Future<List<Map<String, Object?>>> topArtists({
    int? startMs,
    int? endMs,
    int limit = 10,
    bool validOnly = true,
  }) {
    return _topBy(
      column: 'artist',
      unknownLabel: '未知艺人',
      startMs: startMs,
      endMs: endMs,
      limit: limit,
      validOnly: validOnly,
    );
  }

  /// 按专辑聚合的 Top 榜（NULL/空专辑归"未知专辑"桶并标记 isUnknown，
  /// repTitle=代表曲目）。
  Future<List<Map<String, Object?>>> topAlbums({
    int? startMs,
    int? endMs,
    int limit = 10,
    bool validOnly = true,
  }) {
    return _topBy(
      column: 'album',
      unknownLabel: '未知专辑',
      startMs: startMs,
      endMs: endMs,
      limit: limit,
      validOnly: validOnly,
    );
  }

  /// 按月聚合（month 为 yyyyMM 整数，升序）。日期取本地时区
  /// （sqlite `strftime(..., 'localtime')`），与用户直觉的"自然月"一致。
  Future<List<({int month, int count, int playedMs})>> monthlyTrends({
    int? startMs,
    int? endMs,
    bool validOnly = true,
  }) async {
    final db = await _open();
    final (cond, args) =
        _rangeCond(startMs: startMs, endMs: endMs, validOnly: validOnly);
    final rows = await db.rawQuery(
      "SELECT strftime('%Y%m', played_at / 1000, 'unixepoch', 'localtime') AS ym, "
      'COUNT(*) AS cnt, COALESCE(SUM(played_ms), 0) AS total_ms '
      'FROM play_records WHERE $cond '
      'GROUP BY ym ORDER BY ym ASC',
      args,
    );
    return <({int month, int count, int playedMs})>[
      for (final r in rows)
        (
          month: int.parse(r['ym']! as String),
          count: r['cnt'] as int,
          playedMs: r['total_ms'] as int,
        ),
    ];
  }

  /// 总览数值：总次数 / 总净时长 / 活跃天数（有播放的自然日数，本地时区）/
  /// 曲目数（按曲名去重）/ 艺人数（NULL/空艺人计为"未知"一档）。
  Future<
      ({
        int plays,
        int playedMs,
        int activeDays,
        int distinctTracks,
        int distinctArtists,
      })> overview({
    int? startMs,
    int? endMs,
    bool validOnly = true,
  }) async {
    final db = await _open();
    final (cond, args) =
        _rangeCond(startMs: startMs, endMs: endMs, validOnly: validOnly);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS plays, '
      'COALESCE(SUM(played_ms), 0) AS total_ms, '
      "COUNT(DISTINCT date(played_at / 1000, 'unixepoch', 'localtime')) AS active_days, "
      'COUNT(DISTINCT title) AS distinct_tracks, '
      "COUNT(DISTINCT COALESCE(NULLIF(TRIM(artist), ''), '')) AS distinct_artists "
      'FROM play_records WHERE $cond',
      args,
    );
    final r = rows.first;
    return (
      plays: r['plays'] as int,
      playedMs: r['total_ms'] as int,
      activeDays: r['active_days'] as int,
      distinctTracks: r['distinct_tracks'] as int,
      distinctArtists: r['distinct_artists'] as int,
    );
  }

  /// 最长连续收听天数（有至少一次播放的自然日连续段的最大长度）。
  ///
  /// 先取去重日期列表（已排序），在 Dart 侧线性扫描计连续段——比纯 SQL
  /// 窗口函数简单可靠（移动端 SQLite 版本参差）。
  Future<int> longestStreak({
    int? startMs,
    int? endMs,
    bool validOnly = true,
  }) async {
    final db = await _open();
    final (cond, args) =
        _rangeCond(startMs: startMs, endMs: endMs, validOnly: validOnly);
    final rows = await db.rawQuery(
      "SELECT DISTINCT date(played_at / 1000, 'unixepoch', 'localtime') AS d "
      'FROM play_records WHERE $cond ORDER BY d ASC',
      args,
    );
    var best = 0;
    var cur = 0;
    DateTime? prev;
    for (final r in rows) {
      final s = r['d']! as String; // 'YYYY-MM-DD'
      // 用 UTC 构造纯日历日：本地午夜相减跨夏令时会得到 23/25 小时，
      // inDays 取整后误判；UTC 日期差恒为 24h 整数倍。
      final day = DateTime.utc(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(5, 7)),
        int.parse(s.substring(8, 10)),
      );
      cur = (prev != null && day.difference(prev).inDays == 1) ? cur + 1 : 1;
      if (cur > best) best = cur;
      prev = day;
    }
    return best;
  }

  /// "重逢"次数：同一曲目与上一次播放间隔 ≥ [minGapDays] 天的再听次数
  /// （简单口径：范围内的每次间隔达标即计一次，够 UI 展示用）。
  Future<int> rediscovery({
    int minGapDays = 7,
    int? startMs,
    int? endMs,
    bool validOnly = true,
  }) async {
    final db = await _open();
    final (cond, args) =
        _rangeCond(startMs: startMs, endMs: endMs, validOnly: validOnly);
    final rows = await db.rawQuery(
      'SELECT title, played_at FROM play_records WHERE $cond '
      'ORDER BY title ASC, played_at ASC',
      args,
    );
    final gapMs = minGapDays * 86400000;
    var count = 0;
    String? curTitle;
    int? prevAt;
    for (final r in rows) {
      final title = r['title']! as String;
      final at = r['played_at']! as int;
      if (title == curTitle && prevAt != null && at - prevAt >= gapMs) {
        count++;
      }
      curTitle = title;
      prevAt = at;
    }
    return count;
  }

  /// 判断一次播放是否计入有效收听（Last.fm 口径）。
  ///
  /// 规则：已知时长（>0）时播放时长过半即有效；时长未知/异常时
  /// 以累计播放 4 分钟（240000ms）兜底——短歌听不满半长但持续
  /// 收听超过 4 分钟同样应计一次。
  static bool isValidPlay(int playedMs, int? durationMs) {
    if (durationMs != null && durationMs > 0) {
      if (playedMs >= durationMs * 0.5) return true;
    }
    return playedMs >= 240000;
  }
}
