import 'package:flutter/foundation.dart';

import '../data/models/song.dart';
import '../data/repositories/favorites_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';

class FavoritesProvider extends ChangeNotifier {
  final FavoritesRepository _repository = FavoritesRepository();
  List<Song> _favorites = [];
  Set<String> _favoriteIds = {};
  bool _isLoading = false;

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
    _isLoading = false;
    notifyListeners();
  }

  bool isFavorite(String songId) => _favoriteIds.contains(songId);

  Future<void> toggleFavorite(Song song) async {
    if (_favoriteIds.contains(song.id)) {
      await _repository.removeFavorite(song.id);
      _favoriteIds.remove(song.id);
      _favorites.removeWhere((s) => s.id == song.id);
    } else {
      await _repository.addFavorite(song);
      _favoriteIds.add(song.id);
      _favorites.insert(0, song);
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

  Future<Map<String, dynamic>?> deletePlaylist(String listid) async {
    final api = KugouApiClient();
    return await api.deletePlaylist(listid);
  }

  Future<Map<String, dynamic>?> getUserPlaylists({
    int page = 1,
    int pagesize = 30,
  }) async {
    final api = KugouApiClient();
    return await api.getUserPlaylist(page: page, pagesize: pagesize);
  }
}
