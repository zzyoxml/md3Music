import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'lyric_data.dart';
import 'stream_cache_repository.dart';

/// 缓存统计信息
class CacheStats {
  final int totalBytes;
  final int audioBytes;
  final int lyricsBytes;
  final int artworkBytes;
  final int songCount;

  const CacheStats({
    required this.totalBytes,
    required this.audioBytes,
    required this.lyricsBytes,
    required this.artworkBytes,
    required this.songCount,
  });
}

/// 边听边存核心缓存管理器（单例）
///
/// 负责 audio / lyrics / artwork 三类文件的磁盘缓存，
/// 内部持有 [StreamCacheRepository] 做索引持久化。
///
/// 包内不依赖主工程类型：歌曲用 [SongMetadata]（由主工程接线层适配），
/// 歌词用 [LyricData]；缓存上限由 [cacheLimitMbProvider] 注入读取，
/// 未注入时跳过按上限清理（等价于无限制）。
class StreamCacheManager {
  StreamCacheManager._();
  static final StreamCacheManager instance = StreamCacheManager._();

  /// 由主工程接线层注入：读取边听边存缓存上限（MB）。
  /// 为 null 时跳过按上限清理（不注入则不删除任何缓存）。
  static Future<int> Function()? cacheLimitMbProvider;

  /// 缓存根目录 stream_cache/
  late final Directory _cacheRoot;
  late final Directory _audioDir;
  late final Directory _lyricsDir;
  late final Directory _artworkDir;
  late final Dio _dio;

  /// 正在进行的音频下载，key = hash，用于取消
  final Map<String, CancelToken> _audioDownloads = {};

  bool _initialized = false;

  /// 初始化缓存目录与索引。所有公开方法调用前都会先确保初始化完成。
  Future<void> ensureInitialized() async {
    if (_initialized) {
      // 目录可能被系统清理（Android 外部存储），每次检查并重建
      try {
        if (!await _audioDir.exists()) await _audioDir.create(recursive: true);
        if (!await _lyricsDir.exists()) await _lyricsDir.create(recursive: true);
        if (!await _artworkDir.exists()) await _artworkDir.create(recursive: true);
      } catch (_) {}
      return;
    }
    // 选择缓存根目录：优先外部存储，兜底应用文档目录
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {
      base = null;
    }
    base ??= await getApplicationDocumentsDirectory();

    final sep = Platform.pathSeparator;
    _cacheRoot = Directory('${base.path}${sep}stream_cache');
    _audioDir = Directory('${_cacheRoot.path}${sep}audio');
    _lyricsDir = Directory('${_cacheRoot.path}${sep}lyrics');
    _artworkDir = Directory('${_cacheRoot.path}${sep}artwork');

    await _cacheRoot.create(recursive: true);
    await _audioDir.create(recursive: true);
    await _lyricsDir.create(recursive: true);
    await _artworkDir.create(recursive: true);

    _dio = Dio();

    // 将缓存目录交给索引仓库并加载 index.json
    await StreamCacheRepository.instance.setCacheDir(_cacheRoot);
    _initialized = true;
  }

  /// 音质等级：128 < 320 < flac < high
  int _qualityRank(String q) {
    switch (q) {
      case '128':
        return 1;
      case 'hq':
        return 2;
      case 'flac':
        return 3;
      case 'high':
        return 4;
      default:
        return 0;
    }
  }

  /// 拼接缓存根目录与相对路径（索引中存储的是相对路径）
  String _resolvePath(String relativePath) {
    return '${_cacheRoot.path}${Platform.pathSeparator}$relativePath';
  }

  /// 获取已缓存的音频文件路径。
  ///
  /// 查找策略：在所有 rank ≥ [quality] 的已缓存音质中，
  /// 优先返回同音质，其次返回更高音质（rank 升序）。
  /// 命中后更新 lastAccessedAt，返回完整路径；未命中返回 null。
  Future<String?> getCachedAudioPath(String hash, String quality) async {
    await ensureInitialized();
    try {
      final entry = StreamCacheRepository.instance.getEntry(hash);
      if (entry == null || entry.audio.isEmpty) return null;

      final requestedRank = _qualityRank(quality);
      // 收集 rank >= 请求音质的候选
      final candidates = <MapEntry<String, AudioCacheInfo>>[];
      entry.audio.forEach((q, info) {
        if (_qualityRank(q) >= requestedRank) {
          candidates.add(MapEntry(q, info));
        }
      });
      // 按 rank 升序：同音质（diff=0）优先，其次更高音质
      candidates.sort(
        (a, b) => _qualityRank(a.key).compareTo(_qualityRank(b.key)),
      );

      for (final c in candidates) {
        final fullPath = _resolvePath(c.value.path);
        if (File(fullPath).existsSync()) {
          await StreamCacheRepository.instance.touchAudio(hash, c.key);
          return fullPath;
        }
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] getCachedAudioPath 失败: $e');
      return null;
    }
  }

