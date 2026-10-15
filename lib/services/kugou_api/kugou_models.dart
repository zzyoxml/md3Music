import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/album.dart';
import '../../data/models/artist.dart';
import '../../data/models/playlist.dart';
import '../../data/models/song.dart';

/// 音量均衡响度缓存：url → (LUFS, 峰值dB)。由 [KugouPlayUrl.fromJson] 在每次解析到
/// 响度时记录，播放链路按播放 url 回退取用（避免依赖 song 对象承载响度字段）。
/// 同时持久化到 SharedPreferences，历史回放的已缓存 url 跨会话也能取到响度。
typedef KugouLoudness = ({double lufs, double? peak});
final Map<String, KugouLoudness> kugouUrlLoudness = {};

const String _kugouLoudnessPrefsKey = 'kugou_url_loudness';
const int _kugouLoudnessMax = 300;
bool _kugouLoudnessLoaded = false;

/// 预热：启动时把历史持久化的 url→响度 载入内存缓存。
Future<void> warmLoudnessCache() async {
  if (_kugouLoudnessLoaded) return;
  _kugouLoudnessLoaded = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kugouLoudnessPrefsKey);
    if (raw == null || raw.isEmpty) return;
    final list = jsonDecode(raw) as List<dynamic>;
    for (final item in list) {
      if (item is! Map) continue;
      final url = item['u'] as String?;
      final lufs = item['l'];
      if (url == null || url.isEmpty || lufs is! num) continue;
      final pk = item['p'];
      kugouUrlLoudness[url] = (lufs: lufs.toDouble(), peak: pk is num ? pk.toDouble() : null);
    }
  } catch (_) {}
}

/// 持久化 url→响度 缓存（截断到最近 [max] 条）。
Future<void> _persistLoudnessCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final entries = kugouUrlLoudness.entries
        .take(_kugouLoudnessMax)
        .map((e) => {'u': e.key, 'l': e.value.lufs, 'p': e.value.peak})
        .toList();
    await prefs.setString(_kugouLoudnessPrefsKey, jsonEncode(entries));
  } catch (_) {}
}

