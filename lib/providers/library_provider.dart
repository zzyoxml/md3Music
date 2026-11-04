import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../core/services/folder_picker_service.dart';
import '../core/services/local_artwork_cache.dart';
import '../core/utils/permissions.dart';
import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/music_folder.dart';
import '../data/models/song.dart';
import '../data/repositories/local_music_repository.dart';
import 'song_match_provider.dart';

/// 调试日志辅助函数（编译时根据 debugPrint 过滤 release 模式输出）
void _log(String msg) {
  if (kDebugMode) debugPrint(msg);
}

class LibraryProvider extends ChangeNotifier {
  LibraryProvider({LocalMusicRepository? repository})
      : _repository = repository ?? LocalMusicRepository();

  final LocalMusicRepository _repository;

  List<Song> _songs = [];
  List<Song> _indexedSongs = [];
  bool _filterShortAudio = false;
  List<Album> _albums = [];
  List<Artist> _artists = [];
  List<MusicFolder> _folders = [];
  List<String> _scanFolders = [];
  List<String> _excludedFolders = [];

  bool _isLoading = false;
  bool _isScanning = false;
  String? _error;
  String _searchQuery = '';
  int _settingsLoadGeneration = 0;

  /// 未过滤的原始歌曲列表（供详情页按分类获取歌曲使用）。
  List<Song> get allSongs => _songs;
  List<Song> get songs => _filterSongs(_songs);
  List<Album> get albums => _filterAlbums(_albums);
  List<Artist> get artists => _filterArtists(_artists);
  List<MusicFolder> get folders => _folders;
  List<String> get scanFolders => _scanFolders;
  List<String> get excludedFolders => _excludedFolders;
  bool get isLoading => _isLoading;
  bool get isScanning => _isScanning;
  String? get error => _error;
  String get searchQuery => _searchQuery;
  bool get hasMusic => _songs.isNotEmpty;
  bool get filterShortAudio => _filterShortAudio;

  void _rebuildCategories() {
    _songs = _repository.filterSongs(
      _indexedSongs,
      excludedFolders: _excludedFolders,
      filterShortAudio: _filterShortAudio,
    );
    _albums = _repository.buildAlbums(_songs);
    _artists = _repository.buildArtists(_songs);
    _folders = _repository.buildFolders(_songs);
  }

  Future<void> setFilterShortAudio(bool enabled) async {
    await _repository.setFilterShortAudio(enabled);
    _filterShortAudio = enabled;
    _rebuildCategories();
    notifyListeners();
  }

