import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';

bool _isNativeMobile() {
  if (kIsWeb) return false;
  try {
    return Platform.isAndroid || Platform.isIOS;
  } catch (_) {
    return false;
  }
}

class LocalMusicRepository {
  OnAudioQuery? _audioQuery;

  OnAudioQuery get _query {
    _audioQuery ??= OnAudioQuery();
    return _audioQuery!;
  }

  Future<List<Song>> scanSongs() async {
    if (!_isNativeMobile()) return [];

    try {
      final songs = await _query.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
      );

      return songs.map((audio) {
        return Song(
          id: audio.id.toString(),
          title: audio.title.isNotEmpty ? audio.title : '未知歌曲',
          artist: audio.artist?.isNotEmpty == true ? audio.artist! : '未知歌手',
          album: audio.album?.isNotEmpty == true ? audio.album! : '未知专辑',
          duration: Duration(milliseconds: audio.duration ?? 0),
          localPath: audio.data,
          artworkUri: null,
          isOnline: false,
          albumId: audio.albumId?.toString(),
          artistId: audio.artistId?.toString(),
        );
      }).toList();
    } catch (e) {
      debugPrint('scanSongs error: $e');
      return [];
    }
  }

  Future<List<Album>> scanAlbums() async {
    if (!_isNativeMobile()) return [];

    try {
      final albums = await _query.queryAlbums(
        sortType: AlbumSortType.ALBUM,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
      );

      return albums.map((album) {
        return Album(
          id: album.id.toString(),
          name: album.album.isNotEmpty ? album.album : '未知专辑',
          artist: album.artist?.isNotEmpty == true ? album.artist! : '未知歌手',
          artworkUri: null,
          songCount: album.numOfSongs,
        );
      }).toList();
    } catch (e) {
      debugPrint('scanAlbums error: $e');
      return [];
    }
  }

  Future<List<Artist>> scanArtists() async {
    if (!_isNativeMobile()) return [];

    try {
      final artists = await _query.queryArtists(
        sortType: ArtistSortType.ARTIST,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
      );

      return artists.map((artist) {
        return Artist(
          id: artist.id.toString(),
          name: artist.artist.isNotEmpty ? artist.artist : '未知歌手',
          artworkUri: null,
          songCount: artist.numberOfTracks ?? 0,
          albumCount: artist.numberOfAlbums ?? 0,
        );
      }).toList();
    } catch (e) {
      debugPrint('scanArtists error: $e');
      return [];
    }
  }

  Future<Uint8List?> getArtwork(int id, ArtworkType type) async {
    if (!_isNativeMobile()) return null;
    try {
      return await _query.queryArtwork(
        id,
        type,
        size: 200,
      );
    } catch (e) {
      debugPrint('getArtwork error: $e');
      return null;
    }
  }
}
