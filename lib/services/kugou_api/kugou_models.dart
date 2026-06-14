import '../../data/models/album.dart';
import '../../data/models/artist.dart';
import '../../data/models/playlist.dart';
import '../../data/models/song.dart';

class KugouSearchResult {
  final List<KugouSongDetail> songs;
  final List<KugouArtistBrief> artists;
  final List<KugouAlbumBrief> albums;
  final List<KugouPlaylistBrief> playlists;
  final int total;

  const KugouSearchResult({
    this.songs = const [],
    this.artists = const [],
    this.albums = const [],
    this.playlists = const [],
    this.total = 0,
  });

  factory KugouSearchResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    List<KugouSongDetail> songs = [];
    List<KugouArtistBrief> artists = [];
    List<KugouAlbumBrief> albums = [];
    List<KugouPlaylistBrief> playlists = [];

    final list = data['lists'] ?? data['songs'] ?? data['info'] ?? [];
    if (list is List && list.isNotEmpty) {
      final first = list.first;
      if (first is Map<String, dynamic>) {
        if (first.containsKey('hash') ||
            first.containsKey('FileHash') ||
            first.containsKey('songname') ||
            first.containsKey('SongName')) {
          songs = list
              .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
              .toList();
        } else if (first.containsKey('albumid') ||
            first.containsKey('AlbumID') ||
            first.containsKey('album_name') ||
            first.containsKey('AlbumName')) {
          albums = list
              .map((e) => KugouAlbumBrief.fromJson(e as Map<String, dynamic>))
              .toList();
        } else if (first.containsKey('singerid') ||
            first.containsKey('SingerID') ||
            first.containsKey('author_name')) {
          artists = list
              .map((e) => KugouArtistBrief.fromJson(e as Map<String, dynamic>))
              .toList();
        } else if (first.containsKey('specialid') ||
            first.containsKey('global_collection_id') ||
            first.containsKey('specialname')) {
          playlists = list
              .map(
                (e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>),
              )
              .toList();
        } else {
          songs = list
              .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
    }

    return KugouSearchResult(
      songs: songs,
      artists: artists,
      albums: albums,
      playlists: playlists,
      total: _parseInt(data['total'] ?? data['total_count'] ?? 0),
    );
  }
}

class KugouArtistBrief {
  final String id;
  final String name;
  final String? avatarUrl;

  const KugouArtistBrief({
    required this.id,
    required this.name,
    this.avatarUrl,
  });

  factory KugouArtistBrief.fromJson(Map<String, dynamic> json) {
    return KugouArtistBrief(
      id: _str(
        json['singerid'] ??
            json['artist_id'] ??
            json['AuthorID'] ??
            json['id'] ??
            '',
      ),
      name: _str(
        json['singername'] ??
            json['artist_name'] ??
            json['SingerName'] ??
            json['author_name'] ??
            json['name'] ??
            '',
      ),
      avatarUrl: _resolveArtworkUri(
        json['imgurl'] ??
            json['avatar_url'] ??
            json['img'] ??
            json['pic'] ??
            json['ImgUrl'],
      ),
    );
  }

  Artist toArtist() {
    return Artist(
      id: id,
      name: name,
      artworkUri: avatarUrl,
      songCount: 0,
      albumCount: 0,
    );
  }
}

class KugouAlbumBrief {
  final String id;
  final String name;
  final String? coverUrl;
  final String? artistName;

  const KugouAlbumBrief({
    required this.id,
    required this.name,
    this.coverUrl,
    this.artistName,
  });

  factory KugouAlbumBrief.fromJson(Map<String, dynamic> json) {
    return KugouAlbumBrief(
      id: _str(
        json['albumid'] ??
            json['album_id'] ??
            json['AlbumID'] ??
            json['id'] ??
            '',
      ),
      name: _str(
        json['album_name'] ??
            json['AlbumName'] ??
            json['albumname'] ??
            json['name'] ??
            '',
      ),
      coverUrl: _resolveArtworkUri(
        json['imgurl'] ??
            json['cover_url'] ??
            json['img'] ??
            json['pic'] ??
            json['ImgUrl'],
      ),
      artistName: _strNull(
        json['singername'] ??
            json['artist_name'] ??
            json['SingerName'] ??
            json['author_name'],
      ),
    );
  }