  /// 仅移除索引；排除目录持久化，避免重新扫描时自动加入。
  Future<void> removeFoldersFromIndex(Iterable<String> paths) async {
    final removed = paths.toSet();
    if (removed.isEmpty) return;
    final saved = await _repository.getSavedFolders();
    final excluded = await _repository.getExcludedFolders();
    _excludedFolders = {...excluded, ...removed}.toList();
    _scanFolders = saved.where((path) => !removed.contains(path)).toList();
    await _repository.saveExcludedFolders(_excludedFolders);
    await _repository.saveFolders(_scanFolders);
    _indexedSongs = _repository.filterSongs(
      _indexedSongs,
      excludedFolders: _excludedFolders,
    );
    await _repository.saveSongs(_indexedSongs);
    _rebuildCategories();
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void clearSearch() {
    _searchQuery = '';
    notifyListeners();
  }

  List<Song> _filterSongs(List<Song> songs) {
    if (_searchQuery.isEmpty) return songs;
    final q = _searchQuery.toLowerCase();
    return songs
        .where(
          (s) =>
              s.title.toLowerCase().contains(q) ||
              s.artist.toLowerCase().contains(q) ||
              s.album.toLowerCase().contains(q),
        )
        .toList();
  }

  List<Album> _filterAlbums(List<Album> albums) {
    if (_searchQuery.isEmpty) return albums;
    final q = _searchQuery.toLowerCase();
    return albums
        .where(
          (a) =>
              a.name.toLowerCase().contains(q) ||
              a.artist.toLowerCase().contains(q),
        )
        .toList();
  }

  List<Artist> _filterArtists(List<Artist> artists) {
    if (_searchQuery.isEmpty) return artists;
    final q = _searchQuery.toLowerCase();
    return artists.where((a) => a.name.toLowerCase().contains(q)).toList();
  }

  /// 加载已保存的扫描文件夹和排除文件夹列表。
  Future<void> loadScanFolders() async {
    final generation = _settingsLoadGeneration;
    final folders = await _repository.getSavedFolders();
    final excluded = await _repository.getExcludedFolders();
    final filterShortAudio = await _repository.getFilterShortAudio();
    if (Platform.isWindows && generation != _settingsLoadGeneration) return;
    _scanFolders = folders;
    _excludedFolders = excluded;
    _filterShortAudio = filterShortAudio;
    _rebuildCategories();
    notifyListeners();
  }

  /// Windows 重置扫描目录和短音频筛选时使旧读取失效。
  void prepareWindowsSettingsReset() {
    if (Platform.isWindows) ++_settingsLoadGeneration;
  }

  /// 刷新扫描目录和短音频筛选，不丢失已扫描歌曲缓存。
  Future<void> reloadWindowsSettings() async {
    if (!Platform.isWindows) return;
    ++_settingsLoadGeneration;
    await loadScanFolders();
  }

  /// 加载上次持久化的歌曲列表（用于 App 重启后立即显示）。
  ///
  /// 不会自动触发扫描；只有在用户没有缓存且有扫描文件夹时才提示。
  /// 同时加载已保存的扫描目录，保持状态一致。
  Future<void> loadSavedSongs() async {
    final generation = _settingsLoadGeneration;
    final cached = await _repository.getSavedSongs();
    final folders = await _repository.getSavedFolders();
    final excluded = await _repository.getExcludedFolders();
    final filterShortAudio = await _repository.getFilterShortAudio();
    if (Platform.isWindows && generation != _settingsLoadGeneration) return;
    _indexedSongs = cached;
    _scanFolders = folders;
    _excludedFolders = excluded;
    _filterShortAudio = filterShortAudio;
    _rebuildCategories();
    notifyListeners();
    _log('[LibraryProvider] 已恢复 ${cached.length} 首缓存歌曲');
  }

  /// 扫描本地音乐（使用默认目录 + 用户选择的目录，排除用户指定的文件夹）。
  Future<void> loadLocalMusic() async {
    if (_isScanning) return;
    if (kIsWeb) {
      _songs = [];
      _albums = [];
      _artists = [];
      _folders = [];
      return;
    }

    _isScanning = true;
    _error = null;
    notifyListeners();

    try {
      // SAF 用户授权目录不依赖全盘媒体权限；即使用户拒绝媒体权限仍可扫描 U 盘。
      _scanFolders = await _repository.getSavedFolders();
      _excludedFolders = await _repository.getExcludedFolders();
      _filterShortAudio = await _repository.getFilterShortAudio();

      // 请求系统媒体库权限
      final hasPermission = await requestStoragePermission();
      if (!hasPermission && !_scanFolders.any(FolderPickerService.isTreeUri)) {
        _error = '需要存储权限才能扫描本地音乐';
        return;
      }

      // 扫描（传入排除文件夹）
      final songs = await _repository.scanSongs(
        customFolders: _scanFolders,
        excludedFolders: _excludedFolders,
      );

      // 清除封面缓存（重新扫描后旧缓存失效）
      LocalArtworkCache().clear();

      // 构建分类
      // 扫描期间可能移除文件夹，完成时使用最新排除配置再过滤。
      _excludedFolders = await _repository.getExcludedFolders();
      _indexedSongs = _repository.filterSongs(
        songs,
        excludedFolders: _excludedFolders,
      );
      _rebuildCategories();

      // 持久化本次扫描结果，下次启动直接恢复
      await _repository.saveSongs(_indexedSongs);

      // 触发本地歌曲的在线信息自动匹配（引擎内部有开关与去重，重复调用安全）
      unawaited(SongMatchProvider.instance?.onLibraryUpdated(_indexedSongs)
          .catchError((Object error) {
        debugPrint('[LibraryScan] 在线匹配失败: $error');
      }));
      debugPrint('[LibraryScan] 完成，歌曲数=${_indexedSongs.length}');
    } catch (e, stack) {
      _error = e.toString();
      debugPrint('[LibraryScan] 扫描失败: $e\n$stack');
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  /// 通过文件夹选择器添加扫描目录。
  Future<bool> addScanFolder() async {
    final path = await FolderPickerService.pickFolder();
    if (path == null) return false;

    await _repository.addFolder(path);
    _scanFolders = await _repository.getSavedFolders();
    _excludedFolders = await _repository.getExcludedFolders();
    notifyListeners();
    return true;
  }

  /// 移除扫描目录。
  Future<void> removeScanFolder(String path) async {
    await _repository.removeFolder(path);
    _scanFolders = await _repository.getSavedFolders();
    notifyListeners();
  }

  /// 通过文件夹选择器添加排除目录。
  Future<bool> addExcludedFolder() async {
    final path = await FolderPickerService.pickFolder();
    if (path == null) return false;

    await _repository.addExcludedFolder(path);
    _excludedFolders = await _repository.getExcludedFolders();
    _indexedSongs = _repository.filterSongs(
      _indexedSongs,
      excludedFolders: _excludedFolders,
    );
    await _repository.saveSongs(_indexedSongs);
    _rebuildCategories();
    notifyListeners();
    return true;
  }

  /// 移除排除目录。
  Future<void> removeExcludedFolder(String path) async {
    await _repository.removeExcludedFolder(path);
    _excludedFolders = await _repository.getExcludedFolders();
    notifyListeners();
  }

  /// 获取指定文件夹中的歌曲。
  List<Song> getSongsInFolder(String folderPath) {
    return _songs.where((s) {
      if (s.localPath == null) return false;
      // 与 buildFolders 一致：Windows 路径先统一分隔符，避免详情构建越界。
      final localPath = s.localPath!.replaceAll('\\', '/');
      final songDir = s.folderPath ??
          localPath.substring(0, localPath.lastIndexOf('/'));
      return songDir == folderPath;
    }).toList();
  }

  /// 获取指定专辑中的歌曲。
  List<Song> getSongsInAlbum(String albumName) {
    return _songs.where((s) => s.album == albumName).toList();
  }

  /// 获取指定艺术家的歌曲。
  List<Song> getSongsByArtist(String artistName) {
    return _songs.where((s) => s.artist == artistName).toList();
  }

  List<Song> searchLocal(String query) {
    if (query.isEmpty) return _songs;
    final lowerQuery = query.toLowerCase();
    return _songs.where((song) {
      return song.title.toLowerCase().contains(lowerQuery) ||
          song.artist.toLowerCase().contains(lowerQuery) ||
          song.album.toLowerCase().contains(lowerQuery);
    }).toList();
  }
}
