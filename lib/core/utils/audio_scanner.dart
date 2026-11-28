import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

/// 默认扫描目录：覆盖常见音乐 App 下载路径。
const List<String> defaultScanDirs = [
  '/storage/emulated/0/Music',
  '/storage/emulated/0/Download',
  '/storage/emulated/0/Netease/CloudMusic/Music',
  '/storage/emulated/0/qqmusic/song',
  '/storage/emulated/0/kugou/down_data',
  '/storage/emulated/0/kugou/down_kg',
];

/// Windows 默认扫描目录：用户在「音乐 / 下载 / 桌面」下的常见位置。
///
/// 上面那份 [defaultScanDirs] 是 Android 专属路径（`/storage/emulated/0/...`），
/// 在 Windows 上一条都不存在 → 默认扫描永远返回 0 个文件，用户不加自定义目录
/// 就永远是空的「本地音乐」。这里按用户主目录拼出候选路径。
List<String> get defaultScanDirsForPlatform {
  if (Platform.isWindows) {
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (home.isEmpty) return const [];
    final sep = Platform.pathSeparator;
    final dirs = <String>[
      '$home${sep}Music',
      '$home${sep}Downloads',
      '$home${sep}Desktop',
    ];
    // 去掉重复项（如用户主目录本身就是 Music 时）
    return dirs.toSet().toList();
  }
  return defaultScanDirs;
}

/// 支持的音频文件扩展名（用于过滤目录扫描结果）。
/// 仅保留纯音频格式，不含 .mp4/.mov 等视频容器。
const Set<String> audioExtensions = {
  '.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav', '.aac', '.ape', '.wma',
  '.aif', '.aiff', '.aifc',
};

/// Android 默认 Media3 解复用器不支持的常见容器，不作为可播放本地歌曲扫描。
const Set<String> androidUnsupportedAudioExtensions = {
  '.ape', '.wma', '.aif', '.aiff', '.aifc',
};

String _audioExtension(String path) {
  final fileName = path.split(RegExp(r'[/\\]')).last.toLowerCase();
  final dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot);
}

bool isAudioFileSupported(String path, {required bool isAndroid}) {
  final extension = _audioExtension(path);
  return audioExtensions.contains(extension) &&
      (!isAndroid || !androidUnsupportedAudioExtensions.contains(extension));
}

bool isAndroidUnsupportedAudioFile(String path) =>
    androidUnsupportedAudioExtensions.contains(_audioExtension(path));

/// Isolate 入口函数：批量扫描音频文件并读取 metadata。
///
/// 在 [compute] 中调用，[filePaths] 为文件路径字符串列表。
/// 返回可序列化的 `List<Map>`，每项包含 filePath/title/artist/album/durationMs。
List<Map<String, dynamic>> scanAudioFilesInIsolate(List<String> filePaths) {
  final results = <Map<String, dynamic>>[];
  int skipped = 0;
  for (final path in filePaths) {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        skipped++;
        continue;
      }
      final metadata = readMetadata(file, getImage: false);
      // issue #251：本地音乐优先用「文件自身的本地信息」组织专辑。
      // 内嵌标签是第一优先；标签缺失时按目录结构推断（专辑/曲目 布局），
      // 而不是一律落到「未知专辑」——后者会让整库塌成一个专辑分组。
      final tagAlbum = metadata.album?.trim();
      final tagArtist = metadata.artist?.trim();
      results.add({
        'filePath': path,
        'title': metadata.title ?? _extractTitleFromPath(path),
        'artist': (tagArtist != null && tagArtist.isNotEmpty)
            ? tagArtist
            : (inferArtistFromPath(path) ?? '未知艺术家'),
        'album': (tagAlbum != null && tagAlbum.isNotEmpty)
            ? tagAlbum
            : (inferAlbumFromPath(path) ?? '未知专辑'),
        'durationMs': metadata.duration?.inMilliseconds ?? 0,
        'bitrate': metadata.bitrate ?? 0,
      });
    } catch (e) {
      skipped++;
      debugPrint('[AudioScanner] 跳过文件: $path, 错误: $e');
    }
  }
  debugPrint(
      '[AudioScanner] 扫描完成: 共 ${filePaths.length} 个文件, 成功 ${results.length}, 失败 $skipped');
  return results;
}