  Album toAlbum() {
    return Album(
      id: id,
      name: name,
      artist: artistName ?? '',
      artworkUri: coverUrl,
      songCount: 0,
    );
  }
}

class KugouPlaylistBrief {
  final String id;
  final String name;
  final String? coverUrl;
  final int songCount;
  final String? globalCollectionId;
  final String listId;
  final String? listCreateUserid;
  final String? listCreateListid;

  const KugouPlaylistBrief({
    required this.id,
    required this.name,
    this.coverUrl,
    this.songCount = 0,
    this.globalCollectionId,
    this.listId = '',
    this.listCreateUserid,
    this.listCreateListid,
  });

  factory KugouPlaylistBrief.fromJson(Map<String, dynamic> json) {
    return KugouPlaylistBrief(
      id: _str(
        json['specialid'] ?? json['id'] ?? json['global_collection_id'] ?? '',
      ),
      name: _str(json['specialname'] ?? json['name'] ?? ''),
      coverUrl: _resolveArtworkUri(
        json['imgurl'] ?? json['img'] ?? json['pic'] ?? json['cover_url'],
      ),
      songCount: _parseInt(
        json['songcount'] ?? json['song_count'] ?? json['count'] ?? 0,
      ),
      globalCollectionId: _strNull(json['global_collection_id']),
      listId: _str(json['listid'] ?? ''),
      listCreateUserid: _strNull(json['list_create_userid']),
      listCreateListid: _strNull(json['list_create_listid']),
    );
  }

  Playlist toPlaylist() {
    return Playlist(
      id: globalCollectionId ?? id,
      name: name,
      artworkUri: coverUrl,
      songCount: songCount,
      songs: [],
      listCreateUserid: listCreateUserid,
      listCreateListid: listCreateListid,
    );
  }
}

class KugouSongDetail {
  final String hash;
  final String? albumId;
  final String? albumName;
  final String? artistId;
  final String? artistName;
  final String songName;
  final int duration;
  final String? sqHash;
  final String? hqHash;
  final String? hash320;
  final String? hash128;
  final String? lyrics;
  final String? albumAudioId;
  final String? artworkUri;
  final String? fileName;
  final int privilege;
  final String? albumAudioId2;
  final String? songId;

  const KugouSongDetail({
    required this.hash,
    this.albumId,
    this.albumName,
    this.artistId,
    this.artistName,
    required this.songName,
    this.duration = 0,
    this.sqHash,
    this.hqHash,
    this.hash320,
    this.hash128,
    this.lyrics,
    this.albumAudioId,
    this.artworkUri,
    this.fileName,
    this.privilege = 0,
    this.albumAudioId2,
    this.songId,
  });

