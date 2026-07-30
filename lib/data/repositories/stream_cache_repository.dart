import 'dart:convert';
import 'dart:io';

import '../models/song.dart';

/// 缓存索引根结构，对应 `<cacheDir>/index.json` 文件
class CacheIndex {
  /// 版本号，固定为 1，用于后续兼容性升级
  final int version;
  /// 条目集合，key = song hash
  final Map<String, CacheEntry> entries;

  const CacheIndex({required this.version, required this.entries});

  factory CacheIndex.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'] as Map<String, dynamic>? ?? {};
    final entries = <String, CacheEntry>{};
    rawEntries.forEach((key, value) {
      entries[key] = CacheEntry.fromJson(value as Map<String, dynamic>);
    });
    return CacheIndex(
      version: (json['version'] as num?)?.toInt() ?? 1,
      entries: entries,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'entries': entries.map((key, value) => MapEntry(key, value.toJson())),
    };
  }
}

/// 单首歌曲的缓存条目，包含元数据、音频/歌词/封面的缓存信息
class CacheEntry {
  final SongMetadata? song;
  /// 音频缓存，key = quality ('128'/'320'/'flac'/'high')
  final Map<String, AudioCacheInfo> audio;
  final LyricsCacheInfo? lyrics;
  final ArtworkCacheInfo? artwork;

  const CacheEntry({
    this.song,
    required this.audio,
    this.lyrics,
    this.artwork,
  });

  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    final rawAudio = json['audio'] as Map<String, dynamic>? ?? {};
    final audio = <String, AudioCacheInfo>{};
    rawAudio.forEach((key, value) {
      audio[key] = AudioCacheInfo.fromJson(value as Map<String, dynamic>);
    });
    return CacheEntry(
      song: json['song'] != null
          ? SongMetadata.fromJson(json['song'] as Map<String, dynamic>)
          : null,
      audio: audio,
      lyrics: json['lyrics'] != null
          ? LyricsCacheInfo.fromJson(json['lyrics'] as Map<String, dynamic>)
          : null,
      artwork: json['artwork'] != null
          ? ArtworkCacheInfo.fromJson(json['artwork'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'song': song?.toJson(),
      'audio': audio.map((key, value) => MapEntry(key, value.toJson())),
      'lyrics': lyrics?.toJson(),
      'artwork': artwork?.toJson(),
    };
  }
}

/// 歌曲元数据，由 Song 转换而来用于持久化
class SongMetadata {
  final String id;
  final String title;
  final String artist;
  final String album;
  /// 时长（毫秒），对应 Song.duration.inMilliseconds
  final int durationMs;
  final String? albumId;
  final String? artistId;
  final String? albumAudioId;
  final double? climaxStart;
  final double? climaxEnd;
  final String? artworkUri;

  const SongMetadata({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    this.albumId,
    this.artistId,
    this.albumAudioId,
    this.climaxStart,
    this.climaxEnd,
    this.artworkUri,
  });

  factory SongMetadata.fromJson(Map<String, dynamic> json) {
    return SongMetadata(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String,
      durationMs: (json['durationMs'] as num).toInt(),
      albumId: json['albumId'] as String?,
      artistId: json['artistId'] as String?,
      albumAudioId: json['albumAudioId'] as String?,
      climaxStart: (json['climaxStart'] as num?)?.toDouble(),
      climaxEnd: (json['climaxEnd'] as num?)?.toDouble(),
      artworkUri: json['artworkUri'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'durationMs': durationMs,
      'albumId': albumId,
      'artistId': artistId,
      'albumAudioId': albumAudioId,
      'climaxStart': climaxStart,
      'climaxEnd': climaxEnd,
      'artworkUri': artworkUri,
    };
  }
}

/// 音频文件缓存信息
class AudioCacheInfo {
  /// 相对路径，如 `audio/<hash>_<quality>.mp3`
  final String path;
  /// 文件字节数
  final int size;
  /// 扩展名：'mp3' 或 'flac'
  final String ext;
  /// 首次缓存时间（ISO8601）
  final String cachedAt;
  /// 最后访问时间（ISO8601），用于 LRU 淘汰
  final String lastAccessedAt;

  const AudioCacheInfo({
    required this.path,
    required this.size,
    required this.ext,
    required this.cachedAt,
    required this.lastAccessedAt,
  });