/// Isolate 入口函数：读取单个文件的封面图。
///
/// 在 [compute] 中调用，返回 `Map` 包含 filePath 和 bytes（Uint8List），
/// 或 null 表示无封面。
Map<String, dynamic>? readArtworkInIsolate(String filePath) {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final metadata = readMetadata(file, getImage: true);
    if (metadata.pictures.isNotEmpty) {
      // 优先选择 front cover
      final frontCover = metadata.pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => metadata.pictures.first,
      );
      return {
        'filePath': filePath,
        'bytes': frontCover.bytes,
      };
    }
  } catch (_) {}
  return null;
}

/// 递归收集目录中的音频文件路径。
///
/// 同步工作函数，扫描入口应通过 [collectAudioFilesInIsolate] 在后台调用。
/// 使用 [audioExtensions] 过滤，去重后返回路径列表。
/// [excludedDirs] 中的目录及其子目录会被跳过。
List<String> collectAudioFiles(List<String> rootDirs, {List<String>? excludedDirs}) {
  final filePaths = <String>[];
  final seen = <String>{};
  final visitedDirs = <String>{};
  final excluded = excludedDirs ?? [];
  final pending = List<String>.from(rootDirs);
  while (pending.isNotEmpty) {
    final rootPath = pending.removeLast();
    try {
      final dir = Directory(rootPath);
      if (!dir.existsSync()) {
        debugPrint('[AudioScanner] 目录不存在或不可访问: $rootPath');
        continue;
      }
      // 检查根目录本身是否被排除
      if (_isPathExcluded(rootPath, excluded)) {
        debugPrint('[AudioScanner] 跳过排除目录: $rootPath');
        continue;
      }
      final directoryKey = dir.absolute.path.replaceAll('\\', '/');
      if (!visitedDirs.add(Platform.isWindows ? directoryKey.toLowerCase() : directoryKey)) {
        continue;
      }
      // 每个目录单独处理：无权限的子目录不能让整个根目录的结果丢失；
      // 也不进入排除目录，避免先枚举全盘再过滤导致内存暴涨。
      final entities = dir.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is Directory) {
          if (!_isPathExcluded(entity.path, excluded)) pending.add(entity.path);
        } else if (entity is File) {
          final path = entity.path;
          // 排除文件夹过滤
          if (_isPathExcluded(path, excluded)) continue;
          if (isAudioFileSupported(path, isAndroid: Platform.isAndroid)) {
            if (seen.add(Platform.isWindows ? path.toLowerCase() : path)) {
              filePaths.add(path);
            }
          }
        }
      }
      debugPrint(
          '[AudioScanner] 目录 $rootPath: 累计找到 ${filePaths.length} 个音频文件');
    } catch (e) {
      // 跳过无权限访问的目录（Android 11+ 沙箱限制常见）
      debugPrint('[AudioScanner] 目录扫描失败: $rootPath, 错误: $e');
    }
  }
  debugPrint('[AudioScanner] 总计找到 ${filePaths.length} 个音频文件');
  return filePaths;
}

/// compute 入口只接收可序列化路径，不在 UI Isolate 做递归文件 I/O。
List<String> collectAudioFilesInIsolate(Map<String, List<String>> input) =>
    collectAudioFiles(input['roots']!, excludedDirs: input['excluded']);

