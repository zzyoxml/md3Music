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
            json['sd_hash'] ??
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
                  // 频道音乐故事接口：audio_info 内时长字段为 timelength（毫秒，
                  // 可能为字符串类型）
                  final atl =
                      ai['timelength'] ??
                      ai['timelength_128'] ??
                      ai['timelength_320'] ??
                      ai['timelength_flac'];
                  final atlInt = _parseInt(atl);
                  if (atlInt > 0) return atlInt ~/ 1000;
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
      lyrics: _strNull(json['lyrics'] ?? json['Lyrics'] ?? json['Lyric']),
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

  /// 评论区 id（响应顶层 `childrenid`）。
  ///
  /// 「最热」接口（/comment/music/topliked）必传它，上游不接受用 mixsongid 代替，
  /// 因此只能先请求 /comment/music 拿到这个值。
  final String childrenId;

  const KugouCommentList({
    this.comments = const [],
    this.hotComments = const [],
    this.total = 0,
    this.childrenId = '',
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
        data['total'] ??
            data['count'] ??
            data['comment_count'] ??
            data['comments_num'] ??
            0,
      ),
      childrenId: _str(data['childrenid'] ?? ''),
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

  /// 楼中楼回复的父级回复 ID（原始 JSON 的 `pid`）。
  ///
  /// null 或 '0' 表示直接回复楼主；非 0 时指向同一楼内另一条回复的 ID，
  /// 楼中楼的嵌套层级由此还原（见 buildReplyTree）。
  final String? parentId;

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
    this.parentId,
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
      time: _parseCommentTime(
        json['createtime'] ?? json['addtime'] ?? json['time'],
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
      parentId: _strNull(json['pid']),
      specialId: _strNull(
        json['special_child_id'] ??
            json['special_id'] ??
            json['specialId'] ??
            json['childrenid'],
      ),
      tid: _strNull(
        _zeroAsNull(json['tid']) ?? json['id'] ?? json['comment_id'],
      ),
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

/// 与 [_parseInt] 相同，但解析失败/缺失时返回 null（用于可选数字字段）。
int? _parseIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString());
}

dynamic _zeroAsNull(dynamic v) {
  if (v == null) return null;
  final text = v.toString().trim();
  return text.isEmpty || text == '0' ? null : v;
}

/// 解析评论时间为秒级 Unix 时间戳。
///
/// 酷狗评论接口的 `addtime` 是 "2024-09-11 08:38:13" 这样的日期时间字符串而非
/// 时间戳，[_parseInt] 对它只能得到 0，时间戳因此完全渲染不出来。这里先按数字
/// （秒级时间戳）解析，失败再按日期时间字符串解析。
///
/// 字符串不带时区，实测是北京时间（UTC+8），按 UTC+8 而非设备本地时区解析，
/// 否则其他时区算出的「x 小时前」会整体偏移、甚至变成未来时间。
int _parseCommentTime(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  final text = v.toString().trim();
  if (text.isEmpty) return 0;
  final asTimestamp = int.tryParse(text);
  if (asTimestamp != null) return asTimestamp;
  var iso = text.replaceFirst(' ', 'T');
  if (!iso.endsWith('Z') && !_isoOffsetPattern.hasMatch(iso)) {
    iso = '$iso+08:00';
  }
  final parsed = DateTime.tryParse(iso);
  return parsed == null ? 0 : parsed.millisecondsSinceEpoch ~/ 1000;
}

final RegExp _isoOffsetPattern = RegExp(r'[+-]\d{2}:?\d{2}$');

/// 依次取第一个非空候选作为封面图（上游常返回空串 pic + 有效 bg_pic）。
String? _resolveFirstArtwork(List<dynamic> candidates) {
  for (final c in candidates) {
    if (c != null && c.toString().isNotEmpty) {
      return _resolveArtworkUri(c);
    }
  }
  return null;
}