  factory KugouSongDetail.fromJson(Map<String, dynamic> json) {
    // 处理 singerinfo 数组格式
    String? artistName;
    final singerinfo = json['singerinfo'];
    if (singerinfo is List && singerinfo.isNotEmpty) {
      final firstSinger = singerinfo.first;
      if (firstSinger is Map) {
        artistName = firstSinger['name']?.toString();
      }
    }

    return KugouSongDetail(
      hash: _str(
        json['hash'] ??
            json['FileHash'] ??
            json['Hash128'] ??
            json['SQFileHash'] ??
            json['HQFileHash'] ??
            json['trans_param']?['ogg_128_hash'] ??
            '',
      ),
      albumId: _strNull(json['album_id'] ?? json['AlbumID'] ?? json['albumid']),
      albumName: _strNull(
        json['album_name'] ??
            json['AlbumName'] ??
            json['albumname'] ??
            json['albuminfo']?['name'],
      ),
      artistId: _extractFirst(
        json['SingerId'] ??
            json['singerid'] ??
            json['SingerID'] ??
            json['AuthorID'] ??
            json['artist_id'],
      ),
      artistName:
          artistName ??
          _strNull(
            json['author_name'] ??
                json['SingerName'] ??
                json['artist_name'] ??
                json['singername'],
          ),
      songName: _str(
        json['songname'] ??
            json['SongName'] ??
            json['name'] ??
            json['ori_audio_name'] ??
            json['FileName'] ??
            json['filename'] ??
            '',
      ),
      duration: _parseInt(
        json['time_length'] ??
            json['HQDuration'] ??
            json['Duration'] ??
            json['duration'] ??
            json['SuperDuration'] ??
            json['timelength'] ??
            (() {
              final tl = json['timelen'];
              if (tl != null) return (tl as int) ~/ 1000; // 歌单API的timelen单位为毫秒
              final ai = json['audio_info'] as Map<String, dynamic>?;
              if (ai != null) {
                final d =
                    ai['duration_flac'] as int? ??
                    ai['duration_320'] as int? ??
                    ai['duration_high'] as int? ??
                    ai['duration_128'] as int?;
                if (d != null) return d ~/ 1000; // 排行榜API单位为毫秒
              }
              return null;
            })(),
      ),
      sqHash: _strNull(
        json['hash_flac'] ??
            json['SQHash'] ??
            json['sq_hash'] ??
            json['SQFileHash'],
      ),
      hqHash: _strNull(
        json['hash_320'] ??
            json['HQHash'] ??
            json['hq_hash'] ??
            json['HQFileHash'],
      ),
      hash320: _strNull(
        json['hash_320'] ??
            json['320Hash'] ??
            json['Hash320'] ??
            json['trans_param']?['ogg_320_hash'],
      ),
      hash128: _strNull(
        json['hash_128'] ??
            json['128Hash'] ??
            json['Hash128'] ??
            json['trans_param']?['ogg_128_hash'],
      ),
      lyrics: _strNull(json['lyrics'] ?? json['Lyrics']),
      albumAudioId: _strNull(
        json['album_audio_id'] ??
            json['AlbumAudioID'] ??
            json['MixSongID'] ??
            json['mixsongid'] ??
            json['add_mixsongid'] ??
            json['Audioid'] ??
            json['audio_id'],
      ),
      artworkUri: _resolveArtworkUri(
        json['sizable_cover'] ??
            json['Image'] ??
            json['ImgUrl'] ??
            json['img'] ??
            json['pic'] ??
            json['cover'] ??
            json['trans_param']?['union_cover'],
      ),
      fileName: _strNull(
        json['filename'] ?? json['FileName'] ?? json['ori_audio_name'],
      ),
      privilege: _parseInt(json['privilege'] ?? 0),
      albumAudioId2: _strNull(json['album_audio_id']),
      songId: _strNull(
        json['songid'] ?? json['song_id'] ?? json['SongId'] ?? json['SongID'],
      ),
    );
  }

  Song toSong() {
    return Song(
      id: hash,
      title: songName,
      artist: artistName ?? '',
      album: albumName ?? '',
      duration: Duration(seconds: duration),
      isOnline: true,
      albumId: albumId,
      artistId: artistId,
      artworkUri: artworkUri,
      albumAudioId: albumAudioId,
    );
  }
}

class KugouPlayUrl {
  final String url;
  final int fileSize;
  final int bitRate;
  final String quality;

  const KugouPlayUrl({
    required this.url,
    this.fileSize = 0,
    this.bitRate = 0,
    required this.quality,
  });

  factory KugouPlayUrl.fromJson(Map<String, dynamic> json) {
    dynamic rawUrl = json['url'] ?? json['play_url'] ?? '';
    String url;
    if (rawUrl is List && rawUrl.isNotEmpty) {
      url = rawUrl.first.toString();
    } else {
      url = rawUrl.toString();
    }
    return KugouPlayUrl(
      url: url,
      fileSize: _parseInt(
        json['fileSize'] ??
            json['file_size'] ??
            json['FileSize'] ??
            json['filesize'] ??
            0,
      ),
      bitRate: _parseInt(
        json['bitRate'] ??
            json['bit_rate'] ??
            json['BitRate'] ??
            json['bitrate'] ??
            0,
      ),
      quality: _str(json['quality'] ?? '128'),
    );
  }
}

class KugouRankList {
  final List<KugouRank> ranks;