  factory AudioCacheInfo.fromJson(Map<String, dynamic> json) {
    return AudioCacheInfo(
      path: json['path'] as String,
      size: (json['size'] as num).toInt(),
      ext: json['ext'] as String,
      cachedAt: json['cachedAt'] as String,
      lastAccessedAt: json['lastAccessedAt'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'size': size,
      'ext': ext,
      'cachedAt': cachedAt,
      'lastAccessedAt': lastAccessedAt,
    };
  }
}

/// 歌词缓存信息
class LyricsCacheInfo {
  /// 相对路径，如 `lyrics/<hash>.json`
  final String path;
  final int size;
  final String cachedAt;
  final String lastAccessedAt;

  const LyricsCacheInfo({
    required this.path,
    required this.size,
    required this.cachedAt,
    required this.lastAccessedAt,
  });

  factory LyricsCacheInfo.fromJson(Map<String, dynamic> json) {
    return LyricsCacheInfo(
      path: json['path'] as String,
      size: (json['size'] as num).toInt(),
      cachedAt: json['cachedAt'] as String,
      lastAccessedAt: json['lastAccessedAt'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'size': size,
      'cachedAt': cachedAt,
      'lastAccessedAt': lastAccessedAt,
    };
  }
}

/// 封面缓存信息
class ArtworkCacheInfo {
  /// 相对路径，如 `artwork/<hash>.jpg`
  final String path;
  final int size;
  /// 扩展名，如 'jpg'/'png'
  final String ext;
  final String cachedAt;
  final String lastAccessedAt;

  const ArtworkCacheInfo({
    required this.path,
    required this.size,
    required this.ext,
    required this.cachedAt,
    required this.lastAccessedAt,
  });

  factory ArtworkCacheInfo.fromJson(Map<String, dynamic> json) {
    return ArtworkCacheInfo(
      path: json['path'] as String,
      size: (json['size'] as num).toInt(),
      ext: json['ext'] as String,
      cachedAt: json['cachedAt'] as String,
      lastAccessedAt: json['lastAccessedAt'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'size': size,
      'ext': ext,
      'cachedAt': cachedAt,
      'lastAccessedAt': lastAccessedAt,
    };
  }
}

/// 边听边存功能的缓存索引持久化仓库（单例）
class StreamCacheRepository {
  StreamCacheRepository._();
  static final StreamCacheRepository instance = StreamCacheRepository._();

  /// 缓存根目录，由 StreamCacheManager 在初始化时设置
  Directory? _cacheDir;
  /// 内存索引
  CacheIndex _index = CacheIndex(version: 1, entries: {});
  /// 是否已加载索引文件
  bool _loaded = false;

  /// 设置缓存根目录（由 StreamCacheManager 调用）
  Future<void> setCacheDir(Directory dir) async {
    _cacheDir = dir;
    await _ensureIndexLoaded();
  }

  /// 暴露当前索引（只读用途）
  CacheIndex get currentIndex => _index;

  /// 首次访问时从 `<cacheDir>/index.json` 加载索引；文件不存在则用空索引
  Future<void> _ensureIndexLoaded() async {
    if (_loaded) return;
    if (_cacheDir == null) return;
    final indexFile = _indexFile();
    if (await indexFile.exists()) {
      try {
        final content = await indexFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _index = CacheIndex.fromJson(json);
      } catch (e) {
        // 解析失败时使用空索引，避免阻塞后续流程
        _index = CacheIndex(version: 1, entries: {});
      }
    } else {
      _index = CacheIndex(version: 1, entries: {});
    }
    _loaded = true;
  }

  File _indexFile() {
    return File('${_cacheDir!.path}${Platform.pathSeparator}index.json');
  }

  File _indexTmpFile() {
    return File('${_cacheDir!.path}${Platform.pathSeparator}index.json.tmp');
  }

  /// 原子写入：先写 .tmp 再 rename 为 index.json，避免崩溃丢数据
  Future<void> _saveIndex() async {
    if (_cacheDir == null) return;
    // 确保缓存目录存在（防止目录被系统清理或初始化遗漏）
    try {
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
    } catch (_) {
      // 目录创建失败（如外部存储被系统回收），跳过保存
      return;
    }
    final indexFile = _indexFile();
    final tmpFile = _indexTmpFile();
    try {
      await tmpFile.writeAsString(jsonEncode(_index.toJson()));
      await tmpFile.rename(indexFile.path);
    } catch (e) {
      // rename 失败时尝试用 writeAsString 直接写入（跨文件系统 rename 可能失败）
      try {
        await indexFile.writeAsString(jsonEncode(_index.toJson()));
      } catch (e2) {
        // 保存失败仅打印日志，不抛出
        // ignore: avoid_print
        print('[StreamCacheRepository] _saveIndex 失败: $e2');
      }
    }
  }

