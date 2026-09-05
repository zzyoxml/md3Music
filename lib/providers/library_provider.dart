import 'package:flutter/foundation.dart';

import '../core/services/folder_picker_service.dart';
import '../core/services/local_artwork_cache.dart';
import '../core/utils/permissions.dart';
import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/music_folder.dart';
import '../data/models/song.dart';
import '../data/repositories/local_music_repository.dart';

/// 调试日志辅助函数（编译时根据 debugPrint 过滤 release 模式输出）
void _log(String msg) {
  if (kDebugMode) debugPrint(msg);
}

class LibraryProvider extends ChangeNotifier {
  final LocalMusicRepository _repository = LocalMusicRepository();

  List<Song> _songs = [];
  List<Album> _albums = [];
  List<Artist> _artists = [];
  List<MusicFolder> _folders = [];
  List<String> _scanFolders = [];
  List<String> _excludedFolders = [];

  bool _isLoading = false;
  bool _isScanning = false;
  String? _error;
  String _searchQuery = '';

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
    _scanFolders = await _repository.getSavedFolders();
    _excludedFolders = await _repository.getExcludedFolders();
    notifyListeners();
  }

  /// 加载上次持久化的歌曲列表（用于 App 重启后立即显示）。
  ///
  /// 不会自动触发扫描；只有在用户没有缓存且有扫描文件夹时才提示。
  /// 同时加载已保存的扫描目录，保持状态一致。
  Future<void> loadSavedSongs() async {
    final cached = await _repository.getSavedSongs();
    if (cached.isEmpty) return;
    _songs = cached;
    _albums = _repository.buildAlbums(cached);
    _artists = _repository.buildArtists(cached);
    _folders = _repository.buildFolders(cached);
    _scanFolders = await _repository.getSavedFolders();
    _excludedFolders = await _repository.getExcludedFolders();
    notifyListeners();
    _log('[LibraryProvider] 已恢复 ${cached.length} 首缓存歌曲');
  }

  /// 扫描本地音乐（使用默认目录 + 用户选择的目录，排除用户指定的文件夹）。
  Future<void> loadLocalMusic() async {
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
      // 请求存储权限
      final hasPermission = await requestStoragePermission();
      if (!hasPermission) {
        _error = '需要存储权限才能扫描本地音乐';
        _isScanning = false;
        notifyListeners();
        return;
      }

      // 加载用户保存的扫描文件夹和排除文件夹
      _scanFolders = await _repository.getSavedFolders();
      _excludedFolders = await _repository.getExcludedFolders();

      // 扫描（传入排除文件夹）
      final songs = await _repository.scanSongs(
        customFolders: _scanFolders,
        excludedFolders: _excludedFolders,
      );

      // 清除封面缓存（重新扫描后旧缓存失效）
      LocalArtworkCache().clear();

      // 构建分类
      _songs = songs;
      _albums = _repository.buildAlbums(songs);
      _artists = _repository.buildArtists(songs);
      _folders = _repository.buildFolders(songs);

      // 持久化本次扫描结果，下次启动直接恢复
      await _repository.saveSongs(songs);

      _isScanning = false;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
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
      final songDir = s.localPath!.substring(0, s.localPath!.lastIndexOf('/'));
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