  const KugouRankList({this.ranks = const []});

  factory KugouRankList.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['info'] ?? data['list'] ?? data['ranks'] ?? [];
    return KugouRankList(
      ranks: (list as List<dynamic>)
          .map((e) => KugouRank.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class KugouRank {
  final String id;
  final String name;
  final String? coverUrl;
  final int songCount;

  const KugouRank({
    required this.id,
    required this.name,
    this.coverUrl,
    this.songCount = 0,
  });

  factory KugouRank.fromJson(Map<String, dynamic> json) {
    return KugouRank(
      id: _str(
        json['rankid'] ??
            json['id'] ??
            json['rank_id'] ??
            json['classify'] ??
            '',
      ),
      name: _str(json['rankname'] ?? json['name'] ?? ''),
      coverUrl: _resolveArtworkUri(
        json['imgurl'] ??
            json['img_9'] ??
            json['banner_9'] ??
            json['bannerurl'] ??
            json['cover_url'] ??
            json['ImgUrl'],
      ),
      songCount: _parseInt(json['songcount'] ?? json['song_count'] ?? 0),
    );
  }

  Album toAlbum() {
    return Album(
      id: id,
      name: name,
      artist: '',
      artworkUri: coverUrl,
      songCount: songCount,
    );
  }
}

class KugouPlaylist {
  final String id;
  final String name;
  final String? coverUrl;
  final String? creator;
  final int songCount;
  final String? description;
  final List<KugouSongDetail> songs;

  const KugouPlaylist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.creator,
    this.songCount = 0,
    this.description,
    this.songs = const [],
  });

  factory KugouPlaylist.fromJson(Map<String, dynamic> json) {
    return KugouPlaylist(
      id: _str(
        json['specialid'] ?? json['id'] ?? json['global_collection_id'] ?? '',
      ),
      name: _str(json['specialname'] ?? json['name'] ?? ''),
      coverUrl: _resolveArtworkUri(
        json['imgurl'] ?? json['img'] ?? json['pic'] ?? json['cover_url'],
      ),
      creator: _strNull(json['nickname'] ?? json['creator']),
      songCount: _parseInt(
        json['songcount'] ?? json['song_count'] ?? json['count'] ?? 0,
      ),
      description: _strNull(json['intro'] ?? json['description']),
      songs:
          (json['songs'] as List<dynamic>?)
              ?.map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Playlist toPlaylist() {
    return Playlist(
      id: id,
      name: name,
      artworkUri: coverUrl,
      songCount: songCount,
      creator: creator,
      description: description,
      songs: songs.map((e) => e.toSong()).toList(),
    );
  }
}

class KugouCommentList {
  final List<KugouComment> comments;
  final int total;

  const KugouCommentList({this.comments = const [], this.total = 0});

  factory KugouCommentList.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['list'] ?? data['comments'] ?? [];
    return KugouCommentList(
      comments: (list as List<dynamic>)
          .map((e) => KugouComment.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: _parseInt(
        data['total'] ?? data['count'] ?? data['comment_count'] ?? 0,
      ),
    );
  }
}

class KugouComment {
  final String id;
  final String username;
  final String? avatar;
  final String content;
  final int time;
  final int likes;

  const KugouComment({
    required this.id,
    required this.username,
    this.avatar,
    required this.content,
    this.time = 0,
    this.likes = 0,
  });

  factory KugouComment.fromJson(Map<String, dynamic> json) {
    return KugouComment(
      id: _str(json['commentid'] ?? json['id'] ?? ''),
      username: _str(
        json['user_name'] ?? json['username'] ?? json['nickname'] ?? '',
      ),
      avatar: _strNull(json['user_pic'] ?? json['user_img'] ?? json['avatar']),
      content: _str(json['content'] ?? json['comment_text'] ?? ''),
      time: _parseInt(json['createtime'] ?? json['time'] ?? 0),
      likes: _parseInt(json['like_count'] ?? json['likes'] ?? 0),
    );
  }
}

class KugouLyric {
  final String content;
  final String? decodedContent;
  final String? translatedContent;

  const KugouLyric({
    required this.content,
    this.decodedContent,
    this.translatedContent,
  });

  factory KugouLyric.fromJson(Map<String, dynamic> json) {
    return KugouLyric(
      content: _str(
        json['content'] ?? json['lrcContent'] ?? json['lyrics'] ?? '',
      ),
      decodedContent: _strNull(
        json['decodeContent'] ?? json['decoded_content'] ?? json['lrcContent'],
      ),
      translatedContent: _strNull(
        json['translated_content'] ?? json['trans'] ?? json['lrcContentChi'],
      ),
    );
  }

  String get displayLyric => decodedContent ?? content;
}

class KugouArtistDetail {
  final String id;
  final String name;
  final String? avatarUrl;
  final String? description;
  final int songCount;
  final int albumCount;

  const KugouArtistDetail({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.description,
    this.songCount = 0,
    this.albumCount = 0,
  });

  factory KugouArtistDetail.fromJson(Map<String, dynamic> json) {
    return KugouArtistDetail(
      id: _str(
        json['singerid'] ??
            json['artist_id'] ??
            json['AuthorID'] ??
            json['id'] ??
            '',
      ),
      name: _str(
        json['singername'] ??
            json['artist_name'] ??
            json['SingerName'] ??
            json['name'] ??
            '',
      ),
      avatarUrl: _resolveArtworkUri(
        json['imgurl'] ??
            json['img'] ??
            json['pic'] ??
            json['ImgUrl'] ??
            json['avatar_url'],
      ),
      description: _strNull(
        json['intro'] ?? json['description'] ?? json['desc'],
      ),
      songCount: _parseInt(json['songcount'] ?? json['song_count'] ?? 0),
      albumCount: _parseInt(json['albumcount'] ?? json['album_count'] ?? 0),
    );
  }

  Artist toArtist() {
    return Artist(
      id: id,
      name: name,
      artworkUri: avatarUrl,
      songCount: songCount,
      albumCount: albumCount,
    );
  }
}

class KugouArtistAlbums {
  final List<KugouAlbumBrief> albums;
  final int total;

  const KugouArtistAlbums({this.albums = const [], this.total = 0});

  factory KugouArtistAlbums.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['list'] ?? data['albums'] ?? data['info'] ?? [];
    return KugouArtistAlbums(
      albums: (list as List<dynamic>)
          .map((e) => KugouAlbumBrief.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: _parseInt(data['total'] ?? data['total_count'] ?? 0),
    );
  }
}

class KugouArtistAudios {
  final List<KugouSongDetail> songs;
  final int total;

  const KugouArtistAudios({this.songs = const [], this.total = 0});

  factory KugouArtistAudios.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
    return KugouArtistAudios(
      songs: (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: _parseInt(data['total'] ?? data['total_count'] ?? 0),
    );
  }
}

class KugouAlbumDetail {
  final String id;
  final String name;
  final String? coverUrl;
  final String? artistName;
  final String? description;
  final int songCount;
  final String? publishDate;

  const KugouAlbumDetail({
    required this.id,
    required this.name,
    this.coverUrl,
    this.artistName,
    this.description,
    this.songCount = 0,
    this.publishDate,
  });

  factory KugouAlbumDetail.fromJson(Map<String, dynamic> json) {
    return KugouAlbumDetail(
      id: _str(
        json['albumid'] ??
            json['album_id'] ??
            json['AlbumID'] ??
            json['id'] ??
            '',
      ),
      name: _str(
        json['album_name'] ??
            json['AlbumName'] ??
            json['albumname'] ??
            json['name'] ??
            '',
      ),
      coverUrl: _resolveArtworkUri(
        json['imgurl'] ?? json['img'] ?? json['pic'] ?? json['cover_url'],
      ),
      artistName: _strNull(
        json['singername'] ??
            json['SingerName'] ??
            json['author_name'] ??
            json['artist_name'],
      ),
      description: _strNull(
        json['intro'] ?? json['description'] ?? json['desc'],
      ),
      songCount: _parseInt(json['songcount'] ?? json['song_count'] ?? 0),
      publishDate: _strNull(
        json['publishtime'] ?? json['publish_date'] ?? json['PublishDate'],
      ),
    );
  }

  Album toAlbum() {
    return Album(
      id: id,
      name: name,
      artist: artistName ?? '',
      artworkUri: coverUrl,
      songCount: songCount,
    );
  }
}

class KugouAlbumSongs {
  final List<KugouSongDetail> songs;
  final int total;

  const KugouAlbumSongs({this.songs = const [], this.total = 0});

  factory KugouAlbumSongs.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
    return KugouAlbumSongs(
      songs: (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: _parseInt(data['total'] ?? data['total_count'] ?? 0),
    );
  }
}

class KugouPlaylistCategory {
  final List<KugouPlaylistBrief> playlistList;
  final bool hasNext;

  const KugouPlaylistCategory({
    this.playlistList = const [],
    this.hasNext = false,
  });

  factory KugouPlaylistCategory.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouPlaylistCategory(
      hasNext: _parseInt(data['has_next'] ?? json['has_next'] ?? 0) == 1,
      playlistList: _parsePlList(
        data['special_list'] ?? data['plist'] ?? data['list'] ?? [],
      ),
    );
  }
}

class KugouPlaylistCategoryItem {
  final String id;
  final String name;

  const KugouPlaylistCategoryItem({required this.id, required this.name});

  factory KugouPlaylistCategoryItem.fromJson(Map<String, dynamic> json) {
    return KugouPlaylistCategoryItem(
      id: _str(json['category_id'] ?? json['id'] ?? ''),
      name: _str(json['category_name'] ?? json['name'] ?? ''),
    );
  }
}

class KugouPlaylistSongs {
  final List<KugouSongDetail> songs;
  final int total;

  const KugouPlaylistSongs({this.songs = const [], this.total = 0});

  factory KugouPlaylistSongs.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
    return KugouPlaylistSongs(
      songs: (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: _parseInt(data['total'] ?? data['total_count'] ?? 0),
    );
  }
}

String _str(dynamic v) => v?.toString() ?? '';
String? _strNull(dynamic v) => v?.toString();
int _parseInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

String? _resolveArtworkUri(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  if (s.isEmpty) return null;
  return s.replaceAll('{size}', '400');
}

String? _extractFirst(dynamic v) {
  if (v == null) return null;
  if (v is List && v.isNotEmpty) return v.first?.toString();
  return v.toString();
}

List<KugouPlaylistBrief> _parsePlList(dynamic v) {
  if (v == null) return [];
  if (v is List) {
    return v
        .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
        .toList();
  }
  return [];
}

class KugouQrKey {
  final String? qrcode;
  final String? qrcodeImg;

  const KugouQrKey({this.qrcode, this.qrcodeImg});

  factory KugouQrKey.fromJson(Map<String, dynamic> json) {
    return KugouQrKey(
      qrcode: _strNull(json['qrcode']),
      qrcodeImg: _strNull(json['qrcode_img']),
    );
  }
}

class KugouQrCreate {
  final String? url;
  final String? base64;

  const KugouQrCreate({this.url, this.base64});

  factory KugouQrCreate.fromJson(Map<String, dynamic> json) {
    return KugouQrCreate(
      url: _strNull(json['url']),
      base64: _strNull(json['base64']),
    );
  }
}

class KugouQrCheck {
  final int? status;
  final String? token;
  final String? userid;
  final String? vipToken;
  final Map<String, dynamic>? data;

  const KugouQrCheck({
    this.status,
    this.token,
    this.userid,
    this.vipToken,
    this.data,
  });

  factory KugouQrCheck.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouQrCheck(
      status: _parseInt(data['status']),
      token: _strNull(data['token']),
      userid: _strNull(data['userid']),
      vipToken: _strNull(data['vip_token']),
      data: data,
    );
  }
}

class KugouQuality {
  KugouQuality._();