  /// 返回指定 hash 的条目，不存在返回 null
  CacheEntry? getEntry(String hash) {
    return _index.entries[hash];
  }

  /// 更新或插入条目，设置 song 字段
  Future<void> upsertSongMetadata(String hash, Song song) async {
    await _ensureIndexLoaded();
    final metadata = SongMetadata(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      durationMs: song.duration.inMilliseconds,
      albumId: song.albumId,
      artistId: song.artistId,
      albumAudioId: song.albumAudioId,
      climaxStart: song.climaxStart,
      climaxEnd: song.climaxEnd,
      artworkUri: song.artworkUri,
    );
    final entry = _index.entries[hash];
    if (entry == null) {
      _index.entries[hash] = CacheEntry(song: metadata, audio: {});
    } else {
      // 保留原 audio/lyrics/artwork，仅替换 song 字段
      _index.entries[hash] = CacheEntry(
        song: metadata,
        audio: Map<String, AudioCacheInfo>.from(entry.audio),
        lyrics: entry.lyrics,
        artwork: entry.artwork,
      );
    }
    await _saveIndex();
  }

  /// 更新条目的 audio[quality] = info
  /// 若旧 quality 与新 quality 不同，不自动删除旧文件（由 StreamCacheManager 处理）
  Future<void> upsertAudioEntry(
    String hash,
    String quality,
    AudioCacheInfo info,
  ) async {
    await _ensureIndexLoaded();
    final entry = _index.entries[hash];
    if (entry == null) {
      _index.entries[hash] = CacheEntry(
        song: null,
        audio: {quality: info},
      );
    } else {
      final newAudio = Map<String, AudioCacheInfo>.from(entry.audio);
      newAudio[quality] = info;
      _index.entries[hash] = CacheEntry(
        song: entry.song,
        audio: newAudio,
        lyrics: entry.lyrics,
        artwork: entry.artwork,
      );
    }
    await _saveIndex();
  }

  /// 更新歌词缓存信息
  Future<void> upsertLyricsEntry(String hash, LyricsCacheInfo info) async {
    await _ensureIndexLoaded();
    final entry = _index.entries[hash];
    if (entry == null) {
      _index.entries[hash] = CacheEntry(
        song: null,
        audio: {},
        lyrics: info,
      );
    } else {
      _index.entries[hash] = CacheEntry(
        song: entry.song,
        audio: Map<String, AudioCacheInfo>.from(entry.audio),
        lyrics: info,
        artwork: entry.artwork,
      );
    }
    await _saveIndex();
  }

  /// 更新封面缓存信息
  Future<void> upsertArtworkEntry(String hash, ArtworkCacheInfo info) async {
    await _ensureIndexLoaded();
    final entry = _index.entries[hash];
    if (entry == null) {
      _index.entries[hash] = CacheEntry(
        song: null,
        audio: {},
        artwork: info,
      );
    } else {
      _index.entries[hash] = CacheEntry(
        song: entry.song,
        audio: Map<String, AudioCacheInfo>.from(entry.audio),
        lyrics: entry.lyrics,
        artwork: info,
      );
    }
    await _saveIndex();
  }

  /// 删除整个条目（仅删索引，文件由 StreamCacheManager 删）
  Future<void> removeEntry(String hash) async {
    await _ensureIndexLoaded();
    _index.entries.remove(hash);
    await _saveIndex();
  }

  /// 删除条目内指定音质的音频记录
  Future<void> removeAudioEntry(String hash, String quality) async {
    await _ensureIndexLoaded();
    final entry = _index.entries[hash];
    if (entry == null) return;
    if (!entry.audio.containsKey(quality)) return;
    final newAudio = Map<String, AudioCacheInfo>.from(entry.audio);
    newAudio.remove(quality);
    _index.entries[hash] = CacheEntry(
      song: entry.song,
      audio: newAudio,
      lyrics: entry.lyrics,
      artwork: entry.artwork,
    );
    await _saveIndex();
  }

  /// 更新 audio[quality].lastAccessedAt 为当前时间
  Future<void> touchAudio(String hash, String quality) async {
    await _ensureIndexLoaded();
    final entry = _index.entries[hash];
    if (entry == null) return;
    final audio = entry.audio[quality];
    if (audio == null) return;
    final newAudio = Map<String, AudioCacheInfo>.from(entry.audio);
    newAudio[quality] = AudioCacheInfo(
      path: audio.path,
      size: audio.size,
      ext: audio.ext,
      cachedAt: audio.cachedAt,
      lastAccessedAt: DateTime.now().toIso8601String(),
    );
    _index.entries[hash] = CacheEntry(
      song: entry.song,
      audio: newAudio,
      lyrics: entry.lyrics,
      artwork: entry.artwork,
    );
    await _saveIndex();
  }

