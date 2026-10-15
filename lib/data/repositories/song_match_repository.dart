import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// 本地歌曲与在线歌曲的匹配来源。
enum SongMatchSource {
  /// 自动匹配（扫描/启动后的高置信度搜索命中）。
  auto,

  /// 手动匹配（用户在候选列表中确认，优先级高于自动）。
  manual;

  String toJson() => name;

  static SongMatchSource fromJson(String? v) =>
      v == 'manual' ? SongMatchSource.manual : SongMatchSource.auto;
}

/// 一条本地歌曲 → 在线歌曲的匹配记忆。
///
/// 以本地歌曲 id（`local_<绝对路径>`）为键存储；[hash] 是匹配到的酷狗歌曲
/// hash，是歌词/评论/专辑跳转等在线能力的钥匙。
class SongMatchInfo {
  final String localId;
  final String hash;
  final String? albumAudioId;
  final String? songId;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumId;
  final String? artistId;
  final String? artworkUri;
  final int durationMs;
  final SongMatchSource source;

  /// 是否为用户主动否决：自动匹配永不覆盖该记录。
  final bool dismissed;

  /// 匹配成功时间（epoch 毫秒）。
  final int matchedAt;

  /// 最近一次自动匹配尝试时间（epoch 毫秒），用于冷却去重。
  final int attemptedAt;

  /// 单曲偏好：歌词改用在线匹配结果，覆盖内嵌/同目录歌词。
  /// 默认 false（本地优先）；仅这首歌曲自身生效，随匹配记录持久化。
  final bool preferOnlineLyrics;

  /// 单曲偏好：封面改用在线匹配结果，覆盖内嵌封面。
  /// 默认 false（本地优先）；仅这首歌曲自身生效，随匹配记录持久化。
  final bool preferOnlineCover;

  const SongMatchInfo({
    required this.localId,
    required this.hash,
    this.albumAudioId,
    this.songId,
    this.title,
    this.artist,
    this.album,
    this.albumId,
    this.artistId,
    this.artworkUri,
    this.durationMs = 0,
    this.source = SongMatchSource.auto,
    this.dismissed = false,
    this.matchedAt = 0,
    this.attemptedAt = 0,
    this.preferOnlineLyrics = false,
    this.preferOnlineCover = false,
  });