  static const String standard = '128';
  static const String high = '320';
  static const String lossless = 'flac';
  static const String master = 'hi-res';
}

class KugouUserDetail {
  final String? nickname;
  final String? avatar;
  final String? userid;
  final String? username;
  final Map<String, dynamic>? rawData;

  const KugouUserDetail({
    this.nickname,
    this.avatar,
    this.userid,
    this.username,
    this.rawData,
  });

  factory KugouUserDetail.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouUserDetail(
      nickname: _strNull(data['nickname'] ?? data['username'] ?? data['name']),
      avatar: _resolveArtworkUri(data['avatar'] ?? data['img'] ?? data['pic']),
      userid: _strNull(data['userid'] ?? data['userId'] ?? data['id']),
      username: _strNull(data['username'] ?? data['name']),
      rawData: data,
    );
  }
}

class KugouUserVipDetail {
  final String? nickname;
  final int? vipLevel;
  final bool isVip;
  final String? expireTime;

  const KugouUserVipDetail({
    this.nickname,
    this.vipLevel,
    this.isVip = false,
    this.expireTime,
  });

  factory KugouUserVipDetail.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;

    // 实际结构: data.is_vip (总开关), data.busi_vip[] (各业务线, 含 product_type, vip_end_time)
    final busiList = data['busi_vip'];
    bool isVip = data['is_vip'] == 1;
    String? expireTime;
    if (busiList is List) {
      DateTime? latest;
      for (final b in busiList) {
        if (b is Map<String, dynamic> && b['is_vip'] == 1) {
          isVip = true;
          final t = b['vip_end_time']?.toString();
          if (t != null && t.isNotEmpty) {
            final dt = DateTime.tryParse(t.replaceFirst(' ', 'T'));
            if (dt != null && (latest == null || dt.isAfter(latest))) {
              latest = dt;
            }
          }
        }
      }
      if (latest != null) {
        expireTime =
            '${latest.year.toString().padLeft(4, '0')}-${latest.month.toString().padLeft(2, '0')}-${latest.day.toString().padLeft(2, '0')}';
      }
    }

