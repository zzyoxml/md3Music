
import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';

class LocalMusicRepository {
  Future<List<Song>> scanSongs() async {
    return [];
  }

  Future<List<Album>> scanAlbums() async {
    return [];
  }

  Future<List<Artist>> scanArtists() async {
    return [];
  }

  Future<Uint8List?> getArtwork(int id, int type) async {
    return null;
  }
}