/// 判断路径是否位于排除文件夹内（支持子目录匹配）。
bool _isPathExcluded(String path, List<String> excludedDirs) {
  if (excludedDirs.isEmpty) return false;
  var normalized = path.replaceAll('\\', '/');
  if (Platform.isWindows) normalized = normalized.toLowerCase();
  for (final excluded in excludedDirs) {
    var normalizedExcluded = excluded.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
    if (Platform.isWindows) normalizedExcluded = normalizedExcluded.toLowerCase();
    if (normalized == normalizedExcluded ||
        normalized.startsWith('$normalizedExcluded/')) {
      return true;
    }
  }
  return false;
}

/// 从文件路径提取标题（当 metadata 无 title 时回退）。
String _extractTitleFromPath(String path) {
  // Windows 路径用 `\` 分隔（`C:\Music\a.mp3`），只按 `/` 切会拿到整条路径当标题。
  final fileName = path.split(RegExp(r'[/\\]')).last;
  final lastDot = fileName.lastIndexOf('.');
  if (lastDot > 0) return fileName.substring(0, lastDot);
  return fileName;
}

/// 常见「本地音乐」根目录名：命中这些目录说明上一层不是专辑名。
///
/// 用于 [inferAlbumFromPath] 判断哪一级才像专辑目录 —— 例如
/// `D:/Music/周杰伦/叶惠美/01.mp3` 的专辑是「叶惠美」，而
/// `D:/Music/01.mp3` 不该把「Music」当成专辑。
const Set<String> _kGenericMusicDirs = {
  'music',
  'musics',
  'audio',
  'audios',
  'sound',
  'sounds',
  'song',
  'songs',
  'mp3',
  'flac',
  '无损音乐',
  '音乐',
  '我的音乐',
  '本地音乐',
  '下载',
  'download',
  'downloads',
  'dcim',
  'recordings',
  '录音',
};

/// 从文件路径推断专辑名（metadata 无 album 时回退）。
///
/// issue #251：用户希望「本地音乐未匹配在线信息时，直接使用本地文件内部
/// 标签信息来匹配专辑」。内嵌标签读不到时，业界通行做法是**按目录结构推断**
/// ——绝大多数人的曲库就是 `专辑/曲目` 或 `艺术家/专辑/曲目` 布局。
///
/// 规则：取父目录名；父目录是盘符根 / 常见音乐根目录 / 名为「未知」时返回 null
/// （交给调用方落「未知专辑」，不伪造专辑名）。
String? inferAlbumFromPath(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return null; // 只有文件名，没有目录可用
  return _albumFromDirName(parts[parts.length - 2]);
}

/// 从**目录路径**推断专辑名（SAF 场景：只知道文件所在目录，没有完整文件路径）。
///
/// 与 [inferAlbumFromPath] 的区别是取 `docDir` 的**最后一级**而不是父级，
/// 因为调用方传入的已经是文件所在目录。
String? inferAlbumFromDir(String docDir) {
  final parts =
      docDir.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  return _albumFromDirName(parts[parts.length - 1]);
}

String? _albumFromDirName(String raw) {
  final parent = raw.trim();
  if (parent.isEmpty) return null;
  final normalized = parent.toLowerCase();
  // 盘符（`D:`）或纯根目录：不当作专辑。
  if (RegExp(r'^[a-z]:$').hasMatch(normalized)) return null;
  if (_kGenericMusicDirs.contains(normalized)) return null;
  return parent;
}

/// 从文件路径推断艺术家名（`艺术家/专辑/曲目` 布局时取祖父目录）。
///
/// 只在目录层级足够（≥3 级：艺术家/专辑/文件）且祖父目录不是通用根目录时
/// 才返回，避免把 `Music/01.mp3` 的「Music」误当艺术家。
String? inferArtistFromPath(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList();
  if (parts.length < 3) return null;
  final grand = parts[parts.length - 3].trim();
  if (grand.isEmpty) return null;
  final normalized = grand.toLowerCase();
  if (RegExp(r'^[a-z]:$').hasMatch(normalized)) return null;
  if (_kGenericMusicDirs.contains(normalized)) return null;
  return grand;
}