String? _resolveArtworkUri(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  if (s.isEmpty) return null;
  return s.replaceAll('{size}', '400');
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

/// 听歌等级信息（/user/grade/info，v2/lite 协议）。
class KugouGradeInfo {
  /// 服务器当前累计听歌时长（秒）
  final int? dSec;

  /// 时长（秒，与 d_sec 近似，取其一展示）
  final int? duration;

  /// 当前等级（如 3）
  final int? pGrade;

  /// 当前成长值/积分
  final int? pCurrentPoint;

  /// 本级所需成长值（升到本级时）
  final int? pGradePoint;

  /// 下一等级
  final int? pNextGrade;

  /// 升到下一级所需成长值
  final int? pNextGradePoint;

  /// 服务器时间（字符串）
  final String? serverTime;

  const KugouGradeInfo({
    this.dSec,
    this.duration,
    this.pGrade,
    this.pCurrentPoint,
    this.pGradePoint,
    this.pNextGrade,
    this.pNextGradePoint,
    this.serverTime,
  });

  factory KugouGradeInfo.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouGradeInfo(
      dSec: _parseInt(data['d_sec'] ?? data['dSec']),
      duration: _parseInt(data['duration']),
      pGrade: _parseInt(data['p_grade'] ?? data['pGrade']),
      pCurrentPoint: _parseInt(
        data['p_current_point'] ?? data['pCurrentPoint'],
      ),
      pGradePoint: _parseInt(data['p_grade_point'] ?? data['pGradePoint']),
      pNextGrade: _parseInt(data['p_next_grade'] ?? data['pNextGrade']),
      pNextGradePoint: _parseInt(
        data['p_next_grade_point'] ?? data['pNextGradePoint'],
      ),
      serverTime: _strNull(data['servertime'] ?? data['serverTime']),
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
      name: _str(json['title'] ?? json['name'] ?? json['scene_name'] ?? ''),
      coverUrl: _resolveFirstArtwork([
        json['pic'],
        json['bg_pic'],
        json['img'],
        json['imgurl'],
        json['cover'],
      ]),
    );
  }
}

/// 场景模块下的 Tag（/scene/module 模块的 extra[] 项）。
///
/// [contentType] 决定进入的列表接口：
/// 6=音乐（/scene/audio/list）、1=歌单（/scene/collection/list）、
/// 2=视频（/scene/video/list）、5=听书（暂不支持）。
class KugouSceneTag {
  final String tagId;
  final String name;
  final int? contentType;
  final String? picUrl;

  const KugouSceneTag({
    required this.tagId,
    required this.name,
    this.contentType,
    this.picUrl,
  });

  factory KugouSceneTag.fromJson(Map<String, dynamic> json) {
    return KugouSceneTag(
      tagId: _str(json['tag_id'] ?? json['id'] ?? ''),
      name: _str(json['tag_name'] ?? json['name'] ?? json['title'] ?? ''),
      contentType: _parseIntOrNull(json['content_type'] ?? json['types']),
      picUrl: _resolveArtworkUri(
        json['pic'] ?? json['imgurl'] ?? json['img'] ?? json['cover'],
      ),
    );
  }
}

/// 场景详情中的模块（/scene/module 的 data.content 下数组项）。
///
/// [type]：2=音乐模块、3=视频模块、4=讨论模块（extra 为 discuss_param，无 tag）。
/// [tags] 直接取自模块的 extra[]，无需再请求 /scene/module/info。
class KugouSceneModule {
  final String moduleId;
  final String name;
  final int type;
  final List<KugouSceneTag> tags;

  const KugouSceneModule({
    required this.moduleId,
    required this.name,
    this.type = 0,
    this.tags = const [],
  });

  factory KugouSceneModule.fromJson(Map<String, dynamic> json) {
    final tags = <KugouSceneTag>[];
    final extra = json['extra'];
    if (extra is List) {
      for (final e in extra) {
        if (e is Map<String, dynamic>) {
          final t = KugouSceneTag.fromJson(e);
          if (t.tagId.isNotEmpty) tags.add(t);
        }
      }
    }
    return KugouSceneModule(
      moduleId: _str(json['module_id'] ?? json['id'] ?? ''),
      name: _str(
        json['module_title'] ?? json['title'] ?? json['module_name'] ?? '',
      ),
      type: _parseInt(json['module_type'] ?? 0),
      tags: tags,
    );
  }
}

