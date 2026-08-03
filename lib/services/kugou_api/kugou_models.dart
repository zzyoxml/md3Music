import '../../data/models/album.dart';
import '../../data/models/artist.dart';
import '../../data/models/playlist.dart';
import '../../data/models/song.dart';

/// 归一化时长：酷狗不同接口返回的时长单位不一致（秒 / 毫秒）。
/// 超过 10000 秒（约 2.8 小时）视为毫秒，统一转换为秒。
int _normalizeDuration(int raw) {
  if (raw <= 0) return 0;
  if (raw > 10000) return raw ~/ 1000;
  return raw;
}

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
    // 去除 HTML 标签
    String cleanName(String? s) {
      if (s == null) return '';
      return s.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    }

    // 提取第一个歌手名（"周杰伦、袁咏琳" → "周杰伦"）
    String extractFirstName(String s) {
      if (s.isEmpty) return s;
      // 按 "、" 或 "," 分割，取第一个
      final parts = s.split(RegExp(r'[、,，]'));
      return parts.first.trim();
    }

    final rawName = cleanName(
      json['singername'] ??
          json['artist_name'] ??
          json['SingerName'] ??
          json['author_name'] ??
          json['name'] ??
          '',
    );

    final parsedId = _str(
      json['singerid'] ??
          json['artist_id'] ??
          json['AuthorID'] ??
          json['id'] ??
          json['mix_singer_id'] ??
          '',
    );

    return KugouArtistBrief(
      id: parsedId,
      name: extractFirstName(rawName),
      avatarUrl: _resolveArtworkUri(
        json['sizable_avatar'] ??
            json['imgurl'] ??
            json['avatar_url'] ??
            json['img'] ??
            json['pic'] ??
            json['ImgUrl'] ??
            json['sizable_cover'] ??
            json['avatar'],
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
  final String? globalCollectionId;
  final String? numericId;

  const KugouAlbumBrief({
    required this.id,
    required this.name,
    this.coverUrl,
    this.artistName,
    this.globalCollectionId,
    this.numericId,
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
      name: _cleanName(
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
      artistName: _cleanName(
        json['singername'] ??
            json['artist_name'] ??
            json['SingerName'] ??
            json['author_name'],
      ),
      globalCollectionId: _strNull(json['global_collection_id'] ?? json['gid']),
      numericId: _strNull(
        json['albumid'] ?? json['album_id'] ?? json['AlbumID'],
      ),
    );
  }

  Album toAlbum() {
    return Album(
      id: numericId ?? id,
      name: name,
      artist: artistName ?? '',
      artworkUri: coverUrl,
      songCount: 0,
      globalCollectionId: globalCollectionId,
    );
  }
}

class KugouPlaylistBrief {
  final String id;
  final String name;
  final String? coverUrl;
  final int songCount;
  final String? globalCollectionId;
  final String? numericId;
  final String listId;
  final String? listCreateUserid;
  final String? listCreateListid;
  final String? listCreateGid;
  final int type; // 0=自己创建, 1=收藏/订阅他人
  final int source; // 0=普通歌单, 2=收藏的专辑等
  final String? description;

  const KugouPlaylistBrief({
    required this.id,
    required this.name,
    this.coverUrl,
    this.songCount = 0,
    this.globalCollectionId,
    this.numericId,
    this.listId = '',
    this.listCreateUserid,
    this.listCreateListid,
    this.listCreateGid,
    this.type = 0,
    this.source = 0,
    this.description,
  });

  factory KugouPlaylistBrief.fromJson(Map<String, dynamic> json) {
    // 「我收藏」里每个歌单的 listid 是用户订阅后的版本（用于取完整歌曲）。
    // list_create_listid 是原歌单 listid（不可用）。两者通常不同；
    // 但部分场景下 server 只返回 listid，所以 listCreateListid 兜底用 listid。
    final listid = _str(json['listid'] ?? '');
    return KugouPlaylistBrief(
      id: _str(
        json['specialid'] ?? json['id'] ?? json['global_collection_id'] ?? '',
      ),
      name: _cleanName(json['specialname'] ?? json['name'] ?? ''),
      coverUrl: _resolveArtworkUri(
        // sizable_cover 是 /kmr/v2/albums 等接口实际返回的封面字段，
        // 与 KugouSongDetail.fromJson 保持一致的字段集
        json['sizable_cover'] ??
            json['imgurl'] ??
            json['img'] ??
            json['pic'] ??
            json['cover_url'] ??
            json['cover'] ??
            json['trans_param']?['union_cover'],
      ),
      songCount: _parseInt(
        json['songcount'] ?? json['song_count'] ?? json['count'] ?? 0,
      ),
      globalCollectionId: _strNull(json['global_collection_id'] ?? json['gid']),
      numericId: _strNull(
        json['specialid'] ?? json['albumid'] ?? json['album_id'],
      ),
      listId: listid,
      listCreateUserid: _strNull(json['list_create_userid']),
      listCreateListid: _strNull(json['list_create_listid']) ?? listid,
      listCreateGid: _strNull(
        json['list_create_gid'] ?? json['list_create_gid'],
      ),
      type: _parseInt(json['type'] ?? 0),
      source: _parseInt(json['source'] ?? 0),
      description: _strNull(
        json['intro'] ?? json['description'] ?? json['desc'],
      ),
    );
  }

  Playlist toPlaylist() {
    return Playlist(
      id: globalCollectionId ?? id,
      name: name,
      artworkUri: coverUrl,
      songCount: songCount,
      songs: [],
      description: description,
      listCreateUserid: listCreateUserid,
      listCreateListid: listCreateListid,
      listCreateGid: listCreateGid,
      subscribedListId: listId, // 用户订阅版本的 listid，用于拉取歌曲
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
  final int? fileId;

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
    this.fileId,
  });

  /// 创建副本并覆盖指定字段（用于补全 albumName 等缺失字段）
  KugouSongDetail copyWith({String? albumName}) {
    return KugouSongDetail(
      hash: hash,
      albumId: albumId,
      albumName: albumName ?? this.albumName,
      artistId: artistId,
      artistName: artistName,
      songName: songName,
      duration: duration,
      sqHash: sqHash,
      hqHash: hqHash,
      hash320: hash320,
      hash128: hash128,
      lyrics: lyrics,
      albumAudioId: albumAudioId,
      artworkUri: artworkUri,
      fileName: fileName,
      privilege: privilege,
      albumAudioId2: albumAudioId2,
      songId: songId,
      fileId: fileId,
    );
  }

  factory KugouSongDetail.fromJson(Map<String, dynamic> json) {
    // 处理 singerinfo / authors 数组格式
    String? artistName;
    String? artistIdFromSingerInfo;
    final singerinfo = json['singerinfo'];
    if (singerinfo is List && singerinfo.isNotEmpty) {
      final names = <String>[];
      for (final s in singerinfo) {
        if (s is Map) {
          final n = s['name']?.toString();
          if (n != null && n.isNotEmpty) names.add(n);
          artistIdFromSingerInfo ??= s['id']?.toString();
        }
      }
      if (names.isNotEmpty) artistName = names.join('、');
    }
    // kmr/v2 API 返回 authors 数组，兼容处理
    if (artistName == null || artistName.isEmpty) {
      final authors = json['authors'];
      if (authors is List && authors.isNotEmpty) {
        artistName = authors
            .map((a) => (a is Map ? a['author_name']?.toString() : '') ?? '')
            .where((s) => s.isNotEmpty)
            .join('、');
        if (artistIdFromSingerInfo == null && authors.first is Map) {
          artistIdFromSingerInfo = authors.first['author_id']?.toString();
        }
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
            json['audio_info']?['hash'] ??
            '',
      ),
      albumId: _strNull(
        json['album_id'] ??
            json['AlbumID'] ??
            json['albumid'] ??
            json['base']?['album_id'],
      ),
      albumName: _strNull(
        json['album_name'] ??
            json['AlbumName'] ??
            json['albumname'] ??
            json['albuminfo']?['name'] ??
            json['album_info']?['album_name'],
      ),
      artistId: _strNull(
        artistIdFromSingerInfo ??
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
            json['base']?['audio_name'] ??
            '',
      ),
      // 不同时长字段单位不统一：部分接口（如搜索）返回毫秒，部分返回秒。
      // 统一归一化：原始值 > 10000 视为毫秒，除以 1000。
      duration: _normalizeDuration(
        _parseInt(
          json['time_length'] ??
              json['HQDuration'] ??
              json['Duration'] ??
              json['duration'] ??
              json['audio_info']?['duration'] ??
              json['SuperDuration'] ??
              json['timelength'] ??
              (() {
                final tl = json['timelen'];
                if (tl != null) return (tl as int) ~/ 1000;
                final ai = json['audio_info'] as Map<String, dynamic>?;
                if (ai != null) {
                  final d =
                      ai['duration_flac'] as int? ??
                      ai['duration_320'] as int? ??
                      ai['duration_high'] as int? ??
                      ai['duration_128'] as int?;
                  if (d != null) return d ~/ 1000;
                }
                return null;
              })(),
        ),
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
            json['trans_param']?['union_cover'] ??
            json['album_info']?['sizable_cover'] ??
            json['album_info']?['cover'],
      ),
      fileName: _strNull(
        json['filename'] ?? json['FileName'] ?? json['ori_audio_name'],
      ),
      privilege: _parseInt(json['privilege'] ?? 0),
      albumAudioId2: _strNull(json['album_audio_id']),
      songId: _strNull(
        json['songid'] ?? json['song_id'] ?? json['SongId'] ?? json['SongID'],
      ),
      fileId: _parseInt(json['fileid'] ?? json['file_id']),
    );
  }

  Song toSong() {
    // 清理 title：API 的 filename/songname 常返回 "歌手 - 歌曲名" 格式，
    // 去掉前缀，只保留纯歌曲名（subtitle 已单独显示歌手和专辑）。
    // 只用 " - "（空格-破折号-空格）作为分隔符，避免误剥含有连字符的歌名
    // （如 "白菊 -shiragiku-"）。与 EchoMusic processSongTitle 实现一致。
    var cleanTitle = songName;
    // 歌手名兜底：当 API 未返回歌手字段时，从 "歌手 - 歌曲名" 格式的
    // 文件名中提取歌手。与 EchoMusic song.ts 实现一致。
    var resolvedArtist = artistName;
    if ((resolvedArtist == null || resolvedArtist.isEmpty) &&
        songName.contains(' - ')) {
      resolvedArtist = songName.split(' - ')[0];
    }
    if (cleanTitle.contains(' - ')) {
      final parts = cleanTitle.split(' - ');
      if (parts.length > 1) {
        final rest = parts.sublist(1).join(' - ');
        if (rest.trim().isNotEmpty) {
          cleanTitle = rest;
        }
      }
    }
    return Song(
      id: hash,
      title: cleanTitle,
      artist: (resolvedArtist != null && resolvedArtist.isNotEmpty)
          ? resolvedArtist
          : '未知歌手',
      album: albumName ?? '',
      duration: Duration(seconds: duration),
      isOnline: true,
      albumId: albumId,
      artistId: artistId,
      artworkUri: artworkUri,
      albumAudioId: albumAudioId,
      fileId: fileId,
    );
  }
}

class KugouPlayUrl {
  final String url;
  final int fileSize;
  final int bitRate;
  final String quality;
  final bool isTrial;

  const KugouPlayUrl({
    required this.url,
    this.fileSize = 0,
    this.bitRate = 0,
    required this.quality,
    this.isTrial = false,
  });

  factory KugouPlayUrl.fromJson(Map<String, dynamic> json) {
    dynamic rawUrl = json['url'] ?? json['play_url'] ?? '';
    String url;
    if (rawUrl is List && rawUrl.isNotEmpty) {
      url = rawUrl.first.toString();
    } else {
      url = rawUrl.toString();
    }
    // 检测是否为试听片段：fail_process 含 'buy' 说明该音质需要购买/VIP；
    // fileSize 小于 200KB 且歌曲正常时长 3-5 分钟，大概率是 30s 试听。
    final failProcess = json['fail_process'];
    final fileSize = _parseInt(
      json['fileSize'] ??
          json['file_size'] ??
          json['FileSize'] ??
          json['filesize'] ??
          0,
    );
    final isTrial = (failProcess is List && failProcess.contains('buy')) ||
        (fileSize > 0 && fileSize < 200 * 1024);
    return KugouPlayUrl(
      url: url,
      fileSize: fileSize,
      bitRate: _parseInt(
        json['bitRate'] ??
            json['bit_rate'] ??
            json['BitRate'] ??
            json['bitrate'] ??
            0,
      ),
      quality: _str(json['quality'] ?? '128'),
      isTrial: isTrial,
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
        // sizable_cover 是 /kmr/v2/albums 等接口实际返回的封面字段，
        // 与 KugouSongDetail.fromJson 保持一致的字段集
        json['sizable_cover'] ??
            json['imgurl'] ??
            json['img'] ??
            json['pic'] ??
            json['cover_url'] ??
            json['cover'] ??
            json['trans_param']?['union_cover'],
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
  final List<KugouComment> hotComments;
  final int total;

  const KugouCommentList({
    this.comments = const [],
    this.hotComments = const [],
    this.total = 0,
  });

  factory KugouCommentList.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final list = data['list'] ?? data['comments'] ?? [];

    // 歌手评论：weight_list / hot_list
    final hotCandidate = data['weight_list'] ?? data['hot_list'];
    final hotList = (hotCandidate is Map && hotCandidate['list'] is List)
        ? hotCandidate['list'] as List<dynamic>
        : (hotCandidate is List ? hotCandidate : <dynamic>[]);
    // 歌手评论：star_cmts / star_comment
    final starCandidate = data['star_cmts'] ?? data['star_comment'];
    final starList = (starCandidate is Map && starCandidate['list'] is List)
        ? starCandidate['list'] as List<dynamic>
        : (starCandidate is List ? starCandidate : <dynamic>[]);

    // 合并：歌手评论 + 歌手评论（去重，避免 star_cmts 同时出现在两个列表中）
    final hot = <KugouComment>[];
    final seenIds = <String>{};
    for (final e in starList) {
      if (e is Map<String, dynamic>) {
        final c = KugouComment.fromJson(e, isStar: true);
        if (seenIds.add(c.id)) hot.add(c);
      }
    }
    for (final e in hotList) {
      if (e is Map<String, dynamic>) {
        final c = KugouComment.fromJson(e, isHot: true);
        if (seenIds.add(c.id)) hot.add(c);
      }
    }

    return KugouCommentList(
      comments: (list as List<dynamic>)
          .map((e) => KugouComment.fromJson(e as Map<String, dynamic>))
          .toList(),
      hotComments: hot,
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
  final int replyCount;
  final bool isHot;
  final bool isStar;

  /// 楼层评论所需字段
  final String? specialId;
  final String? tid;
  final String? code;
  final String? mixSongId;

  const KugouComment({
    required this.id,
    required this.username,
    this.avatar,
    required this.content,
    this.time = 0,
    this.likes = 0,
    this.replyCount = 0,
    this.isHot = false,
    this.isStar = false,
    this.specialId,
    this.tid,
    this.code,
    this.mixSongId,
  });

  factory KugouComment.fromJson(
    Map<String, dynamic> json, {
    bool isHot = false,
    bool isStar = false,
  }) {
    // 修复头像 URL：http → https，避免 Android 明文 HTTP 请求被拒
    String? fixAvatar(String? url) {
      if (url == null || url.isEmpty) return null;
      if (url.startsWith('http://')) {
        return url.replaceFirst('http://', 'https://');
      }
      return url;
    }

    // 支持嵌套的 user 对象（部分接口返回 { user: { avatar, name, ... } }）
    final user = json['user'] as Map<String, dynamic>?;
    final likeRecord = json['like'] is Map<String, dynamic>
        ? json['like'] as Map<String, dynamic>
        : null;

    // 热门/歌手标记：优先从 json 读取，否则使用参数传入的值
    bool parseBool(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v == 1;
      return false;
    }

    return KugouComment(
      id: _str(json['commentid'] ?? json['id'] ?? ''),
      username: _str(
        json['user_name'] ??
            json['username'] ??
            json['nickname'] ??
            user?['name'] ??
            user?['nickname'] ??
            '匿名用户',
      ),
      avatar: fixAvatar(
        _strNull(
          json['user_pic'] ??
              json['user_img'] ??
              json['avatar'] ??
              user?['avatar'] ??
              user?['pic'] ??
              user?['img'],
        ),
      ),
      content: _str(json['content'] ?? json['comment_text'] ?? ''),
      time: _parseInt(
        json['createtime'] ?? json['addtime'] ?? json['time'] ?? 0,
      ),
      likes: _parseInt(
        likeRecord?['count'] ??
            json['like_count'] ??
            json['likes'] ??
            json['like_num'] ??
            json['reply_like_count'] ??
            0,
      ),
      replyCount: _parseInt(json['reply_num'] ?? json['reply_count'] ?? 0),
      isHot: parseBool(json['is_hot'] ?? json['isHot'] ?? isHot),
      isStar: parseBool(json['is_star'] ?? json['isStar'] ?? isStar),
      specialId: _strNull(
        json['special_child_id'] ??
            json['special_id'] ??
            json['specialId'] ??
            json['childrenid'],
      ),
      tid: _strNull(json['tid'] ?? json['id'] ?? json['comment_id']),
      code: _strNull(json['code']),
      mixSongId: _strNull(
        json['mixsongid'] ?? json['audio_id'] ?? json['album_audio_id'],
      ),
    );
  }
}

class KugouLyric {
  final String content;
  final String? decodedContent;
  final String? decodedKrcContent;
  final String? translatedContent;

  /// 罗马音/音译 LRC 明文（酷狗 KRC [language:] 中 language=1 条目）。
  /// 与 [translatedContent] 分离，独立通路传递到渲染层。
  final String? romaContent;

  const KugouLyric({
    required this.content,
    this.decodedContent,
    this.decodedKrcContent,
    this.translatedContent,
    this.romaContent,
  });

  factory KugouLyric.fromJson(Map<String, dynamic> json) {
    return KugouLyric(
      content: _str(
        json['content'] ?? json['lrcContent'] ?? json['lyrics'] ?? '',
      ),
      decodedContent: _strNull(
        json['decodeContent'] ?? json['decoded_content'] ?? json['lrcContent'],
      ),
      // KRC 明文（Node 侧解码后），多字段名降级以兼容不同上游
      decodedKrcContent: _strNull(
        json['decodeKrcContent'] ??
            json['decoded_krc_content'] ??
            json['krcContent'],
      ),
      translatedContent: _strNull(
        json['translated_content'] ?? json['trans'] ?? json['lrcContentChi'],
      ),
    );
  }

  /// 优先返回 KRC 明文（逐字），降级 LRC 明文，最后降级原始 content
  String get displayLyric => decodedKrcContent ?? decodedContent ?? content;

  /// 仅返回 KRC 明文（可空）
  String? get displayKrcLyric => decodedKrcContent;

  /// 仅返回 LRC 明文（可空）
  String? get displayLrcLyric => decodedContent;

  /// 仅返回罗马音 LRC 明文（可空）
  String? get displayRomaLyric => romaContent;
}

class KugouArtistDetail {
  final String id;
  final String name;
  final String? avatarUrl;
  final String? description;
  final int songCount;
  final int albumCount;
  final bool isFollowed;

  /// 接口是否返回了关注状态字段（用于区分"未关注"和"接口没返回"）
  final bool hasFollowStatus;

  const KugouArtistDetail({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.description,
    this.songCount = 0,
    this.albumCount = 0,
    this.isFollowed = false,
    this.hasFollowStatus = false,
  });

  factory KugouArtistDetail.fromJson(Map<String, dynamic> json) {
    final hasFollow =
        json['is_follow'] != null ||
        json['isfollow'] != null ||
        json['followed'] != null;
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
        json['sizable_avatar'] ??
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
      isFollowed:
          json['is_follow'] == 1 ||
          json['isfollow'] == 1 ||
          json['followed'] == 1,
      hasFollowStatus: hasFollow,
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
  final String? globalCollectionId;
  final String? artistId;

  const KugouAlbumDetail({
    required this.id,
    required this.name,
    this.coverUrl,
    this.artistName,
    this.description,
    this.songCount = 0,
    this.publishDate,
    this.globalCollectionId,
    this.artistId,
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
        // sizable_cover 是 /kmr/v2/albums 等接口实际返回的封面字段，
        // 与 KugouSongDetail.fromJson 保持一致的字段集
        json['sizable_cover'] ??
            json['imgurl'] ??
            json['img'] ??
            json['pic'] ??
            json['cover_url'] ??
            json['cover'] ??
            json['trans_param']?['union_cover'],
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
      globalCollectionId: _strNull(json['global_collection_id'] ?? json['gid']),
      artistId: _strNull(
        (() {
          final authors = json['authors'];
          if (authors is List && authors.isNotEmpty) {
            final first = authors.first;
            if (first is Map<String, dynamic>) {
              return first['author_id'] ?? first['singerid'] ?? first['id'];
            }
          }
          return null;
        })(),
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
      globalCollectionId: globalCollectionId,
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
    final rawInfo = data['info'];
    final rawSongs = data['songs'];
    final rawList = data['list'];
    final List<dynamic> list;
    if (rawInfo is List && rawInfo.isNotEmpty) {
      list = rawInfo;
    } else if (rawSongs is List && rawSongs.isNotEmpty) {
      list = rawSongs;
    } else if (rawList is List && rawList.isNotEmpty) {
      list = rawList;
    } else {
      list = (data['tracks'] as List<dynamic>?) ?? [];
    }
    return KugouPlaylistSongs(
      songs: list
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: _parseInt(
        data['total'] ?? data['total_count'] ?? data['count'] ?? 0,
      ),
    );
  }
}

String _str(dynamic v) => v?.toString() ?? '';

String _cleanName(dynamic v) {
  final raw = v?.toString() ?? '';
  return raw
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#\d+;', '');
}

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
  static const String high = 'hq';
  static const String lossless = 'flac';
  static const String hires = 'high';
  static const String master = 'hi-res';

  /// 音质代号 → 中文标签
  static const labels = {
    standard: '标准音质',
    high: '高音质',
    lossless: '无损音质',
    hires: 'Hi-Res',
  };

  static String labelOf(String quality) => labels[quality] ?? quality;
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

  /// 概念版VIP到期时间（优先显示）
  final String? conceptExpireTime;

  /// 原始 busi_vip 列表，用于 UI 细分展示
  final List<Map<String, dynamic>> busiVipList;

  const KugouUserVipDetail({
    this.nickname,
    this.vipLevel,
    this.isVip = false,
    this.expireTime,
    this.conceptExpireTime,
    this.busiVipList = const [],
  });

  factory KugouUserVipDetail.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;

    // 实际结构: data.is_vip (总开关), data.busi_vip[] (各业务线, 含 product_type, vip_end_time)
    final busiList = data['busi_vip'];
    bool isVip = data['is_vip'] == 1;
    String? expireTime;
    String? conceptExpireTime;
    final List<Map<String, dynamic>> rawBusiList = [];

    if (busiList is List) {
      DateTime? latest;
      for (final b in busiList) {
        if (b is Map<String, dynamic>) {
          rawBusiList.add(b);
          if (b['is_vip'] == 1) {
            isVip = true;
            final t = b['vip_end_time']?.toString();
            if (t != null && t.isNotEmpty) {
              final dt = DateTime.tryParse(t.replaceFirst(' ', 'T'));
              if (dt != null) {
                // 取所有 VIP 中最晚到期时间作为通用 expireTime
                if (latest == null || dt.isAfter(latest)) {
                  latest = dt;
                }
                // 概念版VIP: product_type 为 "svip"
                final pt = b['product_type']?.toString() ?? '';
                final isConcept = pt == 'svip';
                print(
                  '[VIP_DEBUG] product_type=$pt isConcept=$isConcept end_time=$t',
                );
                if (isConcept) {
                  conceptExpireTime =
                      '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                }
              }
            }
          }
        }
      }
      if (latest != null && expireTime == null) {
        expireTime =
            '${latest.year.toString().padLeft(4, '0')}-${latest.month.toString().padLeft(2, '0')}-${latest.day.toString().padLeft(2, '0')}';
      }
    }

    return KugouUserVipDetail(
      nickname: _strNull(data['nickname']),
      vipLevel: _parseInt(data['vip_level'] ?? data['vip_type']),
      isVip: isVip,
      expireTime: expireTime,
      conceptExpireTime: conceptExpireTime,
      busiVipList: rawBusiList,
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
    // API 返回的 data 可能是 List（如 [{start_time, end_time, ...}]）或 Map
    dynamic rawData = json['data'];
    if (rawData is List && rawData.isNotEmpty) {
      rawData = rawData.first;
    }
    final data = rawData is Map<String, dynamic> ? rawData : json;
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
