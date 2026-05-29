import 'package:flutter/foundation.dart';

import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/song.dart';
import '../data/repositories/local_music_repository.dart';

class LibraryProvider extends ChangeNotifier {
  final LocalMusicRepository _repository = LocalMusicRepository();

  List<Song> _songs = [];
  List<Album> _albums = [];
  List<Artist> _artists = [];
  bool _isLoading = false;
  String? _error;

  List<Song> get songs => _songs;
  List<Album> get albums => _albums;
  List<Artist> get artists => _artists;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> loadLocalMusic() async {
    if (kIsWeb) {
      _songs = [];
      _albums = [];
      _artists = [];
      return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final songs = await _repository.scanSongs();
      final albums = await _repository.scanAlbums();
      final artists = await _repository.scanArtists();

      _songs = songs;
      _albums = albums;
      _artists = artists;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
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