/// 场景讨论区动态（/scene/lists/v2 的 data.list 项）。
class KugouSceneDiscuss {
  final String id;
  final String content;
  final String nickname;
  final String? avatar;
  final int likeTotal;
  final int commentTotal;
  final String? topicTitle;
  final KugouSongDetail? song;
  final KugouPlaylistBrief? collection;

  const KugouSceneDiscuss({
    required this.id,
    required this.content,
    required this.nickname,
    this.avatar,
    this.likeTotal = 0,
    this.commentTotal = 0,
    this.topicTitle,
    this.song,
    this.collection,
  });

  factory KugouSceneDiscuss.fromJson(Map<String, dynamic> json) {
    final user = json['g_user'];
    final userMap = user is Map<String, dynamic> ? user : null;
    final songJson = json['song'];
    final topicJson = json['topic'];
    final collectionJson = json['collection'];
    return KugouSceneDiscuss(
      id: _str(json['id'] ?? ''),
      content: _str(json['content'] ?? ''),
      nickname: _str(userMap?['nickname'] ?? ''),
      avatar: _resolveArtworkUri(userMap?['avatar']),
      likeTotal: _parseInt(json['like_total'] ?? 0),
      commentTotal: _parseInt(json['comment_total'] ?? 0),
      topicTitle: _strNull(
        topicJson is Map<String, dynamic> ? topicJson['title'] : null,
      ),
      song: songJson is Map<String, dynamic>
          ? KugouSongDetail.fromJson(songJson)
          : null,
      collection: collectionJson is Map<String, dynamic>
          ? KugouPlaylistBrief.fromJson(collectionJson)
          : null,
    );
  }
}

/// 场景音乐视频项（/scene/video/list 响应项）。
class KugouSceneVideo {
  final String id;
  final String title;
  final String? coverUrl;
  final String? hash;
  final String? authorName;

  const KugouSceneVideo({
    required this.id,
    required this.title,
    this.coverUrl,
    this.hash,
    this.authorName,
  });

  factory KugouSceneVideo.fromJson(Map<String, dynamic> json) {
    // 视频 hash：sd_hash（标清）/ qhd_hash（高清），用于 /video/url 取播放地址
    final authorInfo = json['author_info'];
    return KugouSceneVideo(
      id: _str(json['video_id'] ?? json['id'] ?? json['content_id'] ?? ''),
      title: _str(json['title'] ?? json['name'] ?? json['video_name'] ?? ''),
      coverUrl: _resolveFirstArtwork([
        json['cover'],
        json['img'],
        json['imgurl'],
        json['pic'],
      ]),
      hash: _strNull(
        json['sd_hash'] ?? json['qhd_hash'] ?? json['hash'] ?? json['video_hash'],
      ),
      authorName: _strNull(
        (authorInfo is Map<String, dynamic> ? authorInfo['user_name'] : null) ??
            json['author_name'] ??
            json['singer_name'],
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
      id: _str(
        json['global_collection_id'] ??
            json['id'] ??
            json['channel_id'] ??
            json['channelid'] ??
            '',
      ),
      name: _str(
        json['name'] ?? json['channel_name'] ?? json['channelname'] ?? '',
      ),
      coverUrl: _resolveArtworkUri(
        json['channel_avatar'] ??
            json['channel_cover'] ??
            json['img'] ??
            json['imgurl'] ??
            json['cover'] ??
            json['pic'],
      ),
      desc: _strNull(json['intro'] ?? json['desc'] ?? json['description']),
    );
  }
}

class KugouLongAudioAlbum {
  final String id;
  final String name;
  final String? coverUrl;
  final String? author;
  final int audioCount;
  /// 专辑简介（详情页展示，可空）。
  final String? intro;

  const KugouLongAudioAlbum({
    required this.id,
    required this.name,
    this.coverUrl,
    this.author,
    this.audioCount = 0,
    this.intro,
  });