  /// 下载并缓存音频文件。
  ///
  /// 流程：下载到临时文件 → magic bytes 判定扩展名 → 重命名为最终文件 →
  /// 更新索引 → 按设置的上限清理。
  /// 整个方法不抛异常，避免影响播放器主流程。
  Future<void> cacheAudio(SongMetadata song, String quality, String url) async {
    await ensureInitialized();
    final hash = song.id;
    // 同 hash 的下载串行进行，避免并发写冲突
    if (_audioDownloads.containsKey(hash)) return;

    final cancelToken = CancelToken();
    _audioDownloads[hash] = cancelToken;
    final sep = Platform.pathSeparator;
    final tempPath = '${_audioDir.path}$sep${hash}_$quality.tmp';

    try {
      await _dio.download(url, tempPath, cancelToken: cancelToken);

      final tempFile = File(tempPath);
      if (!await tempFile.exists()) return;

      // 读取前 4 字节判断实际音频格式
      String ext;
      final bytes = await tempFile.openRead(0, 4).first;
      if (bytes.length >= 4 &&
          bytes[0] == 0x66 &&
          bytes[1] == 0x4C &&
          bytes[2] == 0x61 &&
          bytes[3] == 0x43) {
        ext = 'flac'; // fLaC
      } else if (bytes.length >= 3 &&
          bytes[0] == 0x49 &&
          bytes[1] == 0x44 &&
          bytes[2] == 0x33) {
        ext = 'mp3'; // ID3
      } else if (bytes.length >= 2 &&
          bytes[0] == 0xFF &&
          (bytes[1] & 0xE0) == 0xE0) {
        ext = 'mp3'; // MPEG 同步字
      } else {
        // magic bytes 无法判断时按音质兜底
        final q = quality.toLowerCase();
        ext = (q == 'flac' || q == 'high') ? 'flac' : 'mp3';
      }

      final finalPath = '${_audioDir.path}$sep${hash}_$quality.$ext';
      final finalFile = File(finalPath);
      // 若最终文件已存在，先删除
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tempFile.rename(finalPath);

      final size = await finalFile.length();
      final now = DateTime.now().toIso8601String();
      final relativePath = 'audio${Platform.pathSeparator}${hash}_$quality.$ext';

      await StreamCacheRepository.instance.upsertSongMetadata(hash, song);
      await StreamCacheRepository.instance.upsertAudioEntry(
        hash,
        quality,
        AudioCacheInfo(
          path: relativePath,
          size: size,
          ext: ext,
          cachedAt: now,
          lastAccessedAt: now,
        ),
      );

      // 读取设置中的边听边存缓存上限（MB）并清理
      await _cleanIfOverLimit();
    } catch (e) {
      // 下载失败或取消时删除临时文件
      try {
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      // ignore: avoid_print
      print('[StreamCacheManager] cacheAudio 失败: $e');
    } finally {
      _audioDownloads.remove(hash);
    }
  }

  /// 取消指定 hash 的音频下载，并清理可能的临时文件（不删除已完成的最终文件）。
  Future<void> cancelAudioDownload(String hash) async {
    await ensureInitialized();
    try {
      _audioDownloads[hash]?.cancel();
      _audioDownloads.remove(hash);
      // 删除 _audioDir 下匹配 <hash>_*.tmp 的临时文件
      final entities = _audioDir.listSync();
      final prefix = '${hash}_';
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith(prefix) && name.endsWith('.tmp')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] cancelAudioDownload 失败: $e');
    }
  }