  /// 更新 lyrics.lastAccessedAt
  Future<void> touchLyrics(String hash) async {
    await _ensureIndexLoaded();
    final entry = _index.entries[hash];
    if (entry == null) return;
    final lyrics = entry.lyrics;
    if (lyrics == null) return;
    _index.entries[hash] = CacheEntry(
      song: entry.song,
      audio: Map<String, AudioCacheInfo>.from(entry.audio),
      lyrics: LyricsCacheInfo(
        path: lyrics.path,
        size: lyrics.size,
        cachedAt: lyrics.cachedAt,
        lastAccessedAt: DateTime.now().toIso8601String(),
      ),
      artwork: entry.artwork,
    );
    await _saveIndex();
  }

  /// 更新 artwork.lastAccessedAt
  Future<void> touchArtwork(String hash) async {
    await _ensureIndexLoaded();
    final entry = _index.entries[hash];
    if (entry == null) return;
    final artwork = entry.artwork;
    if (artwork == null) return;
    _index.entries[hash] = CacheEntry(
      song: entry.song,
      audio: Map<String, AudioCacheInfo>.from(entry.audio),
      lyrics: entry.lyrics,
      artwork: ArtworkCacheInfo(
        path: artwork.path,
        size: artwork.size,
        ext: artwork.ext,
        cachedAt: artwork.cachedAt,
        lastAccessedAt: DateTime.now().toIso8601String(),
      ),
    );
    await _saveIndex();
  }

  /// 遍历所有条目累加 audio/lyrics/artwork 的 size
  int getTotalBytes() {
    int total = 0;
    for (final entry in _index.entries.values) {
      for (final audio in entry.audio.values) {
        total += audio.size;
      }
      if (entry.lyrics != null) total += entry.lyrics!.size;
      if (entry.artwork != null) total += entry.artwork!.size;
    }
    return total;
  }

  /// 统计所有音频字节数
  int getAudioBytes() {
    int total = 0;
    for (final entry in _index.entries.values) {
      for (final audio in entry.audio.values) {
        total += audio.size;
      }
    }
    return total;
  }

  /// 统计所有歌词字节数
  int getLyricsBytes() {
    int total = 0;
    for (final entry in _index.entries.values) {
      if (entry.lyrics != null) total += entry.lyrics!.size;
    }
    return total;
  }

  /// 统计所有封面字节数
  int getArtworkBytes() {
    int total = 0;
    for (final entry in _index.entries.values) {
      if (entry.artwork != null) total += entry.artwork!.size;
    }
    return total;
  }

  /// 有 audio 缓存的条目数
  int getSongCount() {
    int count = 0;
    for (final entry in _index.entries.values) {
      if (entry.audio.isNotEmpty) count++;
    }
    return count;
  }

  /// 返回按条目中最旧的 lastAccessedAt 升序排列的列表（用于 LRU 淘汰）
  /// 若条目有 audio，取 audio 中最旧的 lastAccessedAt；
  /// 若没有 audio，则取 lyrics/artwork 中最旧的
  List<MapEntry<String, CacheEntry>> getEntriesOrderedByLastAccess() {
    final list = _index.entries.entries.toList();
    list.sort((a, b) {
      final tsA = _entryOldestLastAccess(a.value);
      final tsB = _entryOldestLastAccess(b.value);
      // 没有任何访问时间记录的条目视为最旧（最该被淘汰）
      if (tsA == null && tsB == null) return 0;
      if (tsA == null) return -1;
      if (tsB == null) return 1;
      return tsA.compareTo(tsB);
    });
    return list;
  }

  /// 计算单个条目中最旧的 lastAccessedAt
  String? _entryOldestLastAccess(CacheEntry entry) {
    if (entry.audio.isNotEmpty) {
      String? oldest;
      for (final info in entry.audio.values) {
        if (oldest == null || info.lastAccessedAt.compareTo(oldest) < 0) {
          oldest = info.lastAccessedAt;
        }
      }
      return oldest;
    }
    // 没有 audio 时，使用 lyrics/artwork 中最旧的
    String? oldest;
    if (entry.lyrics != null) {
      oldest = entry.lyrics!.lastAccessedAt;
    }
    if (entry.artwork != null) {
      final ts = entry.artwork!.lastAccessedAt;
      if (oldest == null || ts.compareTo(oldest) < 0) {
        oldest = ts;
      }
    }
    return oldest;
  }
}