  factory KugouLongAudioAlbum.fromJson(Map<String, dynamic> json) {
    return KugouLongAudioAlbum(
      id: _str(json['id'] ?? json['album_id'] ?? json['albumid'] ?? ''),
      name: _str(
        json['name'] ??
            json['album_name'] ??
            json['albumname'] ??
            json['title'] ??
            '',
      ),
      coverUrl: _resolveArtworkUri(
        json['sizable_cover'] ??
            json['img'] ??
            json['imgurl'] ??
            json['cover'],
      ),
      author: _strNull(
        json['author'] ?? json['author_name'] ?? json['singer'],
      ),
      audioCount: _parseInt(
        json['audio_count'] ??
            json['audiocount'] ??
            json['audio_total'] ??
            json['songcount'] ??
            0,
      ),
      intro: _strNull(json['intro'] ?? json['mix_intro'] ?? json['full_intro']),
    );
  }
}

/// 听书专辑下的音频（章节）。
class KugouLongAudioAudio {
  /// 播放用 id：hash 优先，兜底 album_audio_id / audio_id / mixsongid。
  final String id;
  final String name;
  final String? author;
  final Duration duration;
  final String? artworkUri;
  final String? albumAudioId;
  final String? albumId;
  /// 是否限免可播：fail_process_128（默认 128k 播放音质）为 0；字段缺失时兜底 fail_process。
  /// 非 0（酷狗惯例 4）= 需购买/仅试听（付费章节）。
  final bool canPlay;

  const KugouLongAudioAudio({
    required this.id,
    required this.name,
    this.author,
    this.duration = Duration.zero,
    this.artworkUri,
    this.albumAudioId,
    this.albumId,
    this.canPlay = true,
  });

  factory KugouLongAudioAudio.fromJson(Map<String, dynamic> json) {
    // 封面字段在 trans_param.union_cover（听书章节无顶层 img 字段）
    final transParam = json['trans_param'];
    final unionCover = transParam is Map<String, dynamic>
        ? transParam['union_cover']
        : null;
    return KugouLongAudioAudio(
      id: _str(
        json['hash'] ??
            json['play_hash'] ??
            json['album_audio_id'] ??
            json['audio_id'] ??
            json['mixsongid'] ??
            '',
      ),
      name: _str(
        json['audio_name'] ??
            json['filename'] ??
            json['song_name'] ??
            json['title'] ??
            '',
      ),
      author: _strNull(json['author_name'] ?? json['singer_name']),
      duration: Duration(
        seconds: _normalizeDuration(
          _parseInt(
            json['timelength'] ??
                json['timelength_128'] ??
                json['timelength_320'] ??
                json['timelength_high'] ??
                json['duration'] ??
                0,
          ),
        ),
      ),
      artworkUri: _resolveArtworkUri(
        unionCover ?? json['img'] ?? json['imgurl'] ?? json['cover'],
      ),
      albumAudioId: _strNull(json['album_audio_id']),
      albumId: _strNull(json['album_id']),
      canPlay: _isLongAudioCanPlay(json),
    );
  }
}

/// 限免/可播判定：`fail_process_128`（默认 128k 播放音质）为 0 即可播；
/// 字段缺失时兜底顶层 `fail_process`；两者都无则默认可播（避免误杀）。
/// 注意：不能用 privilege（限免章节 privilege_128 也是 4）。
bool _isLongAudioCanPlay(Map<String, dynamic> json) {
  final v128 = _parseIntOrNull(json['fail_process_128']);
  if (v128 != null) return v128 == 0;
  final v = _parseIntOrNull(json['fail_process']);
  if (v != null) return v == 0;
  return true;
}

/// 手机验证码登录的多账号候选（酷狗 `/v7/login_by_verifycode` 返回的
/// `data.user_list` 条目）。一个手机号绑定多个账号时，需展示此列表让用户
/// 选择，再携带选中账号的 [userid] 二次请求完成登录。
class KugouLoginAccount {
  final String userid;
  final String? nickname;
  final String? avatar;

  const KugouLoginAccount({
    required this.userid,
    this.nickname,
    this.avatar,
  });

  factory KugouLoginAccount.fromJson(Map<String, dynamic> json) {
    return KugouLoginAccount(
      userid: _str(
        json['userid'] ?? json['userId'] ?? json['id'] ?? json['user_id'],
      ),
      nickname: _strNull(
        json['nickname'] ?? json['user_name'] ?? json['name'],
      ),
      avatar: _resolveArtworkUri(
        json['avatar'] ?? json['pic'] ?? json['img'] ?? json['imgurl'],
      ),
    );
  }
}