    return KugouUserVipDetail(
      nickname: _strNull(data['nickname']),
      vipLevel: _parseInt(data['vip_level'] ?? data['vip_type']),
      isVip: isVip,
      expireTime: expireTime,
    );
  }
}

class KugouSongClimax {
  final String? climaxStart;
  final String? climaxEnd;
  final String? startTime;
  final String? endTime;

  const KugouSongClimax({
    this.climaxStart,
    this.climaxEnd,
    this.startTime,
    this.endTime,
  });

  factory KugouSongClimax.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouSongClimax(
      climaxStart: _strNull(data['climax_start'] ?? data['climaxStart']),
      climaxEnd: _strNull(data['climax_end'] ?? data['climaxEnd']),
      startTime: _strNull(data['start_time'] ?? data['startTime']),
      endTime: _strNull(data['end_time'] ?? data['endTime']),
    );
  }
}

class KugouSongRanking {
  final int? rank;
  final int? score;
  final String? rankType;

  const KugouSongRanking({this.rank, this.score, this.rankType});

  factory KugouSongRanking.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouSongRanking(
      rank: _parseInt(data['rank'] ?? data['rankNum']),
      score: _parseInt(data['score']),
      rankType: _strNull(data['rank_type'] ?? data['rankType']),
    );
  }
}

