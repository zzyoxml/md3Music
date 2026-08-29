import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/music_folder.dart';
import '../models/song.dart';
import '../../core/services/media_store_service.dart';
import '../../core/utils/audio_scanner.dart';

/// 本地音乐仓库：负责扫描设备存储中的音频文件并构建分类数据。
///
/// 扫描策略（双源合并）：
/// 1. **MediaStore（主源）**：Android 11+ 沙箱模式下唯一稳定方案，
///    系统已索引的所有音频（网易云/QQ 音乐/酷狗等通过 MediaStore 公开的部分）。
/// 2. **文件系统（补充）**：扫描用户额外选择的文件夹，以及常见下载目录
///    （如 `/storage/emulated/0/Music`、`/Download`），用 `audio_metadata_reader`
///    读取 metadata。
class LocalMusicRepository {
  static const String _foldersKey = 'local_music_scan_folders';
  static const String _excludedFoldersKey = 'local_music_excluded_folders';

  /// 持久化已扫描的歌曲列表（JSON 编码）。
  /// 用于 App 重启后立即显示上次扫描结果，避免每次启动都重扫。
  static const String _cachedSongsKey = 'local_music_cached_songs';
  static const String _cachedAtKey = 'local_music_cached_at';

  /// 获取用户保存的自定义扫描文件夹列表。
  Future<List<String>> getSavedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_foldersKey) ?? [];
  }

  /// 保存扫描文件夹列表。
  Future<void> saveFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_foldersKey, folders);
  }

  /// 添加扫描文件夹（去重）。
  Future<void> addFolder(String folder) async {
    final folders = await getSavedFolders();
    if (!folders.contains(folder)) {
      folders.add(folder);
      await saveFolders(folders);
    }
  }

  /// 移除扫描文件夹。
  Future<void> removeFolder(String folder) async {
    final folders = await getSavedFolders();
    folders.remove(folder);
    await saveFolders(folders);
  }

  /// 持久化已扫描的歌曲列表到 SharedPreferences（JSON 数组）。
  ///
  /// 用于 App 退出后再次启动时立即显示上次扫描结果，
  /// 不再强制要求用户每次启动都重新扫描。
  Future<void> saveSongs(List<Song> songs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = songs.map((s) => s.toJson()).toList();
      await prefs.setString(_cachedSongsKey, jsonEncode(jsonList));
      await prefs.setInt(_cachedAtKey, DateTime.now().millisecondsSinceEpoch);
      debugPrint('[LocalMusicRepository] 已缓存 ${songs.length} 首歌曲');
    } catch (e) {
      debugPrint('[LocalMusicRepository] 缓存歌曲失败: $e');
    }
  }

  /// 读取上次持久化的歌曲列表。
  ///
  /// 返回的列表仅作"快速显示上次结果"用，文件可能在系统升级/卸载后
  /// 已不存在；UI 层不感知（播放器在播放时再校验）。
  Future<List<Song>> getSavedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cachedSongsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[LocalMusicRepository] 读取缓存歌曲失败: $e');
      return [];
    }
  }

  /// 上次缓存的时间戳（毫秒），无则返回 null。
  Future<int?> getCachedAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_cachedAtKey);
  }

  /// 清除缓存的歌曲（用户主动重置本地音乐时使用）。
  Future<void> clearSavedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedSongsKey);
    await prefs.remove(_cachedAtKey);
  }

  /// 获取用户排除的文件夹列表。
  Future<List<String>> getExcludedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_excludedFoldersKey) ?? [];
  }

  /// 保存排除文件夹列表。
  Future<void> saveExcludedFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludedFoldersKey, folders);
  }

  /// 添加排除文件夹（去重）。
  Future<void> addExcludedFolder(String folder) async {
    final folders = await getExcludedFolders();
    if (!folders.contains(folder)) {
      folders.add(folder);
      await saveExcludedFolders(folders);
    }
  }

  /// 移除排除文件夹。
  Future<void> removeExcludedFolder(String folder) async {
    final folders = await getExcludedFolders();
    folders.remove(folder);
    await saveExcludedFolders(folders);
  }

  /// 判断文件路径是否位于排除文件夹内。
  ///
  /// 支持子目录匹配：排除 `/storage/emulated/0/Recordings` 时，
  /// `/storage/emulated/0/Recordings/voice.mp3` 也会被排除。
  bool _isExcluded(String filePath, List<String> excludedFolders) {
    if (excludedFolders.isEmpty) return false;
    final normalized = filePath.replaceAll('\\', '/');
    for (final excluded in excludedFolders) {
      final normalizedExcluded = excluded.replaceAll('\\', '/');
      // 确保是目录级别匹配（excluded 是路径前缀，且后面跟着 / 或完全相等）
      if (normalized == normalizedExcluded ||
          normalized.startsWith('$normalizedExcluded/')) {
        return true;
      }
    }
    return false;
  }

  /// 根据码率和文件扩展名推断本地音质标签。
  ///
  /// 规则：
  /// - FLAC/APE/WAV → 'flac'（无损格式直接判定为无损）
  /// - bitrate > 320kbps → 'flac'（码率超过 320 判定为无损）
  /// - bitrate > 128kbps → '320'（高品质）
  /// - bitrate > 0 → '128'（标准音质）
  /// - bitrate == 0 且无法判定 → null
  static String? _inferQuality(int? bitrate, String? filePath) {
    // 无损格式直接判定
    if (filePath != null) {
      final ext = filePath.toLowerCase().split('.').last;
      if (ext == 'flac' || ext == 'ape' || ext == 'wav' || ext == 'aiff') {
        return 'flac';
      }
    }
    if (bitrate == null || bitrate <= 0) return null;
    if (bitrate > 320) return 'flac';
    if (bitrate > 128) return '320';
    return '128';
  }

  /// 扫描所有音频文件并返回 Song 列表。
  ///
  /// 优先使用 MediaStore（沙箱兼容），再补充文件系统扫描用户自定义目录。
  /// [excludedFolders] 中的文件夹及其子目录会被排除。
  Future<List<Song>> scanSongs({
    List<String>? customFolders,
    List<String>? excludedFolders,
  }) async {
    if (kIsWeb) return [];

    final excluded = excludedFolders ?? [];
    final songs = <Song>[];
    final seenPaths = <String>{};

    // 1. MediaStore 主源：Android 11+ 沙箱模式兼容
    try {
      final mediaStoreFiles = await MediaStoreService.queryAudioFiles();
      debugPrint(
        '[LocalMusicRepository] MediaStore 返回 ${mediaStoreFiles.length} 个文件',
      );
      for (final data in mediaStoreFiles) {
        var filePath = data['filePath'] as String?;
        if (filePath == null || !seenPaths.add(filePath)) continue;

        // 把 `content://` 提前解析为真实文件路径。
        // 这样 PlayerProvider 拿到的是绝对路径而不是 content URI，
        // just_audio 可以直接播放（不解析 content:// 协议会导致"播放没声音"）。
        if (filePath.startsWith('content://')) {
          try {
            final resolved = await MediaStoreService.resolveLocalPath(filePath);
            if (resolved != null && resolved.isNotEmpty) {
              filePath = resolved;
              seenPaths.add(filePath);
            }
          } catch (_) {
            // 解析失败保留 content://，由 PlayerProvider 兜底重试
          }
        }

        // 排除文件夹过滤（解析为真实路径后再判断）
        if (_isExcluded(filePath!, excluded)) {
          debugPrint('[LocalMusicRepository] 排除文件: $filePath');
          continue;
        }

        // MediaStore 已提供 title/artist/album，不再用 audio_metadata_reader 重新解析
        // 优先使用 albumArtUri（content://）作为封面来源，UI 层通过
        // CachedNetworkImage 加载（它支持任意 https:// 和 file:// 协议，
        // 对 content:// 需要 Image.network + httpHeader）
        final albumArtUri = data['albumArtUri'] as String?;
        final bitrate = data['bitrate'] as int?;
        songs.add(
          Song(
            id: 'local_$filePath',
            title: (data['title'] as String?) ?? '未知标题',
            artist: (data['artist'] as String?) ?? '未知艺术家',
            album: (data['album'] as String?) ?? '未知专辑',
            duration: Duration(milliseconds: (data['durationMs'] as int?) ?? 0),
            localPath: filePath,
            // 优先用 MediaStore 的 albumArtUri（content://media/...），
            // 为空时用 local://<filePath> 标识内嵌封面，UI 层据此懒加载
            artworkUri: albumArtUri ?? 'local://$filePath',
            isOnline: false,
            quality: _inferQuality(bitrate, filePath),
          ),
        );
      }
    } catch (e) {
      debugPrint('[LocalMusicRepository] MediaStore 扫描失败: $e');
    }

    // 2. 文件系统补充：扫描默认目录 + 用户自定义目录
    final scanDirs = <String>[...defaultScanDirs];
    if (customFolders != null) {
      for (final f in customFolders) {
        if (!scanDirs.contains(f)) scanDirs.add(f);
      }
    }

    final filePaths = collectAudioFiles(scanDirs, excludedDirs: excluded);
    debugPrint('[LocalMusicRepository] 文件系统扫描到 ${filePaths.length} 个文件');

    if (filePaths.isNotEmpty) {
      // 过滤掉已经通过 MediaStore 添加的文件（去重）
      final newPaths = filePaths.where((p) => !seenPaths.contains(p)).toList();
      if (newPaths.isNotEmpty) {
        final results = await compute(scanAudioFilesInIsolate, newPaths);
        for (final data in results) {
          final filePath = data['filePath'] as String;
          if (!seenPaths.add(filePath)) continue;
          final bitrate = data['bitrate'] as int?;
          songs.add(
            Song(
              id: 'local_$filePath',
              title: data['title'] as String,
              artist: data['artist'] as String,
              album: data['album'] as String,
              duration: Duration(
                milliseconds: (data['durationMs'] as int?) ?? 0,
              ),
              localPath: filePath,
              // 用 local:// 前缀标识内嵌封面，UI 层通过 LocalArtworkCache 懒加载
              artworkUri: 'local://$filePath',
              isOnline: false,
              quality: _inferQuality(bitrate, filePath),
            ),
          );
        }
      }
    }

    debugPrint('[LocalMusicRepository] 合并后共 ${songs.length} 首歌曲');
    return songs;
  }

  /// 从 Song 列表构建 Album 列表（按 album 字段分组）。
  List<Album> buildAlbums(List<Song> songs) {
    final albumMap = <String, List<Song>>{};
    for (final song in songs) {
      final key = song.album.isEmpty ? '未知专辑' : song.album;
      albumMap.putIfAbsent(key, () => []).add(song);
    }
    return albumMap.entries.map((entry) {
      final firstSong = entry.value.first;
      return Album(
        id: 'local_album_${entry.key}',
        name: entry.key,
        artist: firstSong.artist,
        songCount: entry.value.length,
        // 使用 local:// 前缀标识本地封面，UI 层据此选择 LocalArtworkCache 加载
        artworkUri: firstSong.localPath != null
            ? 'local://${firstSong.localPath}'
            : null,
      );
    }).toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 从 Song 列表构建 Artist 列表（按 artist 字段分组）。
  List<Artist> buildArtists(List<Song> songs) {
    final artistMap = <String, List<Song>>{};
    for (final song in songs) {
      final key = song.artist.isEmpty ? '未知艺术家' : song.artist;
      artistMap.putIfAbsent(key, () => []).add(song);
    }
    return artistMap.entries.map((entry) {
      final albums = entry.value.map((s) => s.album).toSet();
      final firstSong = entry.value.first;
      return Artist(
        id: 'local_artist_${entry.key}',
        name: entry.key,
        songCount: entry.value.length,
        albumCount: albums.length,
        // 使用 local:// 前缀标识本地封面
        artworkUri: firstSong.localPath != null
            ? 'local://${firstSong.localPath}'
            : null,
      );
    }).toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 从 Song 列表构建 MusicFolder 列表（按文件所在目录分组）。
  List<MusicFolder> buildFolders(List<Song> songs) {
    final folderMap = <String, List<Song>>{};
    for (final song in songs) {
      final path = song.localPath;
      if (path == null) continue;
      final dir = path.substring(0, path.lastIndexOf('/'));
      folderMap.putIfAbsent(dir, () => []).add(song);
    }
    return folderMap.entries.map((entry) {
      final parts = entry.key.split('/').where((p) => p.isNotEmpty);
      return MusicFolder(
        path: entry.key,
        name: parts.isNotEmpty ? parts.last : entry.key,
        songIds: entry.value.map((s) => s.id).toList(),
      );
    }).toList()..sort((a, b) => a.name.compareTo(b.name));
  }
}