/// 按播放 url 查询已解析的响度（无则 null）。内存未命中时尝试从持久化预热加载。
KugouLoudness? loudnessForUrl(String url) {
  if (url.isEmpty) return null;
  return kugouUrlLoudness[url];
}

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
  final int? year;

  const KugouAlbumBrief({
    required this.id,
    required this.name,
    this.coverUrl,
    this.artistName,
    this.globalCollectionId,
    this.numericId,
    this.year,
  });

  /// 兼容新碟上架测试与 UI 层对 `artist` 字段名的访问（与 artistName 等价）。
  String get artist => artistName ?? '';

  factory KugouAlbumBrief.fromJson(Map<String, dynamic> json) {
    // 只认绝对 URL：歌手专辑接口（/artist/albums）里 cover 与 pic 是**裸文件名**
    // （如 `20260909032931659085.jpg`），真实地址在 sizable_cover。旧写法按顺序取到
    // cover 就当封面用，图片必然加载失败 —— 真机表现为「列表无封面、点进详情页反而有」。
    final coverCandidates = <dynamic>[
      json['imgurl'],
      json['cover_url'],
      json['img'],
      json['pic'],
      json['ImgUrl'],
      json['cover'],
      json['sizable_cover'],
      json['album_cover'],
    ];
    dynamic rawCoverValue;
    for (final candidate in coverCandidates) {
      final text = candidate?.toString() ?? '';
      if (text.startsWith('http') || text.startsWith('//')) {
        rawCoverValue = candidate;
        break;
      }
    }
    final rawCover = _resolveArtworkUri(rawCoverValue);

    // 年份：优先 publish_time（秒级时间戳），否则从日期字符串取前 4 位。
    // publishtime 是 mobile_newalbum_sp 的真实字段（"YYYY-MM-DD HH:MM:SS"）。
    int? year;
    final publishTime = json['publish_time'];
    if (publishTime is num && publishTime > 0) {
      year = DateTime.fromMillisecondsSinceEpoch(publishTime.toInt() * 1000).year;
    } else {
      final publishDate = _cleanName(
        json['publish_date'] ??
            json['publishtime'] ??
            json['pub_time'] ??
            json['publishDate'],
      );
      if (publishDate.length >= 4) {
        final y = int.tryParse(publishDate.substring(0, 4));
        if (y != null) year = y;
      }
    }

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
            json['title'] ??
            '',
      ),
      coverUrl: rawCover,
      artistName: _cleanName(
        json['singername'] ??
            json['artist_name'] ??
            json['SingerName'] ??
            json['author_name'] ??
            json['singer'] ??
            json['artist'],
      ),
      globalCollectionId: _strNull(json['global_collection_id'] ?? json['gid']),
      numericId: _strNull(
        json['albumid'] ?? json['album_id'] ?? json['AlbumID'],
      ),
      year: year,
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
      year: year,
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
  /// 私人 FM 反馈令牌（上游 rec_song_info.cur_mark）：红心/垃圾桶/播放完成等
  /// action 回报时必须原样带回，缺了服务端就无法定位这条推荐。
  final String? curMark;

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
    this.curMark,
  });

  /// 创建副本并覆盖指定字段（用于补全 albumName 等缺失字段）
  KugouSongDetail copyWith({
    String? albumName,
    String? artworkUri,
    String? curMark,
  }) {
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
      artworkUri: artworkUri ?? this.artworkUri,
      fileName: fileName,
      privilege: privilege,
      albumAudioId2: albumAudioId2,
      songId: songId,
      fileId: fileId,
      curMark: curMark ?? this.curMark,
    );
  }

  /// 判断一个 map 是否像歌曲条目（云端听歌排行/历史等未文档化响应的条目识别）：
  /// 有 hash 家族字段或任一名称字段即认为可解析。
  static bool itemLooksLikeSong(Map<String, dynamic> json) {
    const hashKeys = [
      'hash', 'FileHash', 'Hash128', 'SQFileHash', 'HQFileHash', 'sd_hash',
      'hash_128', 'hash_320', 'hash_flac', 'sq_hash', 'hq_hash',
    ];
    const nameKeys = [
      'songname', 'SongName', 'name', 'ori_audio_name', 'FileName',
      'filename', 'audio_name',
    ];
    final hasHash = hashKeys.any(
      (k) => json[k] != null && json[k].toString().isNotEmpty,
    );
    if (hasHash) return true;
    return nameKeys.any(
      (k) => json[k] != null && json[k].toString().isNotEmpty,
    );
  }

  factory KugouSongDetail.fromJson(Map<String, dynamic> json) {
    // /audio 等接口把封面、专辑、hash 家族等字段藏在嵌套结构里
    // （audio_info.hash_128/hash_flac/img、album_info.sizable_cover/id、
    // song_info、base），顶层只有 hash 与名称。对齐 EchoMusic
    // mergeNestedSongRecord：嵌套对象浅展开为顶层字段的**兜底**（顶层优先，
    // 防止 album_info.name 覆盖歌曲名）。展开后 hash_128/hash_320/hash_flac、
    // sizable_cover 等顶层候选键即可直接命中——之前富化 cover=false、
    // artistId/albumId 全空、搜索兜底 hash 匹配不上，都是缺这层展开。
    final merged = <String, dynamic>{};
    for (final k in const [
      'album_info',
      'albuminfo',
      'audio',
      'audio_info',
      'song_info',
      'base',
      // 私人 FM 把反馈令牌 cur_mark（与 rec_desc 等）藏在 rec_song_info 里，
      // 浅展开后顶层候选键即可命中（顶层优先，非破坏性）。
      'rec_song_info',
    ]) {
      final nested = json[k];
      if (nested is Map) {
        nested.forEach((key, value) {
          merged.putIfAbsent(key.toString(), () => value);
        });
      }
    }
    merged.addAll(json);
    final json2 = merged;
    // 处理 singerinfo / authors / Singers 数组格式
    String? artistName;
    String? artistIdFromSingerInfo;
    final singerinfo = json2['singerinfo'];
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
    // /search 返回 Singers 数组（元素为 {name, id}），与 singerinfo 同构。
    // 该接口没有 singerinfo/authors，只有 Singers + 标量 SingerName。
    if (artistName == null || artistName.isEmpty) {
      final singers = json2['Singers'] ?? json2['singers'];
      if (singers is List && singers.isNotEmpty) {
        final names = <String>[];
        for (final s in singers) {
          if (s is Map) {
            final n = s['name']?.toString();
            if (n != null && n.isNotEmpty) names.add(n);
            artistIdFromSingerInfo ??= s['id']?.toString();
          }
        }
        if (names.isNotEmpty) artistName = names.join('、');
      }
    }
    // kmr/v2 API 返回 authors 数组，兼容处理
    if (artistName == null || artistName.isEmpty) {
      final authors = json2['authors'];
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

    // SingerId / AuthorID 在 /search 等接口中是数组（如 [4490]），
    // 在另一些接口中是标量字符串。两种形态都要能取出首个非空 id。
    String? firstIdOf(dynamic value) {
      if (value is List) {
        for (final e in value) {
          final s = e?.toString();
          if (s != null && s.isNotEmpty) return s;
        }
        return null;
      }
      return _strNull(value);
    }

    // /audio 等基础接口只返回 audio_name（「歌手 - 歌名」合并格式）：
    // 歌名候选键全部落空时拆出歌手与歌名，避免富化拿到空标题整串歌名
    var songName = _str(
      json2['songname'] ??
          json2['SongName'] ??
          json2['name'] ??
          json2['ori_audio_name'] ??
          json2['FileName'] ??
          json2['filename'] ??
          json2['base']?['audio_name'] ??
          '',
    );
    var resolvedArtistName =
        artistName ??
        _strNull(
          json2['author_name'] ??
              json2['SingerName'] ??
              json2['artist_name'] ??
              json2['singername'],
        );
    if (songName.isEmpty) {
      final mergedName = _str(json2['audio_name'] ?? '');
      if (mergedName.isNotEmpty) {
        final sep = mergedName.indexOf(' - ');
        if (sep > 0) {
          resolvedArtistName ??= mergedName.substring(0, sep);
          songName = mergedName.substring(sep + 3);
        } else {
          songName = mergedName;
        }
      }
    }

    // 私人 FM 反馈令牌：正常从 rec_song_info（已浅展开）/顶层取 cur_mark，
    // 兼容驼峰 curMark 与整型取值；空串按「无令牌」处理，避免把空值回报上游。
    final curMarkRaw = _strNull(json2['cur_mark'] ?? json2['curMark']);
    final curMark =
        (curMarkRaw == null || curMarkRaw.isEmpty) ? null : curMarkRaw;

    return KugouSongDetail(
      hash: _str(
        json2['hash'] ??
            json2['FileHash'] ??
            json2['Hash128'] ??
            json2['SQFileHash'] ??
            json2['HQFileHash'] ??
            json2['sd_hash'] ??
            json2['trans_param']?['ogg_128_hash'] ??
            json2['audio_info']?['hash'] ??
            '',
      ),
      albumId: _strNull(
        json2['album_id'] ??
            json2['AlbumID'] ??
            json2['albumid'] ??
            json2['album_info']?['id'] ??
            json2['base']?['album_id'],
      ),
      albumName: _strNull(
        json2['album_name'] ??
            json2['AlbumName'] ??
            json2['albumname'] ??
            json2['albuminfo']?['name'] ??
            json2['album_info']?['album_name'],
      ),
      artistId: _strNull(
        artistIdFromSingerInfo ??
            firstIdOf(json2['SingerId']) ??
            firstIdOf(json2['singerid']) ??
            firstIdOf(json2['SingerID']) ??
            firstIdOf(json2['AuthorID']) ??
            firstIdOf(json2['artist_id']),
      ),
      songName: songName,
      artistName: resolvedArtistName,
      // 不同时长字段单位不统一：部分接口（如搜索）返回毫秒，部分返回秒。
      // 统一归一化：原始值 > 10000 视为毫秒，除以 1000。
      duration: _normalizeDuration(
        _parseInt(
          json2['time_length'] ??
              json2['HQDuration'] ??
              json2['Duration'] ??
              json2['duration'] ??
              json2['audio_info']?['duration'] ??
              json2['SuperDuration'] ??
              json2['timelength'] ??
              (() {
                final tl = json2['timelen'];
                if (tl != null) return (tl as int) ~/ 1000;
                final ai = json2['audio_info'] as Map<String, dynamic>?;
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
        json2['hash_flac'] ??
            json2['SQHash'] ??
            json2['sq_hash'] ??
            json2['SQFileHash'],
      ),
      hqHash: _strNull(
        json2['hash_320'] ??
            json2['HQHash'] ??
            json2['hq_hash'] ??
            json2['HQFileHash'],
      ),
      hash320: _strNull(
        json2['hash_320'] ??
            json2['320Hash'] ??
            json2['Hash320'] ??
            json2['trans_param']?['ogg_320_hash'],
      ),
      hash128: _strNull(
        json2['hash_128'] ??
            json2['128Hash'] ??
            json2['Hash128'] ??
            json2['trans_param']?['ogg_128_hash'],
      ),
      lyrics: _strNull(json2['lyrics'] ?? json2['Lyrics'] ?? json2['Lyric']),
      albumAudioId: _strNull(
        json2['album_audio_id'] ??
            json2['AlbumAudioID'] ??
            json2['MixSongID'] ??
            json2['mixsongid'] ??
            json2['add_mixsongid'] ??
            json2['Audioid'] ??
            json2['audio_id'],
      ),
      artworkUri: _resolveArtworkUri(
        json2['sizable_cover'] ??
            json2['album_sizable_cover'] ??
            json2['Image'] ??
            json2['ImgUrl'] ??
            json2['img'] ??
            json2['pic'] ??
            json2['cover'] ??
            // listenservice /user/listen 条目的封面键（实机确认：image / image_320）
            json2['image'] ??
            json2['cover_pic'] ??
            json2['union_cover'] ??
            json2['trans_param']?['union_cover'] ??
            json2['audio_info']?['img'] ??
            json2['album_info']?['sizable_cover'] ??
            json2['album_info']?['cover'],
      ),
      fileName: _strNull(
        json2['filename'] ?? json2['FileName'] ?? json2['ori_audio_name'],
      ),
      privilege: _parseInt(json2['privilege'] ?? 0),
      albumAudioId2: _strNull(json2['album_audio_id']),
      songId: _strNull(
        json2['songid'] ?? json2['song_id'] ?? json2['SongId'] ?? json2['SongID'],
      ),
      fileId: _parseInt(json2['fileid'] ?? json2['file_id']),
      curMark: curMark,
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
  /// 音量均衡（响度归一）：集总响度（LUFS），无则 null。
  final double? volumeLufs;
  /// 真峰值（dBTP/dBFS），无则 null。
  final double? volumePeakDb;
  /// 上游响度增益（dB，仅诊断用），无则 null。
  final double? volumeGainDb;

  const KugouPlayUrl({
    required this.url,
    this.fileSize = 0,
    this.bitRate = 0,
    required this.quality,
    this.isTrial = false,
    this.volumeLufs,
    this.volumePeakDb,
    this.volumeGainDb,
  });

  factory KugouPlayUrl.fromJson(Map<String, dynamic> json) {
    // 响度字段：读取嵌套 data 层（_extractData 已把 data 并到顶层或保留 data 层）。
    final data = json['data'];
    final source = data is Map<String, dynamic>
        ? {...json, ...data}
        : json;
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
      volumeLufs: _optDouble(source['volume'] ?? source['volume_lufs']),
      volumePeakDb: _optDouble(source['volume_peak'] ?? source['volumePeak']),
      volumeGainDb: _optDouble(source['volume_gain'] ?? source['volumeGain']),
    ).. _rememberLoudness();
  }

  /// 记录本次解析的响度到全局缓存（并持久化，跨会话供历史回放），播放链路回退使用。
  KugouPlayUrl _rememberLoudness() {
    final lufs = volumeLufs;
    final peak = volumePeakDb;
    if (lufs != null && lufs.isFinite && url.isNotEmpty) {
      kugouUrlLoudness.remove(url);
      kugouUrlLoudness[url] = (lufs: lufs, peak: peak);
      // 持久化（fire-and-forget），限制数量
      if (kugouUrlLoudness.length >= 1) _persistLoudnessCache();
    }
    return this;
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

/// 热搜榜单（上游 `/api/v3/search/hot_tab` 的 `data.list` 元素）。
///
/// 上游每条只有 `keyword`（`reason` 与之完全重复、`icon/type/jumpurl/json_url`
/// 实测恒为空或固定值，**没有热度数值**），故模型只保留榜名与有序词表，
/// 不去伪造热度字段。
class HotSearchBoard {
  final String name;
  final List<String> keywords;

  const HotSearchBoard({required this.name, required this.keywords});

  /// 从 `/search/hot` 的响应 JSON 抽榜单。
  ///
  /// 关键：`data.list` 是**榜单数组**，词在 `list[i].keywords[j].keyword`。
  /// 直接把 `data.list` 当词数组取 `keyword ?? name` 会拿到一串榜名
  /// （这是旧实现 `kugou_api_client.dart` 的回归点）。
  static List<HotSearchBoard> parseList(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is! Map) return const [];
    final list = data['list'];
    if (list is! List) return const [];

    final boards = <HotSearchBoard>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final name = _str(entry['name']);
      final rawKeywords = entry['keywords'];
      if (name.isEmpty || rawKeywords is! List) continue;

      final words = <String>[];
      for (final item in rawKeywords) {
        final word = item is Map ? _str(item['keyword']) : _str(item);
        if (word.isNotEmpty) words.add(word);
      }
      if (words.isNotEmpty) {
        boards.add(HotSearchBoard(name: name, keywords: words));
      }
    }
    return boards;
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

/// 评论附带图片（上游评论项的 `images` 数组元素）。
///
/// 上游形如 `{"url": "...", "width": 2040, "height": 1530, "mark": 1, "label": "..."}`。
/// **URL 保持原样**：`webimg.bssdl.kugou.com` 没有有效 https 证书，
/// 统一改写 https 会导致图片加载失败；`network_security_config.xml` 已对
/// `kugou.com` 子域放行明文，http 与 https 都能直连。
class CommentImage {
  final String url;
  final int width;
  final int height;

  const CommentImage({required this.url, this.width = 0, this.height = 0});

  /// 宽高比；尺寸缺失或非法时回退 1.0，避免除零与布局塌陷。
  double get aspectRatio =>
      (width > 0 && height > 0) ? width / height : 1.0;

  /// 解析上游 images 数组，跳过无效项（无 url / 非 Map）。
  static List<CommentImage> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final out = <CommentImage>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final url = _str(e['url'] ?? e['img'] ?? e['pic'] ?? '');
      if (url.isEmpty) continue;
      out.add(
        CommentImage(
          url: url,
          width: _parseInt(e['width'] ?? 0),
          height: _parseInt(e['height'] ?? 0),
        ),
      );
    }
    return out;
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

  /// 作者 uid。楼中楼回复要把它作为「被回复者」写进 extdata.puser_id。
  final String? userId;

  /// 评论附带图片（可能多张）。
  final List<CommentImage> images;

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
    this.userId,
    this.images = const [],
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

    // 歌手/演唱者评论：上游在 topliked、comment 等接口里用 isAuthor=1 或
    // vinfo9.singer_status==4 标识演唱者本人发的评论（此时没有 is_star 字段），
    // 若不识别就无法把它从最热列表归入「歌手评论」栏并去重。
    final vinfo9 = json['vinfo9'] is Map<String, dynamic>
        ? json['vinfo9'] as Map<String, dynamic>
        : null;
    final isAuthorComment =
        parseBool(json['isAuthor'] ?? json['is_author']) ||
        (vinfo9 != null && _parseInt(vinfo9['singer_status']) == 4);

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
      isStar: parseBool(json['is_star'] ?? json['isStar'] ?? isStar) ||
          isAuthorComment,
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
      userId: _strNull(json['user_id'] ?? json['userid'] ?? json['kugouid']),
      images: CommentImage.listFromJson(json['images']),
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
    // data 既可能是对象（列表在 list/albums/info）也可能是**数组**；
    // 早先写死的 `as Map<String, dynamic>?` 在数组形态下抛 TypeError，
    // 被客户端 catch 静默吞成 null，表现为「歌手明明有专辑却显示暂无专辑」。
    final rawData = json['data'] ?? json;
    final list = rawData is List
        ? rawData
        : (rawData is Map
            ? (rawData['list'] ??
                rawData['albums'] ??
                rawData['info'] ??
                rawData['data'] ??
                [])
            : []);
    final totalSource = rawData is Map ? rawData : json;
    return KugouArtistAlbums(
      albums: (list as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map((e) => KugouAlbumBrief.fromJson(e))
          .toList(),
      total: _parseInt(
        totalSource['total'] ?? totalSource['total_count'] ?? json['total'] ?? 0,
      ),
    );
  }
}

class KugouMvBrief {
  final String videoId;
  final String name;
  final String? coverUrl;
  final String? authorName;
  final int timelengthMs;
  final String? publishDate;
  final String? albumAudioId;
  final String? hash;

  const KugouMvBrief({
    required this.videoId,
    required this.name,
    this.coverUrl,
    this.authorName,
    this.timelengthMs = 0,
    this.publishDate,
    this.albumAudioId,
    this.hash,
  });

  factory KugouMvBrief.fromJson(Map<String, dynamic> json) {
    // 上游缺失字段常返回空串而不是 null，而 [_strNull] 只做 toString、空串会原样留下，
    // 因此这里局部收口一次「空串当 null」（同 KugouSongDetail.fromJson 里的 firstIdOf 闭包写法）。
    String? textOf(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    return KugouMvBrief(
      videoId: _str(
        json['video_id'] ??
            json['id'] ??
            json['videoid'] ??
            '',
      ),
      name: _str(
        json['video_name'] ??
            json['name'] ??
            json['title'] ??
            json['mv_name'] ??
            '',
      ),
      coverUrl: _resolveFirstArtwork([
        json['hdpic'],
        json['cover'],
        json['pic'],
        json['imgurl'],
        json['sizable_cover'],
      ]),
      authorName: textOf(
        json['author_name'] ??
            json['singer_name'] ??
            json['singername'] ??
            json['author'],
      ),
      timelengthMs: _parseInt(json['timelength'] ?? json['duration'] ?? 0),
      publishDate: textOf(
        json['publish_date'] ??
            json['publishtime'] ??
            json['publish_time'],
      ),
      albumAudioId: textOf(
        json['album_audio_id'] ?? json['albumaudio_id'],
      ),
      // 清晰度由高到低回落；无 mkv_ 前缀的键名在同族上游里也出现过
      // （见 KugouSceneVideo.fromJson 的 sd_hash / qhd_hash）
      hash: textOf(
        json['mkv_qhd_hash'] ??
            json['mkv_hd_hash'] ??
            json['mkv_sd_hash'] ??
            json['qhd_hash'] ??
            json['sd_hash'] ??
            json['video_hash'] ??
            json['hash'],
      ),
    );
  }
}

class KugouArtistVideos {
  final List<KugouMvBrief> mvs;
  final int total;

  const KugouArtistVideos({this.mvs = const [], this.total = 0});

  factory KugouArtistVideos.fromJson(Map<String, dynamic> json) {
    try {
      dynamic rawData = json['data'] ?? json;
      List<dynamic> list;
      if (rawData is List) {
        list = rawData;
      } else if (rawData is Map) {
        list =
            rawData['list'] ??
                rawData['info'] ??
                rawData['videos'] ??
                rawData['items'] ??
                [];
      } else {
        list = [];
      }

      // total 同样双口径：先看根节点，再看 data Map 里的是否带总数
      int parsedTotal = 0;
      if (json['total'] != null || json['cur_total'] != null) {
        parsedTotal = _parseInt(json['total'] ?? json['cur_total']);
      } else if (rawData is Map &&
          (rawData['total'] != null || rawData['total_count'] != null)) {
        parsedTotal = _parseInt(rawData['total'] ?? rawData['total_count']);
      }

      final mvs = <KugouMvBrief>[];
      for (final e in list) {
        if (e is! Map) continue;
        final mv = KugouMvBrief.fromJson(Map<String, dynamic>.from(e));
        if (mv.videoId.isNotEmpty) {
          mvs.add(mv);
        }
      }

      return KugouArtistVideos(mvs: mvs, total: parsedTotal);
    } catch (e) {
      // 真机定位上游字段名用，不能静默吞掉
      // ignore: avoid_print
      print('[ArtistMvDebug] parse error: $e, raw: $json');
      rethrow;
    }
  }
}

class KugouArtistAudios {
  final List<KugouSongDetail> songs;
  final int total;

  const KugouArtistAudios({this.songs = const [], this.total = 0});

  factory KugouArtistAudios.fromJson(Map<String, dynamic> json) {
    dynamic rawData = json['data'] ?? json;
    List<dynamic> list;
    if (rawData is List) {
      list = rawData;
    } else if (rawData is Map) {
      list = rawData['list'] ?? rawData['songs'] ?? rawData['info'] ?? [];
    } else {
      list = [];
    }
    
    // total 可能是根节点的 total，也可能是 data 里的 total
    int parsedTotal = 0;
    if (json['total'] != null) {
      parsedTotal = _parseInt(json['total']);
    } else if (rawData is Map && (rawData['total'] != null || rawData['total_count'] != null)) {
      parsedTotal = _parseInt(rawData['total'] ?? rawData['total_count']);
    }

    return KugouArtistAudios(
      songs: list.map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>)).toList(),
      total: parsedTotal,
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

/// 解析可选浮点字段（响度/峰值等）。缺失或非有限值时返回 null。
double? _optDouble(dynamic v) {
  if (v == null) return null;
  final parsed = v is num ? v.toDouble() : double.tryParse(v.toString());
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
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

  /// 蝰蛇母带（/v6/priv_url qualities 下标 6，等级 101，需要 VIP）。
  /// Rust 侧 song_url_new.rs 的 QUALITIES 已包含该值，按下标命中即回写此音质。
  static const String viperTape = 'viper_tape';

  /// 音质代号 → 中文标签
  static const labels = {
    standard: '标准音质',
    high: '高音质',
    lossless: '无损音质',
    hires: 'Hi-Res',
    viperTape: '蝰蛇母带',
  };

  static String labelOf(String quality) => labels[quality] ?? quality;
}

class KugouUserDetail {
  final String? nickname;
  final String? avatar;
  final String? userid;
  final String? username;
  final Map<String, dynamic>? rawData;

  /// 个性签名（候选键 signature/usersign/sign；真实字段名以真机
  /// [USER_DETAIL] 日志为准，见 kugou_api_client.getUserDetail）
  final String? signature;

  /// 性别：0 女 / 1 男 / 2 保密（修改接口 /user/update 的取值约定）
  final int? sex;

  /// 生日（yyyy-MM-dd；上游返回时间戳时换算为该格式）
  final String? birthday;

  /// 省份/城市。上游 /v3/get_my_info 可能返回名称或数字代码，
  /// 而修改接口要传名称——UI 侧按原样展示并手输兜底。
  final String? province;
  final String? city;

  /// 备注
  final String? memo;

  /// 标签（上游返回数组时以逗号连接；修改接口接受逗号分隔字符串）
  final String? tags;

  const KugouUserDetail({
    this.nickname,
    this.avatar,
    this.userid,
    this.username,
    this.rawData,
    this.signature,
    this.sex,
    this.birthday,
    this.province,
    this.city,
    this.memo,
    this.tags,
  });

  factory KugouUserDetail.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouUserDetail(
      nickname: _strNull(data['nickname'] ?? data['username'] ?? data['name']),
      avatar: _resolveArtworkUri(data['avatar'] ?? data['img'] ?? data['pic']),
      userid: _strNull(data['userid'] ?? data['userId'] ?? data['id']),
      username: _strNull(data['username'] ?? data['name']),
      rawData: data,
      signature: _firstStr(data, const ['signature', 'usersign', 'sign']),
      sex: _firstSex(data),
      birthday: _firstBirthday(data),
      province: _firstStr(data, const ['province', 'provinceName', 'province_name']),
      city: _firstStr(data, const ['city', 'cityName', 'city_name']),
      memo: _firstStr(data, const ['memo']),
      tags: _firstTags(data),
    );
  }

  static String? _firstTags(Map<String, dynamic> data) {
    final v = data['tags'];
    if (v == null) return null;
    if (v is List) {
      final s = v.map((e) => e.toString()).where((e) => e.isNotEmpty).join(',');
      return s.isEmpty ? null : s;
    }
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  static String? _firstStr(Map<String, dynamic> data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v == null) continue;
      final s = v.toString();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  static int? _firstSex(Map<String, dynamic> data) {
    for (final k in const ['sex', 'gender']) {
      final v = data[k];
      if (v is num) return v.toInt();
      if (v is String) {
        final parsed = int.tryParse(v.trim());
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static String? _firstBirthday(Map<String, dynamic> data) {
    final v = data['birthday'];
    if (v == null) return null;
    // 时间戳（秒或毫秒）→ yyyy-MM-dd
    final n = v is num ? v.toInt() : (v is String ? int.tryParse(v.trim()) : null);
    if (n != null) {
      if (n <= 0) return null;
      final ms = n > 100000000000 ? n : n * 1000;
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
}

/// 听歌偏好（/user/preference 返回的 data）。
///
/// lang/style 为基础偏好的 JSON 字符串（{"标签id":权重}，>50 视为启用）；
/// song_lang 为歌曲推荐强度 JSON 字符串（0 屏蔽 / 50 默认 / 100 加大），标签为
/// L*/S*/T*/N* 前缀 ID（L1 国语、L2 英语、L5 粤语、L4 韩语、L3 日语、L6 纯音乐、
/// S9 DJ、T1 翻唱、N2 现场、S28 AI 歌曲）。**两组标签 ID 相互独立，不应互相转换**。
/// gender/age/mode 为单个 id 字符串（'' = 未设置）。
class KugouUserPreference {
  /// 推荐模式：'' 未设置 / 0 默认 / 1 熟悉 / 2 尝鲜
  final String mode;

  /// 性别 id：'' 未设置 / 1 女 / 2 男
  final String gender;

  /// 年龄段 id：'' 未设置 / 0 其它 / 1 00后 / 2 90后 / 3 80后 / 4 70后 /
  /// 6 10后 / 7 05后 / 8 95后 / 9 85后 / 10 75后 / 11 65后 / 12 60后
  final String age;

  /// 语言偏好（{"标签id": 权重}，>50 视为启用）
  final Map<String, int> lang;

  /// 风格偏好（{"标签id": 权重}，>50 视为启用）
  final Map<String, int> style;

  /// 歌曲推荐强度（{"标签id": 0-100}，0 屏蔽 / 50 默认 / 100 加大）
  final Map<String, int> songLang;

  /// 三组 JSON 串的原始文本（UI 回显未识别标签、diff 兜底用）
  final String langRaw;
  final String styleRaw;
  final String songLangRaw;

  /// 其余上游原样字段（stylerec_taglist / wish_taglist / inactive_taglist /
  /// inactive_singerlist / song_style 等，UI 暂不消费，更新时原样保留语义）
  final Map<String, dynamic> rawData;

  const KugouUserPreference({
    this.mode = '',
    this.gender = '',
    this.age = '',
    this.lang = const {},
    this.style = const {},
    this.songLang = const {},
    this.langRaw = '',
    this.styleRaw = '',
    this.songLangRaw = '',
    this.rawData = const {},
  });

  factory KugouUserPreference.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    String rawOf(dynamic v) => v == null ? '' : v.toString();
    return KugouUserPreference(
      mode: rawOf(data['mode']),
      gender: rawOf(data['gender']),
      age: rawOf(data['age']),
      langRaw: rawOf(data['lang']),
      styleRaw: rawOf(data['style']),
      songLangRaw: rawOf(data['song_lang']),
      lang: _parseWeightMap(data['lang']),
      style: _parseWeightMap(data['style']),
      songLang: _parseWeightMap(data['song_lang']),
      rawData: data,
    );
  }

  /// 解析 {"1":100,"3":50} 形态的权重 JSON 串；非 Map / 解析失败回退空 map
  /// （原始串保留在 *Raw 字段）。
  static Map<String, int> _parseWeightMap(dynamic raw) {
    if (raw == null || raw.toString().isEmpty) return const {};
    if (raw is Map) {
      return _coerceWeightMap(raw);
    }
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map) return _coerceWeightMap(decoded);
    } catch (_) {}
    return const {};
  }

  static Map<String, int> _coerceWeightMap(Map<dynamic, dynamic> source) {
    final out = <String, int>{};
    source.forEach((k, v) {
      final n = v is num ? v.toInt() : int.tryParse(v.toString().trim());
      if (n != null) out[k.toString()] = n;
    });
    return out;
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

/// 歌曲成绩单（/song/ranking）：歌曲在各平台榜单的成就汇总。
class KugouSongRanking {
  final String? title;

  /// 平台汇总文案（如"该歌曲累计上榜 N 次"）。
  final String? title2;

  /// 各平台成就卡列表（data.info）。
  final List<KugouSongRankingInfo> info;

  const KugouSongRanking({
    this.title,
    this.title2,
    this.info = const [],
  });

  factory KugouSongRanking.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final rawInfo = data['info'];
    final info = rawInfo is List
        ? rawInfo
            .whereType<Map<String, dynamic>>()
            .map(KugouSongRankingInfo.fromJson)
            .toList()
        : const <KugouSongRankingInfo>[];
    return KugouSongRanking(
      // 实测响应只有 title1（"已上榜 4/17"）与 title2（平台总述），无 title 字段
      title: _strNull(data['title'] ?? data['title1']),
      title2: _strNull(data['title2']),
      info: info,
    );
  }
}

/// 成绩单平台成就卡：一个平台一条（当前名次/累计上榜/最近上榜）。
class KugouSongRankingInfo {
  final int? platform;
  final String? platformName;

  /// 当前名次（ranking_num）。
  final int? rankingNum;

  /// 累计上榜次数。
  final int? rankingTimes;

  /// 最近上榜时间（上游原始字符串）。
  final String? lastTime;
  final String? logoPic;
  final String? sharePic;

  const KugouSongRankingInfo({
    this.platform,
    this.platformName,
    this.rankingNum,
    this.rankingTimes,
    this.lastTime,
    this.logoPic,
    this.sharePic,
  });

  factory KugouSongRankingInfo.fromJson(Map<String, dynamic> json) {
    return KugouSongRankingInfo(
      platform: _parseIntOrNull(json['platform']),
      platformName: _strNull(json['platform_name'] ?? json['platformName']),
      rankingNum: _parseIntOrNull(json['ranking_num'] ?? json['rankingNum']),
      rankingTimes:
          _parseIntOrNull(json['ranking_times'] ?? json['rankingTimes']),
      lastTime: _strNull(json['last_time'] ?? json['lastTime']),
      // 实测响应字段为 platform_logo；其余为旧口径/ camelCase 兜底
      logoPic: _strNull(
        json['platform_logo'] ??
            json['platformLogo'] ??
            json['logo_pic'] ??
            json['logoPic'] ??
            json['logo'],
      ),
      sharePic: _strNull(json['share_pic'] ?? json['sharePic']),
    );
  }
}

/// 成绩单详情（/song/ranking/filter）：单个子榜单的历史成绩条目。
class KugouSongRankingFilterItem {
  final int? area;
  final String? name;

  /// 累计上榜次数。
  final int? count;

  /// 历史最高名次（top_ranking，<=0 视为暂无排名）。
  final int? topRanking;
  final int? platform;
  final String? platformName;
  final String? logoPic;
  final String? sharePic;

  const KugouSongRankingFilterItem({
    this.area,
    this.name,
    this.count,
    this.topRanking,
    this.platform,
    this.platformName,
    this.logoPic,
    this.sharePic,
  });

  factory KugouSongRankingFilterItem.fromJson(Map<String, dynamic> json) {
    return KugouSongRankingFilterItem(
      area: _parseIntOrNull(json['area']),
      name: _strNull(json['name']),
      count: _parseIntOrNull(json['count']),
      topRanking: _parseIntOrNull(json['top_ranking'] ?? json['topRanking']),
      platform: _parseIntOrNull(json['platform']),
      platformName: _strNull(json['platform_name'] ?? json['platformName']),
      logoPic: _strNull(
        json['platform_logo'] ??
            json['platformLogo'] ??
            json['logo_pic'] ??
            json['logoPic'] ??
            json['logo'],
      ),
      sharePic: _strNull(json['share_pic'] ?? json['sharePic']),
    );
  }
}

/// 伴奏匹配（/audio/accompany/matching）：上游为这首歌返回的最佳伴奏曲目。
/// 实测响应（探针 tests/smoke.rs::accompany_matching_probe）：
/// `{"data":{"singername":"希林娜依高","accompanySongId":"43522508","remark":"伴奏",
///   "bitrate":"128","filesize":"3457210","songname":"Shine Brighter (愈加璀璨)",
///   "duration":"216000","extname":"mp3","hash":"8153F7E7…","songid":"43522508",…},
///   "error_code":0,"status":1}`
class KugouAccompany {
  /// 上游业务状态：1 = 匹配成功。
  final int? status;
  final int? errorCode;

  /// 伴奏曲目 hash（试听播放入口，也是 K 歌数量接口 songHash 入参的来源）。
  final String? hash;

  /// 伴奏曲目名（如 "Shine Brighter (愈加璀璨)"）。
  final String? songName;
  final String? singerName;

  /// 伴奏时长（毫秒，上游为字符串数字）。
  final int? durationMs;

  /// 音质信息：码率 kbps / 扩展名 / 文件大小（字节）。
  final int? bitrate;
  final String? extName;
  final int? fileSize;

  /// 上游备注（实测恒为 "伴奏"）。
  final String? remark;

  /// 伴奏曲目 id（K 歌数量接口 songId 入参的来源）。
  final String? songId;

  const KugouAccompany({
    this.status,
    this.errorCode,
    this.hash,
    this.songName,
    this.singerName,
    this.durationMs,
    this.bitrate,
    this.extName,
    this.fileSize,
    this.remark,
    this.songId,
  });

  /// 匹配成功且伴奏 hash 可用（可试听 / 可作 K 歌数量入参）。
  bool get hasMatch => status == 1 && (hash?.isNotEmpty ?? false);

  factory KugouAccompany.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouAccompany(
      status: _parseIntOrNull(json['status']),
      errorCode: _parseIntOrNull(json['error_code']),
      hash: _strNull(data['hash']),
      songName: _strNull(data['songname'] ?? data['songName']),
      singerName: _strNull(data['singername'] ?? data['singerName']),
      durationMs: _parseIntOrNull(data['duration']),
      bitrate: _parseIntOrNull(data['bitrate']),
      extName: _strNull(data['extname'] ?? data['extName']),
      fileSize: _parseIntOrNull(data['filesize'] ?? data['fileSize']),
      remark: _strNull(data['remark']),
      songId: _strNull(data['songid'] ?? data['accompanySongId'] ?? data['songId']),
    );
  }
}

/// K 歌数量（/audio/ktv/total）：这首歌在酷狗 K 歌曲库的伴奏作品总数。
/// 入参（songId/singerName/songHash）取自 [KugouAccompany] 的返回。
/// 实测响应（探针 tests/smoke.rs::audio_ktv_total_probe）：
/// `{"code":0,"msg":"","times":…,"data":{"totalOpusNum":"248"}}`
class KugouAudioKtvTotal {
  /// K 歌作品总数（totalOpusNum，上游为字符串数字）。
  final int? totalOpusNum;

  const KugouAudioKtvTotal({this.totalOpusNum});

  factory KugouAudioKtvTotal.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouAudioKtvTotal(
      totalOpusNum:
          _parseIntOrNull(data['totalOpusNum'] ?? data['total_opus_num']),
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

/// 限免/可播判定。
///
/// 实测（album 202415911「北大怀沙说三国演义」，2026-08 抓包）证实：听书章节列表
/// 接口 `/longaudio/v2/album_audios` 的 fail_process / fail_process_128 字段可靠：
/// 免费/限免章节为 0，付费章节为 32（privilege=10）。据此可直接过滤付费章节，
/// 无需再依赖播放层 31863 no free part 拦截。
bool _isLongAudioCanPlay(Map<String, dynamic> json) {
  final v128 = _parseIntOrNull(json['fail_process_128']);
  if (v128 != null && v128 != 0) return false;
  final v = _parseIntOrNull(json['fail_process']);
  if (v != null && v != 0) return false;
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

/// 从 `/home/discover`（上游 `homediscoverrec/v1/client/home_discover_rec`）的原始
/// 响应里取出歌曲列表。
///
/// 上游的 JS 参考实现把 JSON **原样透传**，既无字段文档也无样例响应，歌曲数组究竟
/// 挂在哪个键上无从确认，因此这里按「通用信封 → 多键兜底 → 逐条降级」来解析：任何
/// 一层形状不符都只损失那一条、或整体退化为空列表，**绝不把异常抛给调用方**——刷歌
/// 推荐页必须在酷狗改字段时继续可用，而不是整页崩掉。单条解析直接交给
/// [KugouSongDetail.fromJson]（它已处理 `album_info`/`audio_info`/`Singers`/`authors`
/// 等多种嵌套形态），此处不重复造。
///
/// 候选键优先级：`song_list` → `songs` → `list` → `info` → `data` → `items`。
/// `data` 这个键在酷狗响应里既可能是信封也可能是数组本身（`{data:[...]}`），所以先
/// 判它是不是 `List`，是的话直接当歌曲列表用，不再按候选键下钻。
List<KugouSongDetail> parseHomeDiscoverSongs(Map<String, dynamic> json) {
  // 逐条映射：非 Map 元素与单条解析异常都只跳过这一条，不牵连同批其余歌曲。
  List<KugouSongDetail> take(List<dynamic> raw) {
    final songs = <KugouSongDetail>[];
    for (final element in raw) {
      if (element is! Map<String, dynamic>) continue;
      try {
        songs.add(KugouSongDetail.fromJson(element));
      } catch (_) {
        continue;
      }
    }
    return songs;
  }

  try {
    final envelope = json['data'];
    // `data` 本身就是数组：信封即列表，此时根对象上的其它键不该抢优先级。
    if (envelope is List) return take(envelope);
    // `data` 是 Map 才按通用信封下钻；键缺失或类型不对就直接用根对象，
    // 因为确有响应不带信封、歌曲键挂在顶层的形态。
    final body = envelope is Map ? envelope : json;
    for (final key in const [
      'song_list',
      'songs',
      'list',
      'info',
      'data',
      'items',
    ]) {
      final value = body[key];
      if (value is List) return take(value);
    }
    // 兜底：候选键全落空时，根对象 / data 自身就是数组也接受（键名不在候选表
    // 内）。入参签名固定为 `Map<String, dynamic>`，故「根为数组」实际走不到，
    // 这里保留检查只为把该不变量写死；`data` 为数组的形态已由上面的信封分支
    // 先命中，此处是双重保险。
    for (final holder in <Object?>[json, envelope]) {
      if (holder is List) return take(holder);
    }
    return const [];
  } catch (_) {
    return const [];
  }
}

/// `/login/device`（酷狗 `userinfoservice.kugou.com/v2/get_dev`）返回的单台登录
/// 设备（`data.li[]` 条目）。字段全部字符串化：上游这些键在 JSON 里 string/number
/// 混用，而踢下线接口要求把它们原样回传（web 签名对 string/number 的拼接结果一致）。
///
/// 本机判定依赖 `/login/device` 响应顶层由 Rust 服务器注入的 `local_device`
/// （本机 mid/dfid，来自 device_info.json）——设备列表项的 `mid` 与之相同即为本机；
/// mid 缺失时回退 dfid（`mt` 键）比对。上游响应本身不带本机标识，不能用客户端
/// 自存的 dfid 判定（可能过期，误判会把本机标成可踢设备）。
class KugouLoginDevice {
  /// 设备 mid（kick 的 t_mid）。
  final String mid;

  /// 记录的 `mt` 键 = 本机 dfid。
  final String dfid;

  /// `dev` 键：机型描述。
  final String model;

  /// `app` 键：客户端平台。
  final String platform;

  /// `loc` 键：登录/活跃位置（如「广东省深圳市 联通」）。
  final String loc;

  /// `t` 键：活跃时间原始值（unix 秒或毫秒，亦是 kick 的 t）。
  final String t;

  /// `ver` 键：客户端版本（kick 的 t_clientver）。
  final String ver;

  /// `appid` 键：客户端 appid（kick 的 t_appid）。
  final String appid;

  /// `new` 键原始值：等于 [t] 且非 '0' 时视为新设备。
  final String newFlag;

  /// `login_type` 键：0 密码 1 手机 2 微信 3 QQ 4 苹果 5 微博 6 扫码。
  final String loginType;

  /// 是否本机（当前登录设备）。
  final bool isCurrent;

  /// 列表序号（1 起），仅作展示兜底「登录设备 N」。
  final int index;

  const KugouLoginDevice({
    required this.mid,
    required this.dfid,
    required this.model,
    required this.platform,
    required this.loc,
    required this.t,
    required this.ver,
    required this.appid,
    required this.newFlag,
    required this.loginType,
    required this.isCurrent,
    required this.index,
  });

  factory KugouLoginDevice.fromJson(
    Map<String, dynamic> json, {
    String localMid = '',
    String localDfid = '',
    int index = 0,
  }) {
    final mid = _str(json['mid']);
    final dfid = _str(json['mt']);
    return KugouLoginDevice(
      mid: mid,
      dfid: dfid,
      model: _strNull(json['dev']) ?? '',
      platform: _str(json['app']),
      loc: _strNull(json['loc']) ?? '',
      t: _str(json['t']),
      ver: _str(json['ver']),
      appid: _str(json['appid']),
      newFlag: _strNull(json['new']) ?? '',
      loginType: _str(json['login_type']),
      isCurrent: _isCurrentDevice(mid, dfid, localMid, localDfid),
      index: index,
    );
  }

  /// 本机判定：mid 双方齐全时按 mid 比对；否则回退 dfid。
  static bool _isCurrentDevice(
    String mid,
    String dfid,
    String localMid,
    String localDfid,
  ) {
    if (localMid.isEmpty && localDfid.isEmpty) return false;
    if (mid.isNotEmpty && localMid.isNotEmpty) return mid == localMid;
    if (dfid.isNotEmpty && localDfid.isNotEmpty) return dfid == localDfid;
    return false;
  }

  /// 能否被踢下线：非本机且 kick 四元组（mid/t/appid/ver）齐全。
  bool get canKick =>
      !isCurrent &&
      mid.isNotEmpty &&
      t.isNotEmpty &&
      appid.isNotEmpty &&
      ver.isNotEmpty;

  /// 新设备标记：`new === t` 且非 '0'（酷狗以登录时间回填 new）。
  bool get isNew => newFlag.isNotEmpty && newFlag == t && t != '0';

  /// 展示标题兜底链：机型 → 平台含安卓 → 平台 → 「登录设备 N」。
  String get title {
    final m = model.trim();
    if (m.isNotEmpty) return m;
    final p = platform.trim();
    if (p.isNotEmpty) {
      final lower = p.toLowerCase();
      if (p.contains('安卓') || lower.contains('android')) {
        return '酷狗Android客户端';
      }
      return p;
    }
    return index > 0 ? '登录设备 $index' : '登录设备';
  }

  /// 登录方式文案；未知值展示原值。
  String get loginTypeLabel {
    switch (loginType) {
      case '0':
        return '账号密码';
      case '1':
        return '手机';
      case '2':
        return '微信';
      case '3':
        return 'QQ';
      case '4':
        return '苹果';
      case '5':
        return '微博';
      case '6':
        return '扫码';
      default:
        return loginType.isEmpty ? '未知' : '未知($loginType)';
    }
  }

  /// 位置展示：loc 按空白/逗号/斜杠分割取最后一段（如「广东省深圳市 联通」→「联通」）。
  String get locationLabel {
    final l = loc.trim();
    if (l.isEmpty) return '';
    final parts =
        l.split(RegExp(r'[\s,，/]+')).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? l : parts.last;
  }

  /// 活跃时间的毫秒值（解析失败为 0，仅用于排序）。
  int get activeTimeMs => int.tryParse(t) ?? 0;

  /// 活跃时间展示：unix 秒（≤10 位 ×1000）/毫秒/日期串 → `yyyy-MM-dd HH:mm`。
  String get activeTimeText {
    final raw = t.trim();
    if (raw.isEmpty) return '';
    DateTime? time;
    final ms = int.tryParse(raw);
    if (ms != null) {
      final normalized = raw.length <= 10 ? ms * 1000 : ms;
      time =
          DateTime.fromMillisecondsSinceEpoch(normalized);
    } else {
      time = DateTime.tryParse(raw);
    }
    if (time == null) return raw;
    return DateFormat('yyyy-MM-dd HH:mm').format(time);
  }
}

/// `/login/device` 完整响应的解析结果：设备列表（已按本机优先、活跃时间降序排列）
/// 与 Rust 服务器注入的本机设备标识。`ok` 为 false 表示上游返回了业务错误
/// （如 token 失效），此时 devices 为空但不应展示「暂无设备」。
class KugouLoginDeviceSnapshot {
  final List<KugouLoginDevice> devices;
  final String localMid;
  final String localDfid;
  final bool ok;

  const KugouLoginDeviceSnapshot({
    required this.devices,
    this.localMid = '',
    this.localDfid = '',
    this.ok = true,
  });

  factory KugouLoginDeviceSnapshot.fromJson(Map<String, dynamic> json) {
    // 业务成功判定与 KugouApiClient.isBizOk 同口径：error_code 0/缺失 且 status 1/缺失。
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final local = json['local_device'];
    final localMap = local is Map
        ? Map<String, dynamic>.from(local)
        : const <String, dynamic>{};
    final localMid = _str(localMap['mid']);
    final localDfid = _str(localMap['dfid']);
    final data = json['data'];
    final li = data is Map ? data['li'] : null;
    final rawList = li is List ? li : const [];
    final devices = <KugouLoginDevice>[];
    var index = 0;
    for (final item in rawList) {
      if (item is! Map) continue;
      index++;
      devices.add(
        KugouLoginDevice.fromJson(
          Map<String, dynamic>.from(item),
          localMid: localMid,
          localDfid: localDfid,
          index: index,
        ),
      );
    }
    devices.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      return b.activeTimeMs.compareTo(a.activeTimeMs);
    });
    return KugouLoginDeviceSnapshot(
      devices: devices,
      localMid: localMid,
      localDfid: localDfid,
      ok: ok,
    );
  }
}

/// 内容黑名单条目（/blacklist/list 的 data.items 项）。
/// 歌曲条目含 `song_k/song_v`（k 为小写 FileHash），歌手条目含 `singer_k/singer_v`
/// （k 为歌手 ID）；*_v 为 JSON 字符串 `{"n":显示名,"m":mixsongid(仅歌曲),"t":秒}`，
/// 解析容忍字符串/对象两种形态，失败按空值处理（显示名空时由调用方回退）。
class KugouBlacklistEntry {
  /// 黑名单类型：song / singer
  final String label;

  /// 条目键：歌曲为 FileHash（小写），歌手为歌手 ID
  final String key;

  /// 显示名（歌曲为「歌手 - 歌名」，歌手为歌手名；空串回退「未命名歌曲/歌手」）
  final String name;

  /// 歌曲 MixSongID（仅歌曲条目，用于展示与跳转）
  final String? mixSongId;

  /// 标记时间（unix 秒；上游缺失时 0，UI 不显示时间行）
  final int createdAtSec;

  const KugouBlacklistEntry({
    required this.label,
    required this.key,
    this.name = '',
    this.mixSongId,
    this.createdAtSec = 0,
  });

  static (String name, String? mixSongId, int t) _parseValue(dynamic value) {
    dynamic obj;
    if (value is String && value.isNotEmpty) {
      try {
        obj = jsonDecode(value);
      } catch (_) {
        obj = null;
      }
    } else if (value is Map) {
      obj = value;
    }
    if (obj is! Map) return ('', null, 0);
    final t = obj['t'];
    return (
      obj['n']?.toString() ?? '',
      obj['m']?.toString(),
      t is num ? t.toInt() : int.tryParse('${t ?? ''}') ?? 0,
    );
  }

  factory KugouBlacklistEntry.fromJson(Map<String, dynamic> json) {
    final hasSong = json['song_k'] != null;
    final hasSinger = json['singer_k'] != null;
    final isSong = hasSong || !hasSinger;
    final parsed = _parseValue(isSong ? json['song_v'] : json['singer_v']);
    // 时间以 value 内的 t 为准，缺失回退条目级 t（用户文档返回示例的两级字段）
    final outerT = json['t'];
    final createdAt = parsed.$3 != 0
        ? parsed.$3
        : (outerT is num
            ? outerT.toInt()
            : int.tryParse('${outerT ?? ''}') ?? 0);
    return KugouBlacklistEntry(
      label: isSong ? 'song' : 'singer',
      key: (isSong ? json['song_k'] : json['singer_k'])?.toString() ?? '',
      name: parsed.$1,
      mixSongId: parsed.$2,
      createdAtSec: createdAt,
    );
  }

  /// 显示名；空名回退 [fallback]（歌曲「未命名歌曲」/ 歌手「未命名歌手」，EchoMusic 同款）。
  String displayName(String fallback) => name.isEmpty ? fallback : name;

  /// 标记时间展示：`yyyy-MM-dd`；无时间（0）返回空串。
  String get createdAtText {
    if (createdAtSec <= 0) return '';
    return DateFormat('yyyy-MM-dd')
        .format(DateTime.fromMillisecondsSinceEpoch(createdAtSec * 1000));
  }
}

/// `/blacklist/list` 完整响应的解析结果。`ok` 为 false 表示上游返回业务错误
/// （如 token 失效），此时 entries 为空但不应展示「黑名单为空」。
class KugouBlacklistSnapshot {
  final String label;
  final int page;
  final int pagesize;
  final int total;
  final List<KugouBlacklistEntry> entries;
  final bool ok;

  const KugouBlacklistSnapshot({
    this.label = 'song',
    this.page = 1,
    this.pagesize = 30,
    this.total = 0,
    this.entries = const [],
    this.ok = true,
  });

  factory KugouBlacklistSnapshot.fromJson(Map<String, dynamic> json) {
    // 业务成功判定与 KugouApiClient.isBizOk 同口径：error_code 0/缺失 且 status 1/缺失。
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final data = json['data'];
    final dataMap = data is Map ? Map<String, dynamic>.from(data) : const {};
    final rawList = dataMap['items'];
    final entries = <KugouBlacklistEntry>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is! Map) continue;
        try {
          entries.add(
            KugouBlacklistEntry.fromJson(Map<String, dynamic>.from(item)),
          );
        } catch (_) {
          // 单条解析失败跳过，不影响整页
        }
      }
    }
    int toInt(dynamic v, int fallback) =>
        v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
    return KugouBlacklistSnapshot(
      label: dataMap['label']?.toString() ?? 'song',
      page: toInt(dataMap['page'], 1),
      pagesize: toInt(dataMap['pagesize'], 30),
      total: toInt(dataMap['total'], entries.length),
      entries: entries,
      ok: ok,
    );
  }
}

// ==================== 云端听歌记录（/user/listen · /user/history） ====================
//
// 上游响应结构未文档化（listenservice /v2/get_list 与 playhistory /v1/get_songs），
// 解析一律防御式：数组位置多候选 + 字段别名多候选 + 单条失败跳过。
// 首次实调后若确认了真实字段，可在此收窄候选集（保留兜底不影响正确性）。

/// 在 `data`（或响应根）下按候选键找歌曲条目数组。
/// 返回 `null` 表示没找到数组；空数组是合法结果（云端确实没有记录）。
///
/// **`lists` 为 2026-10-11 实机确认的真值键**（`/user/listen` 空响应样本：
/// `data:{data_date, servertime, lists:[], total_history, total_week,
/// hide_mixsongids}`）；其余候选为防御式兜底（响应结构未文档化）。
/// 条目级字段（hash/名称/次数/时间）尚无真实非空样本，全部走
/// [KugouSongDetail] 的别名解析；首次拿到非空响应后应核对并收窄。
List<dynamic>? _findListenItemArray(Map<String, dynamic> json) {
  final data = json['data'];
  final scopes = <Map<String, dynamic>>[
    if (data is Map) Map<String, dynamic>.from(data),
    json,
  ];
  for (final scope in scopes) {
    for (final key in const ['lists', 'info', 'list', 'songs', 'data', 'items']) {
      final v = scope[key];
      if (v is List) return v;
    }
  }
  return null;
}

/// 从条目里取出可交给 [KugouSongDetail.fromJson] 的歌曲信息层：
/// 条目本身，或其内嵌的 `info`/`song`/`data` 子对象（部分响应把歌曲字段包一层）。
Map<String, dynamic>? _listenItemSongMap(dynamic item) {
  if (item is! Map) return null;
  final direct = Map<String, dynamic>.from(item);
  if (KugouSongDetail.itemLooksLikeSong(direct)) return direct;
  for (final key in const ['info', 'song', 'data', 'base']) {
    final inner = item[key];
    if (inner is Map) {
      final m = Map<String, dynamic>.from(inner);
      if (KugouSongDetail.itemLooksLikeSong(m)) return m;
    }
  }
  return direct;
}

/// 播放次数候选字段（酷狗各接口口径不一，全部尝试）。
/// `/user/listen` 实机确认的字段是 `listen_count`（2026-10-11）。
int? _listenItemPlayCount(Map<String, dynamic> item) {
  for (final key in const [
    'listen_count',
    'count',
    'play_count',
    'playcount',
    'score',
    'pc',
  ]) {
    final v = item[key];
    if (v is num && v > 0) return v.toInt();
    final parsed = int.tryParse('${v ?? ''}');
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

/// 播放时间候选字段 → 归一化为秒级时间戳（≤10 位视为秒，>10 位视为毫秒）。
int _listenItemTimestampSec(Map<String, dynamic> item) {
  for (final key in const ['timestamp', 'time', 'ot', 'play_time', 'last_time']) {
    final v = item[key];
    final n = v is num
        ? v.toInt()
        : int.tryParse('${v ?? ''}');
    if (n == null || n <= 0) continue;
    return n <= 9999999999 ? n : n ~/ 1000;
  }
  return 0;
}

/// 云端听歌排行/历史里的单首歌曲（复用 [KugouSongDetail] 的字段别名解析转 [Song]）。
class KugouRankedSong {
  final Song song;

  /// 云端播放次数（响应未提供时为 null，UI 只显示排名不显示次数）。
  final int? playCount;

  const KugouRankedSong({required this.song, this.playCount});
}

/// `/user/listen`（listenservice /v2/get_list）的解析结果。
/// [ok] 为 false 表示上游返回业务错误（如未登录 token 失效），songs 为空。
class KugouListenRanking {
  /// 0 = 最近一周前 120 首，1 = 全部累计前 120 首
  final int type;
  final List<KugouRankedSong> songs;
  final bool ok;

  const KugouListenRanking({
    this.type = 0,
    this.songs = const [],
    this.ok = true,
  });

  factory KugouListenRanking.fromJson(
    Map<String, dynamic> json, {
    int type = 0,
  }) {
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final rawList = _findListenItemArray(json) ?? const [];
    final songs = <KugouRankedSong>[];
    for (final item in rawList) {
      final songMap = _listenItemSongMap(item);
      if (songMap == null) continue;
      try {
        final song = KugouSongDetail.fromJson(songMap).toSong();
        if (song.id.isEmpty) continue;
        songs.add(
          KugouRankedSong(
            song: song,
            playCount: _listenItemPlayCount(songMap),
          ),
        );
      } catch (_) {
        // 单条解析失败跳过，不影响整页
      }
    }
    return KugouListenRanking(type: type, songs: songs, ok: ok);
  }
}

/// `/user/history`（playhistory /v1/get_songs）里的单条最近播放记录。
///
/// 2026-10-11 实机确认的条目结构：`{mxid, ot, pc, op, sr, info:{name,
/// singername, hash, timelen, cover, mixsongid, album_id, singerinfo, ...}}`
/// —— 歌曲信息嵌套在 `info` 层，`pc` 为该曲累计播放次数（服务端保持 max），
/// `ot` 为最后一次播放时间（秒）。
class KugouHistoryEntry {
  final Song song;

  /// 播放时间（unix 秒；上游缺失为 0，UI 不显示时间）。
  final int timestampSec;

  /// 累计播放次数（上游 `pc`；缺失为 0）。
  final int playCount;

  const KugouHistoryEntry({
    required this.song,
    this.timestampSec = 0,
    this.playCount = 0,
  });
}

/// `/user/history` 的解析结果。[nextBp] 为下一页游标（响应里原样取出的
/// `bp`/`next_bp`/`cursor`，为空表示没有更多页或响应未提供游标）。
class KugouHistorySnapshot {
  final List<KugouHistoryEntry> entries;
  final String? nextBp;
  final bool ok;

  const KugouHistorySnapshot({
    this.entries = const [],
    this.nextBp,
    this.ok = true,
  });

  bool get hasMore {
    final bp = nextBp;
    return bp != null && bp.isNotEmpty;
  }

  factory KugouHistorySnapshot.fromJson(Map<String, dynamic> json) {
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final data = json['data'];
    final dataMap = data is Map
        ? Map<String, dynamic>.from(data)
        : const <String, dynamic>{};
    final rawList = _findListenItemArray(json) ?? const [];
    final entries = <KugouHistoryEntry>[];
    for (final item in rawList) {
      final songMap = _listenItemSongMap(item);
      if (songMap == null) continue;
      try {
        final song = KugouSongDetail.fromJson(songMap).toSong();
        if (song.id.isEmpty) continue;
        final itemMap =
            item is Map ? Map<String, dynamic>.from(item) : const <String, dynamic>{};
        final ts = _listenItemTimestampSec(itemMap);
        // pc = 该曲累计播放次数（实机确认字段；服务端保持 max）
        final pc = itemMap['pc'] is num
            ? (itemMap['pc'] as num).toInt()
            : int.tryParse('${itemMap['pc'] ?? ''}') ?? 0;
        entries.add(
          KugouHistoryEntry(song: song, timestampSec: ts, playCount: pc),
        );
      } catch (_) {
        // 单条解析失败跳过，不影响整页
      }
    }
    // 翻页游标：响应未文档化，多候选防御式提取（实调确认后可收窄）
    String? nextBp;
    for (final scope in <Map<String, dynamic>>[dataMap, json]) {
      for (final key in const ['bp', 'next_bp', 'nextBp', 'cursor']) {
        final v = scope[key];
        if (v == null) continue;
        final s = v.toString();
        if (s.isNotEmpty && s != '0') {
          nextBp = s;
          break;
        }
      }
      if (nextBp != null) break;
    }
    return KugouHistorySnapshot(entries: entries, nextBp: nextBp, ok: ok);
  }
}