class KugouFmInfo {
  final String id;
  final String name;
  final String? coverUrl;
  final String? desc;

  const KugouFmInfo({
    required this.id,
    required this.name,
    this.coverUrl,
    this.desc,
  });

  factory KugouFmInfo.fromJson(Map<String, dynamic> json) {
    return KugouFmInfo(
      id: _str(json['id'] ?? json['fm_id'] ?? ''),
      name: _str(json['name'] ?? json['fm_name'] ?? ''),
      coverUrl: _resolveArtworkUri(
        json['img'] ?? json['imgurl'] ?? json['cover'],
      ),
      desc: _strNull(json['desc'] ?? json['description']),
    );
  }
}

class KugouSceneInfo {
  final String id;
  final String name;
  final String? coverUrl;

  const KugouSceneInfo({required this.id, required this.name, this.coverUrl});

  factory KugouSceneInfo.fromJson(Map<String, dynamic> json) {
    return KugouSceneInfo(
      id: _str(json['id'] ?? json['scene_id'] ?? ''),
      name: _str(json['name'] ?? json['scene_name'] ?? ''),
      coverUrl: _resolveArtworkUri(
        json['img'] ?? json['imgurl'] ?? json['cover'],
      ),
    );
  }
}

class KugouThemeInfo {
  final String id;
  final String name;
  final String? coverUrl;
  final int songCount;

