import 'package:flutter/foundation.dart';

import '../data/models/song.dart';
import '../data/repositories/favorites_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';

class FavoritesProvider extends ChangeNotifier {
  final FavoritesRepository _repository = FavoritesRepository();
  List<Song> _favorites = [];
  Set<String> _favoriteIds = {};
  bool _isLoading = false;
  KugouPlaylistBrief? _myFavoritePlaylist;

  List<Song> get favorites => _favorites;
  Set<String> get favoriteIds => _favoriteIds;
  bool get isLoading => _isLoading;

  FavoritesProvider() {
    loadFavorites();
  }

  Future<void> loadFavorites() async {
    _isLoading = true;
    notifyListeners();
    _favorites = await _repository.getFavorites();
    _favoriteIds = _favorites.map((s) => s.id).toSet();
    await _syncFavoritesFromKugou();
    _isLoading = false;
    notifyListeners();
  }

  bool isFavorite(String songId) => _favoriteIds.contains(songId);

  /// 同步收藏 ID 集合（用于"我喜欢"歌单加载后同步本地状态）
  void syncFavoriteIds(Set<String> ids) {
    _favoriteIds = ids;
    notifyListeners();
  }

  /// 批量添加收藏 ID（用于"我喜欢"歌单加载时同步）
  void addFavoriteIds(List<String> ids) {
    _favoriteIds.addAll(ids);
    notifyListeners();
  }

  Future<KugouPlaylistBrief?> _getMyFavoritePlaylist() async {
    if (_myFavoritePlaylist != null) return _myFavoritePlaylist;
    try {
      final api = KugouApiClient();
      final result = await api.getUserPlaylist(pagesize: 50);
      if (result != null && result['data'] != null) {
        final data = result['data'];
        final info = data is Map ? data['info'] as List<dynamic>? : null;
        if (info != null) {
          for (final item in info) {
            if (item is Map<String, dynamic>) {
              final name = item['name']?.toString() ?? '';
              final isDef = item['is_def'];
              if (name == '我喜欢' || isDef == 2) {
                final brief = KugouPlaylistBrief.fromJson(item);
                _myFavoritePlaylist = brief;
                return _myFavoritePlaylist;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to get favorite playlist: $e');
    }
    return null;
  }

  Future<void> _syncFavoritesFromKugou() async {
    try {
      final playlist = await _getMyFavoritePlaylist();
      if (playlist == null) return;
      final api = KugouApiClient();
      final result = await api.getPlaylistSongs(
        playlist.globalCollectionId ?? playlist.id,
        pagesize: 500,
      );
      if (result != null && result.songs.isNotEmpty) {
        for (final s in result.songs) {
          _favoriteIds.add(s.hash);
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Failed to sync favorites from Kugou: $e');
    }
  }

  Future<void> toggleFavorite(Song song) async {
    final api = KugouApiClient();
    final isLoggedIn = api.isLoggedIn;

    // 动态获取"我喜欢"歌单的 listId
    final playlist = await _getMyFavoritePlaylist();
    final listid = playlist?.listId ?? '2';

    if (_favoriteIds.contains(song.id)) {
      // 先调 API，成功后再更新本地状态
      if (isLoggedIn) {
        try {
          // 优先用 fileId（歌单里的记录ID），没有再用 hash 兜底
          final fileIds = song.fileId != null && song.fileId! > 0
              ? song.fileId.toString()
              : song.id;
          await api.deletePlaylistTracks(listid, fileIds);
        } catch (e) {
          debugPrint('Remove from Kugou favorite failed: $e');
          notifyListeners();
          return;
        }
      }
      _favoriteIds.remove(song.id);
      _favorites.removeWhere((s) => s.id == song.id);
      await _repository.removeFavorite(song.id);
    } else {
      _favoriteIds.add(song.id);
      _favorites.insert(0, song);
      await _repository.addFavorite(song);

      if (isLoggedIn) {
        try {
          final data =
              '${song.title}|${song.id}|${song.albumId ?? 0}|${int.tryParse(song.albumAudioId ?? '') ?? 0}';
          await api.addPlaylistTracks(listid, data);
        } catch (e) {
          debugPrint('Add to Kugou favorite failed: $e');
        }
      }
    }
    notifyListeners();
  }

  Future<void> removeFavorite(String songId) async {
    await _repository.removeFavorite(songId);
    _favoriteIds.remove(songId);
    _favorites.removeWhere((s) => s.id == songId);
    notifyListeners();
  }

  Future<Map<String, dynamic>?> createPlaylist(String name) async {
    final api = KugouApiClient();
    final userid = api.userid;
    if (userid == null) return null;
    return await api.createPlaylist(
      name,
      listCreateUserid: userid,
    );
  }

  Future<Map<String, dynamic>?> addTrackToPlaylist(
    String listid,
    Song song,
  ) async {
    final api = KugouApiClient();
    final data = '${song.title}|${song.id}';
    return await api.addPlaylistTracks(listid, data);
  }

  Future<Map<String, dynamic>?> removeTrackFromPlaylist(
    String listid,
    String fileid,
  ) async {
    final api = KugouApiClient();
    return await api.deletePlaylistTracks(listid, fileid);
  }

  Future<Map<String, dynamic>?> deletePlaylist(String listid, {int type = 1}) async {
    final api = KugouApiClient();
    return await api.deletePlaylist(listid, type: type);
  }

  Future<Map<String, dynamic>?> getUserPlaylists({
    int page = 1,
    int pagesize = 30,
  }) async {
    final api = KugouApiClient();
    return await api.getUserPlaylist(page: page, pagesize: pagesize);
  }
}