  /// 获取已缓存的歌词。文件不存在返回 null。
  /// 命中后更新 lyrics 的 lastAccessedAt。
  Future<LyricData?> getCachedLyric(String hash) async {
    await ensureInitialized();
    try {
      final path = '${_lyricsDir.path}${Platform.pathSeparator}$hash.json';
      final file = File(path);
      if (!await file.exists()) return null;

      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final lyric = LyricData(
        content: json['content'] as String? ?? '',
        decodedContent: json['decodedContent'] as String?,
        decodedKrcContent: json['decodedKrcContent'] as String?,
        translatedContent: json['translatedContent'] as String?,
        romaContent: json['romaContent'] as String?,
      );
      await StreamCacheRepository.instance.touchLyrics(hash);
      return lyric;
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] getCachedLyric 失败: $e');
      return null;
    }
  }

  /// 缓存歌词到磁盘并更新索引。
  Future<void> cacheLyric(String hash, LyricData lyric) async {
    await ensureInitialized();
    try {
      // 序列化所有文本字段
      final jsonMap = {
        'content': lyric.content,
        'decodedContent': lyric.decodedContent,
        'decodedKrcContent': lyric.decodedKrcContent,
        'translatedContent': lyric.translatedContent,
        'romaContent': lyric.romaContent,
      };
      final encoded = jsonEncode(jsonMap);
      final bytes = utf8.encode(encoded);
      final path = '${_lyricsDir.path}${Platform.pathSeparator}$hash.json';
      await File(path).writeAsBytes(bytes);

      final now = DateTime.now().toIso8601String();
      await StreamCacheRepository.instance.upsertLyricsEntry(
        hash,
        LyricsCacheInfo(
          path: 'lyrics${Platform.pathSeparator}$hash.json',
          size: bytes.length,
          cachedAt: now,
          lastAccessedAt: now,
        ),
      );

      // 按边听边存上限清理
      await _cleanIfOverLimit();
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] cacheLyric 失败: $e');
    }
  }

  /// 获取已缓存的封面图片字节。索引无或文件不存在返回 null。
  /// 命中后更新 artwork 的 lastAccessedAt。
  Future<Uint8List?> getCachedArtwork(String hash) async {
    await ensureInitialized();
    try {
      final entry = StreamCacheRepository.instance.getEntry(hash);
      final artwork = entry?.artwork;
      if (artwork == null) return null;

      final fullPath = _resolvePath(artwork.path);
      final file = File(fullPath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      await StreamCacheRepository.instance.touchArtwork(hash);
      return bytes;
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] getCachedArtwork 失败: $e');
      return null;
    }
  }

  /// 获取已缓存的封面图片本地文件路径。索引无或文件不存在返回 null。
  /// 命中后更新 artwork 的 lastAccessedAt。
  /// 用于 MediaSession / 系统通知栏等需要 file:// URI 的场景（断网兜底）。
  Future<String?> getCachedArtworkPath(String hash) async {
    await ensureInitialized();
    try {
      final entry = StreamCacheRepository.instance.getEntry(hash);
      final artwork = entry?.artwork;
      if (artwork == null) return null;

      final fullPath = _resolvePath(artwork.path);
      final file = File(fullPath);
      if (!await file.exists()) return null;

      await StreamCacheRepository.instance.touchArtwork(hash);
      return fullPath;
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] getCachedArtworkPath 失败: $e');
      return null;
    }
  }

  /// 下载并缓存封面图片。url 为空时直接返回。
  Future<void> cacheArtwork(String hash, String url) async {
    await ensureInitialized();
    if (url.isEmpty) return;
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return;

      final bytes = Uint8List.fromList(data);
      await _saveArtworkBytes(hash, bytes);

      // 按边听边存上限清理
      await _cleanIfOverLimit();
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] cacheArtwork 失败: $e');
    }
  }

  /// 从在线音频 URL 提取内嵌封面并缓存。
  ///
  /// 云盘等场景的封面内嵌在音频文件元数据（ID3/FLAC 标签）中，
  /// API 不返回封面 URL。这里用 Range 请求只下载音频头部（封面通常
  /// 位于文件头部几 KB～几百 KB），写入临时文件后用 audio_metadata_reader
  /// 解析内嵌封面，缓存为 artwork 图片。
  ///
  /// 成功返回缓存封面文件的 `file://` 绝对路径；无封面/失败返回 null。
  /// 不抛异常，失败静默（封面缺失不阻塞播放）。
  Future<String?> cacheEmbeddedArtwork(String hash, String audioUrl) async {
    await ensureInitialized();
    if (audioUrl.isEmpty) return null;
    final sep = Platform.pathSeparator;
    final tempPath = '${_artworkDir.path}${sep}embedded_$hash.tmp';
    try {
      // 只取前 2MB：内嵌封面（ID3v2 APIC / FLAC PICTURE）在文件头部。
      // 若服务器忽略 Range 返回全量，仅保留前 2MB 用于解析。
      const headBytes = 2 * 1024 * 1024;
      final response = await _dio.get<List<int>>(
        audioUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=0-${headBytes - 1}'},
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      final head = data.length > headBytes
          ? data.sublist(0, headBytes)
          : data;

      // 写入临时文件供 audio_metadata_reader 解析
      final tempFile = File(tempPath);
      await tempFile.writeAsBytes(head, flush: true);

      Uint8List? cover;
      try {
        final metadata = readMetadata(tempFile, getImage: true);
        if (metadata.pictures.isNotEmpty) {
          final frontCover = metadata.pictures.firstWhere(
            (p) => p.pictureType == PictureType.coverFront,
            orElse: () => metadata.pictures.first,
          );
          cover = frontCover.bytes;
        }
      } catch (_) {
        // 头部字节不足以解析（异常格式）→ 视为无封面
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }

      if (cover == null || cover.isEmpty) return null;
      final path = await _saveArtworkBytes(hash, cover);
      return path == null ? null : 'file://$path';
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] cacheEmbeddedArtwork 失败: $e');
      return null;
    }
  }

  /// 将封面字节写入 artwork 目录并更新索引，返回绝对路径（无扩展名推断失败返回 null）。
  Future<String?> _saveArtworkBytes(String hash, Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    // magic bytes 判断图片格式
    String ext;
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      ext = 'jpg';
    } else if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      ext = 'png';
    } else {
      ext = 'jpg'; // 兜底 jpg
    }

    final path = '${_artworkDir.path}${Platform.pathSeparator}$hash.$ext';
    await File(path).writeAsBytes(bytes);

    final now = DateTime.now().toIso8601String();
    await StreamCacheRepository.instance.upsertArtworkEntry(
      hash,
      ArtworkCacheInfo(
        path: 'artwork${Platform.pathSeparator}$hash.$ext',
        size: bytes.length,
        ext: ext,
        cachedAt: now,
        lastAccessedAt: now,
      ),
    );
    return path;
  }

  /// 返回缓存统计信息
  Future<CacheStats> getCacheStats() async {
    await ensureInitialized();
    try {
      final repo = StreamCacheRepository.instance;
      return CacheStats(
        totalBytes: repo.getTotalBytes(),
        audioBytes: repo.getAudioBytes(),
        lyricsBytes: repo.getLyricsBytes(),
        artworkBytes: repo.getArtworkBytes(),
        songCount: repo.getSongCount(),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] getCacheStats 失败: $e');
      return const CacheStats(
        totalBytes: 0,
        audioBytes: 0,
        lyricsBytes: 0,
        artworkBytes: 0,
        songCount: 0,
      );
    }
  }

  /// 清空所有缓存文件与索引（保留目录结构）。
  Future<void> clearCache() async {
    await ensureInitialized();
    try {
      // 删除各分类目录下的所有文件
      await _clearDirFiles(_audioDir);
      await _clearDirFiles(_lyricsDir);
      await _clearDirFiles(_artworkDir);

      // 清空索引：StreamCacheRepository 无 clearAll，遍历 entries 调 removeEntry
      final repo = StreamCacheRepository.instance;
      final hashes = repo.currentIndex.entries.keys.toList();
      for (final hash in hashes) {
        await repo.removeEntry(hash);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] clearCache 失败: $e');
    }
  }

  /// 删除目录下所有文件（保留目录本身）
  Future<void> _clearDirFiles(Directory dir) async {
    if (!await dir.exists()) return;
    final entities = dir.listSync();
    for (final entity in entities) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  /// 读取注入的缓存上限并触发 LRU 清理；未注入时跳过。
  Future<void> _cleanIfOverLimit() async {
    final provider = StreamCacheManager.cacheLimitMbProvider;
    if (provider == null) return;
    try {
      final limitMb = await provider();
      final limitBytes = limitMb * 1024 * 1024;
      await cleanIfExceeding(limitBytes);
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] 读取缓存上限/清理失败: $e');
    }
  }

  /// 当总缓存大小超过 [maxBytes] 时，按 LRU 策略淘汰最久未访问的条目。
  /// [maxBytes] <= 0 表示无限制，直接返回。
  Future<void> cleanIfExceeding(int maxBytes) async {
    await ensureInitialized();
    try {
      if (maxBytes <= 0) return; // 无限制
      final repo = StreamCacheRepository.instance;
      if (repo.getTotalBytes() <= maxBytes) return;

      // 按最旧访问时间升序排列
      final ordered = repo.getEntriesOrderedByLastAccess();
      for (final entry in ordered) {
        // 已达上限以下则停止
        if (repo.getTotalBytes() <= maxBytes) break;

        final hash = entry.key;
        final cacheEntry = entry.value;
        // 删除该条目的所有文件（audio/lyrics/artwork）
        await _deleteEntryFiles(cacheEntry);
        // 删除索引条目
        await repo.removeEntry(hash);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] cleanIfExceeding 失败: $e');
    }
  }

  /// 删除单个条目对应的所有磁盘文件（audio/lyrics/artwork）
  Future<void> _deleteEntryFiles(CacheEntry entry) async {
    for (final audio in entry.audio.values) {
      final file = File(_resolvePath(audio.path));
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    if (entry.lyrics != null) {
      final file = File(_resolvePath(entry.lyrics!.path));
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    if (entry.artwork != null) {
      final file = File(_resolvePath(entry.artwork!.path));
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  /// 仅更新索引中的歌曲元数据（不写文件）
  Future<void> cacheSongMetadata(SongMetadata song) async {
    await ensureInitialized();
    try {
      await StreamCacheRepository.instance.upsertSongMetadata(song.id, song);
    } catch (e) {
      // ignore: avoid_print
      print('[StreamCacheManager] cacheSongMetadata 失败: $e');
    }
  }
}