  const KugouThemeInfo({
    required this.id,
    required this.name,
    this.coverUrl,
    this.songCount = 0,
  });

  factory KugouThemeInfo.fromJson(Map<String, dynamic> json) {
    return KugouThemeInfo(
      id: _str(json['id'] ?? json['theme_id'] ?? ''),
      name: _str(json['name'] ?? json['theme_name'] ?? ''),
      coverUrl: _resolveArtworkUri(
        json['img'] ?? json['imgurl'] ?? json['cover'],
      ),
      songCount: _parseInt(json['songcount'] ?? json['song_count'] ?? 0),
    );
  }
}

class KugouSheetInfo {
  final String id;
  final String name;
  final String? coverUrl;
  final int songCount;

  const KugouSheetInfo({
    required this.id,
    required this.name,
    this.coverUrl,
    this.songCount = 0,
  });

  factory KugouSheetInfo.fromJson(Map<String, dynamic> json) {
    return KugouSheetInfo(
      id: _str(json['id'] ?? json['sheet_id'] ?? json['specialid'] ?? ''),
      name: _str(
        json['name'] ?? json['sheet_name'] ?? json['specialname'] ?? '',
      ),
      coverUrl: _resolveArtworkUri(
        json['img'] ?? json['imgurl'] ?? json['cover'],
      ),
      songCount: _parseInt(json['songcount'] ?? json['song_count'] ?? 0),
    );
  }
}

class KugouYouthChannel {
  final String id;
  final String name;
  final String? coverUrl;
  final String? desc;

  const KugouYouthChannel({
    required this.id,
    required this.name,
    this.coverUrl,
    this.desc,
  });

  factory KugouYouthChannel.fromJson(Map<String, dynamic> json) {
    return KugouYouthChannel(
      id: _str(json['id'] ?? json['channel_id'] ?? json['channelid'] ?? ''),
      name: _str(
        json['name'] ?? json['channel_name'] ?? json['channelname'] ?? '',
      ),
      coverUrl: _resolveArtworkUri(
        json['img'] ?? json['imgurl'] ?? json['cover'],
      ),
      desc: _strNull(json['desc'] ?? json['description']),
    );
  }
}

class KugouLongAudioAlbum {
  final String id;
  final String name;
  final String? coverUrl;
  final String? author;
  final int audioCount;

  const KugouLongAudioAlbum({
    required this.id,
    required this.name,
    this.coverUrl,
    this.author,
    this.audioCount = 0,
  });

  factory KugouLongAudioAlbum.fromJson(Map<String, dynamic> json) {
    return KugouLongAudioAlbum(
      id: _str(json['id'] ?? json['album_id'] ?? ''),
      name: _str(json['name'] ?? json['album_name'] ?? json['title'] ?? ''),
      coverUrl: _resolveArtworkUri(
        json['img'] ?? json['imgurl'] ?? json['cover'],
      ),
      author: _strNull(json['author'] ?? json['author_name']),
      audioCount: _parseInt(json['audio_count'] ?? json['audiocount'] ?? 0),
    );
  }
}