  factory SongMatchInfo.fromJson(String localId, Map<String, dynamic> json) {
    return SongMatchInfo(
      localId: localId,
      hash: (json['hash'] as String?) ?? '',
      albumAudioId: json['albumAudioId'] as String?,
      songId: json['songId'] as String?,
      title: json['title'] as String?,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      albumId: json['albumId'] as String?,
      artistId: json['artistId'] as String?,
      artworkUri: json['artworkUri'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      source: SongMatchSource.fromJson(json['source'] as String?),
      dismissed: (json['dismissed'] as bool?) ?? false,
      matchedAt: (json['matchedAt'] as num?)?.toInt() ?? 0,
      attemptedAt: (json['attemptedAt'] as num?)?.toInt() ?? 0,
      preferOnlineLyrics: (json['preferOnlineLyrics'] as bool?) ?? false,
      preferOnlineCover: (json['preferOnlineCover'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'hash': hash,
      'albumAudioId': albumAudioId,
      'songId': songId,
      'title': title,
      'artist': artist,
      'album': album,
      'albumId': albumId,
      'artistId': artistId,
      'artworkUri': artworkUri,
      'durationMs': durationMs,
      'source': source.toJson(),
      'dismissed': dismissed,
      'matchedAt': matchedAt,
      'attemptedAt': attemptedAt,
      'preferOnlineLyrics': preferOnlineLyrics,
      'preferOnlineCover': preferOnlineCover,
    };
  }

  SongMatchInfo copyWith({
    String? hash,
    String? albumAudioId,
    String? songId,
    String? title,
    String? artist,
    String? album,
    String? albumId,
    String? artistId,
    String? artworkUri,
    int? durationMs,
    SongMatchSource? source,
    bool? dismissed,
    int? matchedAt,
    int? attemptedAt,
    bool? preferOnlineLyrics,
    bool? preferOnlineCover,
  }) {
    return SongMatchInfo(
      localId: localId,
      hash: hash ?? this.hash,
      albumAudioId: albumAudioId ?? this.albumAudioId,
      songId: songId ?? this.songId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      artistId: artistId ?? this.artistId,
      artworkUri: artworkUri ?? this.artworkUri,
      durationMs: durationMs ?? this.durationMs,
      source: source ?? this.source,
      dismissed: dismissed ?? this.dismissed,
      matchedAt: matchedAt ?? this.matchedAt,
      attemptedAt: attemptedAt ?? this.attemptedAt,
      preferOnlineLyrics: preferOnlineLyrics ?? this.preferOnlineLyrics,
      preferOnlineCover: preferOnlineCover ?? this.preferOnlineCover,
    );
  }

  /// 是否存在有效匹配（有 hash 且未被否决）。
  bool get isMatched => !dismissed && hash.isNotEmpty;

  /// 构造对应的在线歌曲（用于评论/专辑页/试听等在线能力）。
  Song toSong() {
    return Song(
      id: hash,
      title: title ?? '',
      artist: artist ?? '',
      album: album ?? '',
      duration: Duration(milliseconds: durationMs),
      artworkUri: artworkUri,
      isOnline: true,
      albumId: albumId,
      artistId: artistId,
      albumAudioId: albumAudioId,
    );
  }
}

/// 本地歌曲 ↔ 在线歌曲匹配记忆的持久化仓库。
///
/// 与 [HistoryRepository] 同构：单例 + 内存缓存 + 防抖落盘。所有读取方
/// （评论解析、歌词 hash、封面兜底）走同步 [get]，首次使用前需 `ensureLoaded`。
class SongMatchRepository {
  static final SongMatchRepository _instance = SongMatchRepository._();
  factory SongMatchRepository() => _instance;
  SongMatchRepository._();

  static const String _storageKey = 'local_song_match_map';

  /// 落盘防抖：匹配写入不直接打磁盘，攒 5 秒合并写一次。
  static const Duration _flushDelay = Duration(seconds: 5);

  /// 自动匹配失败后的重试冷却：避免每次启动都对同一批无结果歌曲反复搜索。
  static const Duration attemptCooldown = Duration(days: 7);

  Map<String, SongMatchInfo>? _cache;
  Timer? _flushTimer;

  /// 仅测试用：清空内存缓存与防抖计时器，避免单例状态跨用例串味。
  @visibleForTesting
  static void debugResetForTest() {
    final self = _instance;
    self._flushTimer?.cancel();
    self._flushTimer = null;
    self._cache = null;
  }

  Future<Map<String, SongMatchInfo>> _load(SharedPreferences prefs) async {
    if (_cache != null) return _cache!;
    final raw = prefs.getString(_storageKey);
    final map = <String, SongMatchInfo>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            map[key] = SongMatchInfo.fromJson(key, value);
          }
        });
      } catch (_) {
        // 脏数据按空表处理，等待下次写入覆盖
      }
    }
    _cache = map;
    return map;
  }

  /// 确保内存缓存已就绪。同步读取入口（[get]）前必须先 await 本方法。
  Future<void> ensureLoaded() async {
    final prefs = await SharedPreferences.getInstance();
    await _load(prefs);
  }

  /// 同步查询（需先 [ensureLoaded]；未加载时返回 null 而非抛错）。
  SongMatchInfo? get(String localId) => _cache?[localId];

  /// 是否存在有效匹配（同步；需先 [ensureLoaded]）。
  bool isMatched(String localId) => _cache?[localId]?.isMatched ?? false;

  /// 全量视图（只读副本）。
  Future<Map<String, SongMatchInfo>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load(prefs);
    return Map.unmodifiable(map);
  }

  /// 写入一条匹配。manual 记录覆盖 auto；已 dismissed 的记录被新的
  /// manual 匹配复活（用户明确改选）。
  Future<void> put(SongMatchInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load(prefs);
    map[info.localId] = info;
    _scheduleFlush();
  }

  /// 记录一次自动匹配尝试（未命中时）：仅更新 attemptedAt 冷却时间戳，
  /// 不清除已有匹配。
  Future<void> markAttempted(String localId) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load(prefs);
    final existing = map[localId];
    map[localId] = (existing ?? SongMatchInfo(localId: localId, hash: ''))
        .copyWith(attemptedAt: DateTime.now().millisecondsSinceEpoch);
    _scheduleFlush();
  }

  /// 用户主动否决：清掉匹配内容但保留 dismissed 标记，自动匹配不再触碰；
  /// 手动改选（[put] manual）可复活。
  Future<void> dismiss(String localId) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load(prefs);
    map[localId] = (map[localId] ?? SongMatchInfo(localId: localId, hash: ''))
        .copyWith(dismissed: true, hash: '', matchedAt: 0);
    _scheduleFlush();
  }

  /// 彻底移除一条记录（自动匹配可重新尝试）。
  Future<void> remove(String localId) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load(prefs);
    map.remove(localId);
    _scheduleFlush();
  }

  /// 清空全部匹配记录（设置页「清除匹配记录」用）。
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    _cache = {};
    _flushTimer?.cancel();
    _flushTimer = null;
    await prefs.remove(_storageKey);
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, flush);
  }

  /// 立即落盘（防抖到期 / 测试断言前调用）。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final cache = _cache;
    if (cache == null) return;
    final prefs = await SharedPreferences.getInstance();
    // 单层编码：值直接放 Map（toJson），读回 _load 时是 Map<String, dynamic>
    await prefs.setString(
      _storageKey,
      jsonEncode(cache.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }
}
