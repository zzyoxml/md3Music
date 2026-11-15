import 'dart:convert';

import '../../data/models/song.dart';

// ===========================================================================
// 通用防御式读取
//
// 一起听各接口的响应包裹层命名不统一（data 多层嵌套、字段可选同义名、
// 歌曲身份可能散落在 audio/song_info 等子对象里）。这里集中提供：
//   1. 递归解开 data 包裹（最多 5 层，字符串内嵌 JSON 也解析）
//   2. 多候选 key 的字符串/数字/布尔读取
//   3. 任意深度的字段扫描（list_version、quantity、room_state 等）
// 所有读取函数均为纯函数，便于单测覆盖。
// ===========================================================================

/// JSON 值尝试解析（字符串内嵌 JSON）；空串/不以 { [ 开头/解析失败时原样返回。
dynamic parseJsonValue(dynamic v) {
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return v;
    if (!s.startsWith('{') && !s.startsWith('[')) return v;
    try {
      return json.decode(s);
    } catch (_) {
      return v;
    }
  }
  return v;
}

/// 转成 `Map<String, dynamic>`（失败返回 null）。
Map<String, dynamic>? asRecord(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return null;
}

/// 递归解开 data 包裹层（最多 5 层），中间的 JSON 字符串也解析。
dynamic unwrapListenPayload(dynamic payload) {
  var value = parseJsonValue(payload);
  for (var depth = 0; depth < 5; depth++) {
    final rec = asRecord(value);
    if (rec == null || !rec.containsKey('data')) return value;
    value = parseJsonValue(rec['data']);
  }
  return value;
}

/// 多候选 key 读取字符串（String/num 均接受，去首尾空格）。
String readString(Map rec, List<String> keys) {
  for (final k in keys) {
    final v = rec[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is num) return v.toString();
  }
  return '';
}

/// 封面 URL 归一化（对齐 EchoMusic normalizeCoverUrl）：
/// ① http→https；② `{size}` 占位符替换为具体尺寸——酷狗搜索/详情接口
/// 常返回 `stdmusic/{size}/xxx.jpg` 形态，原样下发给 Image.network 必然
/// 404（表现为歌单封面加载不出、只有个别走了其他链路的歌能显示）；
/// ③ 旧域名 c1.kgimg.com → imge.kugou.com。
/// 对已是合法形态的 URL 幂等，无副作用。
String normalizeCoverUrl(String url, {int size = 400}) {
  final raw = url.trim();
  if (raw.isEmpty) return '';
  var cover = raw.replaceFirst('http://', 'https://');
  if (cover.contains('{size}')) {
    cover = cover.replaceAll('{size}', size.toString());
  }
  return cover.replaceFirst('c1.kgimg.com', 'imge.kugou.com');
}

/// 多候选 key 读取 int（可解析的数字字符串也接受）。
int readInt(Map rec, List<String> keys, [int fallback = 0]) {
  for (final k in keys) {
    final v = rec[k];
    if (v is num) return v.toInt();
    if (v is String && v.trim().isNotEmpty) {
      final n = int.tryParse(v.trim());
      if (n != null) return n;
    }
  }
  return fallback;
}

/// 多候选 key 读取 int，全部缺失/非法时返回 null（用于区分「0」与「缺失」）。
int? readOptionalInt(Map rec, List<String> keys) {
  for (final k in keys) {
    if (!rec.containsKey(k)) continue;
    final v = rec[k];
    if (v is num) return v.toInt();
    if (v is String && v.trim().isNotEmpty) {
      final n = int.tryParse(v.trim());
      if (n != null) return n;
    }
  }
  return null;
}

/// 多候选 key 读取布尔（0/1、"0"/"1"、bool 均接受）。
bool readBool(Map rec, bool fallback, List<String> keys) {
  for (final k in keys) {
    final v = rec[k];
    if (v is bool) return v;
    if (v == 0 || v == '0') return false;
    if (v == 1 || v == '1') return true;
  }
  return fallback;
}

/// 从 payload 中提取对象数组：data 直为数组 / data.xxx 候选键 / info 系嵌套再探。
List<Map<String, dynamic>> extractList(dynamic payload) {
  final data = unwrapListenPayload(payload);
  if (data is List) {
    return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }
  final rec = asRecord(data);
  if (rec == null) return const [];
  for (final k in const [
    'list',
    'songs',
    'song_info',
    'song_infos',
    'songs_info',
    'audios',
    'items',
    'members',
    'member_list',
    'user_list',
    'audio_list',
    'music_list',
    'rooms',
    'room_list',
    'messages',
    'msg_list',
    'infos',
  ]) {
    final parsed = parseJsonValue(rec[k]);
    if (parsed is List) {
      return parsed.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
  }
  for (final k in const ['info', 'room_info', 'member_info']) {
    if (!rec.containsKey(k)) continue;
    final nested = extractList(rec[k]);
    if (nested.isNotEmpty) return nested;
  }
  return const [];
}

/// 从 payload 任意深度提取房间号（groupid/group_id/room_id/roomid）。
/// 仅顶层允许字符串/数字直给；嵌套数值字段（join_time 等）绝不误认。
String extractRoomId(dynamic payload, [int depth = 0]) {
  if (depth > 6) return '';
  if (depth == 0 && (payload is String || payload is num)) {
    return payload.toString().trim();
  }
  final rec = asRecord(payload);
  if (rec == null) return '';
  final direct = readString(rec, const ['groupid', 'group_id', 'room_id', 'roomid']);
  if (direct.isNotEmpty) return direct;
  for (final v in rec.values) {
    if (v is Map || v is List) {
      final nested = extractRoomId(v, depth + 1);
      if (nested.isNotEmpty) return nested;
    }
  }
  return '';
}

/// 从 payload 任意深度读取指定 key 的第一个非空字符串（支持字符串数组）。
String readNestedString(dynamic payload, String key, [int depth = 0]) {
  if (depth > 6 || payload == null) return '';
  if (payload is Map) {
    final v = payload[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is num) return v.toString();
    if (v is List) {
      for (final item in v) {
        if (item is String && item.trim().isNotEmpty) return item.trim();
        if (item is num) return item.toString();
      }
    }
    for (final child in payload.values) {
      final nested = readNestedString(child, key, depth + 1);
      if (nested.isNotEmpty) return nested;
    }
  } else if (payload is List) {
    for (final item in payload) {
      final nested = readNestedString(item, key, depth + 1);
      if (nested.isNotEmpty) return nested;
    }
  }
  return '';
}

/// 从 payload 任意深度读取指定 key 的第一个正数。
int readNestedInt(dynamic payload, String key, [int depth = 0]) {
  if (depth > 6 || payload == null) return 0;
  if (payload is Map) {
    final v = payload[key];
    if (v is num && v > 0) return v.toInt();
    for (final child in payload.values) {
      final n = readNestedInt(child, key, depth + 1);
      if (n > 0) return n;
    }
  } else if (payload is List) {
    for (final item in payload) {
      final n = readNestedInt(item, key, depth + 1);
      if (n > 0) return n;
    }
  }
  return 0;
}

/// 任意深度查找布尔 flag（room_state / is_owner 等）：1 / "1" / true 视为真。
bool readNestedFlag(dynamic payload, String key, [int depth = 0]) {
  if (depth > 6 || payload == null) return false;
  if (payload is Map) {
    if (payload.containsKey(key)) {
      final v = payload[key];
      return v == 1 || v == '1' || v == true;
    }
    for (final child in payload.values) {
      if (readNestedFlag(child, key, depth + 1)) return true;
    }
  } else if (payload is List) {
    for (final item in payload) {
      if (readNestedFlag(item, key, depth + 1)) return true;
    }
  }
  return false;
}

/// 秒/毫秒归一：>10000 视为毫秒，否则按秒转毫秒。
int toMs(int raw) => raw > 10000 ? raw : raw * 1000;

/// 酷狗私有音频格式（房间授权地址若为这些扩展名，本机无法直接解码）。
final RegExp _kugouPrivateAudioExt =
    RegExp(r'\.(?:kgs|kgm|kgma|kgg|vpr)(?=$|[/?#&])', caseSensitive: false);

/// 判断是否为酷狗私有格式地址（含 URL 编码变体，如 %2Ekgs）。
bool isKugouPrivateAudioUrl(String url) {
  final normalized = url.trim();
  if (normalized.isEmpty) return false;
  if (_kugouPrivateAudioExt.hasMatch(normalized)) return true;
  try {
    return _kugouPrivateAudioExt.hasMatch(Uri.decodeComponent(normalized));
  } catch (_) {
    return false;
  }
}

// ===========================================================================
// 领域模型
// ===========================================================================

/// 广场/列表中的众乐房摘要。
class MusicRoomBrief {
  final String roomId;
  final String name;
  final String notice;
  final String backgroundUrl;

  /// 当前播放歌曲的专辑封面（上游位于 `song_info.album_info.sizable_cover`）。
  final String currentSongCover;
  final int memberCount;
  final int capacity;
  final String ownerId;
  final String ownerName;
  final String currentSongName;
  final String currentArtistName;
  final bool closed;

  /// 房主是否开启聊天（update_chat 口径）：归一为 1=开启 0=关闭。
  /// 上游原始值 0/2 均视为关闭、其余开启，字段缺失默认开启。
  final int allowChat;

  const MusicRoomBrief({
    required this.roomId,
    required this.name,
    required this.notice,
    required this.backgroundUrl,
    required this.currentSongCover,
    required this.memberCount,
    required this.capacity,
    required this.ownerId,
    required this.ownerName,
    required this.currentSongName,
    required this.currentArtistName,
    required this.closed,
    this.allowChat = 1,
  });

  factory MusicRoomBrief.fromJson(Map<String, dynamic> json) {
    // room_info/base_info 为低优先包裹层，顶层字段优先覆盖
    final base = <String, dynamic>{
      ...?asRecord(parseJsonValue(json['room_info'])),
      ...?asRecord(parseJsonValue(json['base_info'])),
      ...json,
    };
    final owner = <String, dynamic>{
      ...?asRecord(json['user_info']),
      ...?asRecord(json['owner_info']),
    };
    final song = <String, dynamic>{
      ...?asRecord(json['current_audio']),
      ...?asRecord(json['audio']),
      ...?asRecord(json['song_info']),
    };
    // 专辑封面藏在 song_info.album_info 下，按低优先顺序补齐
    final album = <String, dynamic>{
      ...?asRecord(song['album_info']),
      ...?asRecord(song['album']),
    };
    final songCover = readString(album, const [
      'sizable_cover',
      'album_sizable_cover',
      'cover',
      'img',
    ]);
    final songCoverFallback =
        readString(song, const ['sizable_cover', 'cover', 'img', 'cover_url']);
    final hidden = readOptionalInt(base, const ['is_hide']);
    final roomStatus = readOptionalInt(base, const ['room_status']);
    // 聊天开关：0/2 视为关闭、其余开启（缺失默认开启）。
    // readNestedInt 只收单 key 且缺失返回 0（会误判为关闭），
    // 因此用 readOptionalInt 做多候选 key 并区分「缺失」。
    final allowChatRaw = readOptionalInt(base, const ['allow_chat', 'allowchat']);
    final name = readString(base, const ['room_name', 'room_theme', 'name']);
    final ownerName = readString(owner, const ['nick_name', 'nickname', 'owner_name']);
    // 概念版众乐房常不返回 room_name，此时按概念版惯例用「{房主名}的众乐房」兜底
    final resolvedOwnerName = ownerName.isNotEmpty ? ownerName : '房主';
    return MusicRoomBrief(
      roomId: readString(base, const ['room_id', 'roomid', 'groupid', 'id']),
      name: name.isNotEmpty ? name : '$resolvedOwnerName的众乐房',
      notice: readString(base, const ['room_notice', 'notice']),
      // room_bg 来自推荐列表，pic 来自广场列表（room_info.pic）
      backgroundUrl: normalizeCoverUrl(readString(
        base,
        const ['bg_img', 'background_url', 'room_bg', 'pic', 'cover', 'img'],
      )),
      currentSongCover:
          normalizeCoverUrl(songCover.isNotEmpty ? songCover : songCoverFallback),
      memberCount: readOptionalInt(base, const [
            'member_count',
            'online_count',
            'online_user_count',
            'all_user_count',
            'member_num',
          ]) ??
          0,
      // 上游（广场/详情）均无可靠的房间人数上限字段（switch.max_mikecnt 是麦位
      // 上限而非人数上限，在线人数可以超过它），仅在直给 member_limit/capacity
      // 字段时采信，否则 0 表示未知，展示端只显示在线人数，不编造上限
      capacity: readOptionalInt(base, const ['member_limit', 'capacity']) ?? 0,
      ownerId: readString(owner, const ['userid', 'owner_id', 'uid']),
      ownerName: resolvedOwnerName,
      currentSongName: readString(song, const ['song_name', 'songname', 'audio_name']),
      currentArtistName:
          readString(song, const ['author_name', 'singer_name', 'singername']),
      closed: hidden != null ? hidden == 1 : (roomStatus != null ? roomStatus == 0 : false),
      allowChat: (allowChatRaw == 0 || allowChatRaw == 2) ? 0 : 1,
    );
  }

  /// 卡片缩略图：优先当前播放歌曲的专辑封面，缺失时回落房间背景图。
  String get thumbnailUrl =>
      currentSongCover.isNotEmpty ? currentSongCover : backgroundUrl;

  /// 已知房间号但无房间信息时使用的占位对象（凭房间号加入的场景）。
  factory MusicRoomBrief.byRoomId(String roomId) => MusicRoomBrief(
        roomId: roomId,
        name: '一起听房间',
        notice: '',
        backgroundUrl: '',
        currentSongCover: '',
        memberCount: 0,
        capacity: 0,
        ownerId: '',
        ownerName: '房主',
        currentSongName: '',
        currentArtistName: '',
        closed: false,
      );
}

/// 「我的房间」多源合并。
///
/// 来源优先级：`created`（我创建的房间，权威）> `detailed`（详情校验后的实时快照）
/// > `history`（历史列表，元数据最陈旧）。任一源不可用都不影响结果正确性——上游
/// `history` 可能报 20002、`status` 可能报 40007，不能因此让「我的房间」为空。
///
/// 房间号去重且**一律剔除已解散房间**；[selfUserId] 为空时（未登录）不做归属过滤。
List<MusicRoomBrief> mergeMyRooms({
  required List<MusicRoomBrief> created,
  required List<MusicRoomBrief> detailed,
  required List<MusicRoomBrief> history,
  required String selfUserId,
}) {
  bool ownedBySelf(MusicRoomBrief b) =>
      selfUserId.isEmpty || b.ownerId == selfUserId;

  final byId = <String, MusicRoomBrief>{};

  void put(MusicRoomBrief b, {required bool overwrite}) {
    if (b.roomId.isEmpty || b.closed) return;
    if (!overwrite && byId.containsKey(b.roomId)) return;
    byId[b.roomId] = b;
  }

  for (final b in history.where(ownedBySelf)) {
    put(b, overwrite: false);
  }
  for (final b in detailed.where(ownedBySelf)) {
    put(b, overwrite: true);
  }
  // created_rooms 是「我创建的房间」权威列表，其条目未必带 ownerId，
  // 因此不做归属过滤（归属由接口语义保证）。
  for (final b in created) {
    put(b, overwrite: true);
  }
  return byId.values.toList();
}

/// 众乐房内歌曲。
///
/// [hash] 为播放器/封面/歌词使用的标准版权键；
/// [originalHash]（上游 genting_hash）是房间游标与同步键，两者值可能不同，
/// 因此匹配同一首歌时必须同时参与比对。
class RoomSong {
  final String hash;
  final String originalHash;
  final String mixSongId;
  final String name;
  final String singer;
  final int durationSeconds;
  final String coverUrl;
  final String orderUserId;
  /// 歌手 id：跟随端只有 hash 身份，歌手/专辑详情页跳转依赖这两个字段。
  /// 上游接口常不返回，缺失时为空串（不要用 null，与 fromJson 口径一致）。
  final String artistId;
  /// 专辑 id，语义同 [artistId]。
  final String albumId;

  const RoomSong({
    required this.hash,
    required this.originalHash,
    required this.mixSongId,
    required this.name,
    required this.singer,
    required this.durationSeconds,
    required this.coverUrl,
    required this.orderUserId,
    this.artistId = '',
    this.albumId = '',
  });

  factory RoomSong.fromJson(Map<String, dynamic> json) {
    final hash = readString(json, const ['hash', 'file_hash', 'audio_hash']);
    final original = readString(json, const ['genting_hash', 'original_hash']);
    final duration = readInt(json, const ['duration', 'time_length', 'timelength']);
    return RoomSong(
      hash: hash.isNotEmpty ? hash : original,
      originalHash: original,
      mixSongId: readString(json, const [
        'mixsongid',
        'mixSongId',
        'mix_song_id',
        'album_audio_id',
        'genting_album_audio_id',
        'audio_id',
      ]),
      name: readString(json, const ['songname', 'song_name', 'filename', 'name', 'title']),
      singer: readString(json, const ['singername', 'singer_name', 'singername_str', 'singer']),
      // >10000 视为毫秒
      durationSeconds: duration > 10000 ? duration ~/ 1000 : duration,
      coverUrl: normalizeCoverUrl(readString(json, const [
        'img',
        'cover',
        'cover_url',
        'album_img',
        'album_sizable_cover',
        'sizable_cover',
      ])),
      orderUserId: readString(json, const ['order_userid', 'userid']),
      // 上游候选键：singerinfo 拆分出的 artist_id、authors 的 author_id、
      // 以及部分接口直给的 album_id / albumid
      artistId: readString(json, const ['artist_id', 'author_id', 'singer_id', 'singerid']),
      albumId: readString(json, const ['album_id', 'albumid', 'albumId']),
    );
  }

  /// 展示用歌名——剥离常见音频文件扩展名后缀。
  ///
  /// 众乐房歌单条目可能只给 `filename`（形如「歌手 - 歌名.mp3」），直接展示会
  /// 带上文件名后缀；与 [Song.displayName] 保持同一口径。
  String get displayName {
    final pattern = RegExp(
      r'\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$',
      caseSensitive: false,
    );
    return name.replaceFirst(pattern, '');
  }

  /// 仅用于元数据富化时局部替换；身份字段（hash/）不提供覆盖入口，
  /// 避免富化过程意外改变曲目身份导致歌单去重错乱。
  RoomSong copyWith({
    String? name,
    String? singer,
    int? durationSeconds,
    String? coverUrl,
    String? mixSongId,
    String? artistId,
    String? albumId,
  }) {
    return RoomSong(
      hash: hash,
      originalHash: originalHash,
      mixSongId: mixSongId ?? this.mixSongId,
      name: name ?? this.name,
      singer: singer ?? this.singer,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      coverUrl: coverUrl ?? this.coverUrl,
      orderUserId: orderUserId,
      artistId: artistId ?? this.artistId,
      albumId: albumId ?? this.albumId,
    );
  }

  /// 与另一首歌是否同一首（hash / genting_hash / mixSongId 全键比对）。
  bool sameAs(RoomSong other) {
    final myHashes = <String>{
      hash.toLowerCase(),
      if (originalHash.isNotEmpty) originalHash.toLowerCase(),
    };
    final otherHashes = <String>{
      other.hash.toLowerCase(),
      if (other.originalHash.isNotEmpty) other.originalHash.toLowerCase(),
    };
    if (myHashes.intersection(otherHashes).isNotEmpty) return true;
    if (mixSongId.isNotEmpty && mixSongId != '0' && mixSongId == other.mixSongId) return true;
    return false;
  }

  /// 是否对应远端快照正在播放的曲目。
  ///
  /// 与 [sameAs] 同口径但跨类型：接口返回的 `cur_song` 身份与本地歌曲 id 存在
  /// 大小写与形式错位（房间 hash 是 OGG 授权哈希，播放器 id 是标准版权哈希），
  /// 因此必须 hash / genting_hash / mixSongId 三键都比。
  bool matchesRemote(PlayerSyncState remote) {
    final remoteHash = remote.hash.toLowerCase();
    if (remoteHash.isNotEmpty &&
        (hash.toLowerCase() == remoteHash ||
            (originalHash.isNotEmpty && originalHash.toLowerCase() == remoteHash))) {
      return true;
    }
    return mixSongId.isNotEmpty &&
        mixSongId != '0' &&
        remote.mixSongId.isNotEmpty &&
        mixSongId == remote.mixSongId;
  }

  /// 从播放器 [Song] 反查房间条目身份。
  ///
  /// 众乐房歌单只认在线歌曲身份（hash / mixsongid），本地文件没有可上报的
  /// 上游 hash，传空表示「无法作为房间曲目」——调用方据此拦截建房与点歌，
  /// 避免把 `local_/storage/...` 这类本地 id 当成 hash 发给上游。
  static RoomSong fromSong(Song song) {
    final isLocal = !song.isOnline || song.localPath != null;
    return RoomSong(
      hash: isLocal ? '' : song.id,
      originalHash: '',
      mixSongId: song.albumAudioId ?? '',
      name: song.displayName,
      singer: song.artist,
      durationSeconds: song.duration.inSeconds,
      coverUrl: song.artworkUri ?? '',
      orderUserId: '',
      artistId: song.artistId ?? '',
      albumId: song.albumId ?? '',
    );
  }

  /// 转为播放器 Song 模型。
  /// [playUrl] 非空时播放器直接播放该授权地址；为空则走常规在线解析。
  Song toSong({String? playUrl}) {
    return Song(
      id: hash,
      title: name.isEmpty ? '未知歌曲' : name,
      artist: singer.isEmpty ? '未知歌手' : singer,
      album: '',
      isOnline: true,
      albumAudioId: mixSongId,
      // **空串必须归一成 null**：`PlayerProvider.playSong` 用 `song.url == null`
      // 区分「需要走在线解析」与「已有播放地址」。把空的授权地址原样传进来会让
      // `Song.url == ''`，playSong 于是跳过在线解析、直接走 `_resolvePlaybackUrl`
      // ——它对在线歌曲原样返回 `song.url`（''）→ 判定「解析失败」返回，
      // **音源从未被替换**，成员端 UI 已切到房主歌曲、声音却还是上一首。
      url: (playUrl != null && playUrl.trim().isNotEmpty) ? playUrl : null,
      artworkUri: coverUrl.isEmpty ? null : coverUrl,
      duration: Duration(seconds: durationSeconds),
      // 空串转 null：详情页的判断是 `artistId == null || artistId.isEmpty`，
      // 给 null 语义更干净，也避免下游把空串当有效 id 去请求
      artistId: artistId.isEmpty ? null : artistId,
      albumId: albumId.isEmpty ? null : albumId,
    );
  }
}

final RegExp _roomSongFileExtPattern =
    RegExp(r'\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$', caseSensitive: false);

/// 歌名是否可用作展示：排除空值、占位值与未处理的原始音频文件名。
///
/// 上游部分接口直给 `filename`（形如「歌手 - 歌名.mp3」），按「非空即覆盖」会把
/// 已富化的干净短歌名降级成文件名。
bool isUsefulRoomSongName(String name) {
  final s = name.trim();
  if (s.isEmpty || s == kUnknownSongTitle) return false;
  return !_roomSongFileExtPattern.hasMatch(s);
}

/// 封面 URL 是否可用。
bool isUsefulRoomSongCover(String url) => url.trim().isNotEmpty;

/// 元数据完整度评分：歌名 2 + 歌手 2 + 封面 3 + 时长 1 + 歌手 id 1 + 专辑 id 1。
int roomSongMetadataScore(RoomSong s) =>
    (isUsefulRoomSongName(s.name) ? 2 : 0) +
    (s.singer.isNotEmpty ? 2 : 0) +
    (isUsefulRoomSongCover(s.coverUrl) ? 3 : 0) +
    (s.durationSeconds > 0 ? 1 : 0) +
    (s.artistId.isNotEmpty ? 1 : 0) +
    (s.albumId.isNotEmpty ? 1 : 0);

/// 择优合并同一首歌的两条房间条目（缓存值 [cached] 与接口新值 [incoming]）。
///
/// 规则：
///  - **身份字段（hash / originalHash / mixSongId）一律「缓存非空优先」**，不参与
///    评分：它们决定曲目身份，被换成另一次解析的哈希会让歌单去重与当前歌指针错乱。
///  - 展示字段（歌名/歌手/封面/时长）按评分取「更有用」的一侧；一侧不可用时无条件
///    采用另一侧。
RoomSong mergeRoomSongPreferRicher(RoomSong cached, RoomSong incoming) {
  final incomingRicher = roomSongMetadataScore(incoming) > roomSongMetadataScore(cached);
  final rich = incomingRicher ? incoming : cached;
  final lean = incomingRicher ? cached : incoming;
  String pick(String Function(RoomSong) of, bool Function(String) useful) {
    final richValue = of(rich);
    if (useful(richValue)) return richValue;
    final leanValue = of(lean);
    return useful(leanValue) ? leanValue : '';
  }

  return RoomSong(
    hash: cached.hash.isNotEmpty ? cached.hash : incoming.hash,
    originalHash:
        cached.originalHash.isNotEmpty ? cached.originalHash : incoming.originalHash,
    mixSongId: (cached.mixSongId.isNotEmpty && cached.mixSongId != '0')
        ? cached.mixSongId
        : incoming.mixSongId,
    name: pick((s) => s.name, isUsefulRoomSongName),
    singer: pick((s) => s.singer, (v) => v.trim().isNotEmpty),
    durationSeconds:
        rich.durationSeconds > 0 ? rich.durationSeconds : lean.durationSeconds,
    coverUrl: pick((s) => s.coverUrl, isUsefulRoomSongCover),
    orderUserId:
        cached.orderUserId.isNotEmpty ? cached.orderUserId : incoming.orderUserId,
    artistId: cached.artistId.isNotEmpty ? cached.artistId : incoming.artistId,
    albumId: cached.albumId.isNotEmpty ? cached.albumId : incoming.albumId,
  );
}

/// 房间成员。
class RoomMember {
  final String userId;
  final String nickname;
  final String avatar;
  final int studyStatus;

  const RoomMember({
    required this.userId,
    required this.nickname,
    required this.avatar,
    required this.studyStatus,
  });

  factory RoomMember.fromJson(Map<String, dynamic> json) {
    // user_info / member_info 包裹层合并
    final merged = <String, dynamic>{
      ...?asRecord(json['user_info']),
      ...?asRecord(json['member_info']),
      ...json,
    };
    final nickname =
        readString(merged, const ['nick_name', 'nickname', 'username', 'user_name', 'name']);
    return RoomMember(
      userId: readString(merged, const ['userid', 'user_id', 'uid', 'id']),
      nickname: nickname.isNotEmpty ? nickname : '房间成员',
      avatar: readString(merged, const [
        'user_pic',
        'avatar',
        'headimg',
        'head_img',
        'img',
        'pic',
      ]),
      studyStatus: readInt(merged, const ['study_status']),
    );
  }
}

/// sync_player 返回的远端播放快照。
class PlayerSyncState {
  final String hash;
  final String originalHash;
  final String mixSongId;
  final bool isPlaying;
  final int progressMs;
  final int durationMs;
  final String listVersion;

  /// 快照基准时间（已校验 ±60s，可疑值回退为解析时刻）。
  final int updatedAtMs;

  const PlayerSyncState({
    required this.hash,
    required this.originalHash,
    required this.mixSongId,
    required this.isPlaying,
    required this.progressMs,
    required this.durationMs,
    required this.listVersion,
    required this.updatedAtMs,
  });

  factory PlayerSyncState.fromJson(Map<String, dynamic> json, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // sync_player 的播放态位于 data 层，当前歌曲身份位于 data.progress_info
    // （形如 {"progress_info":{"cur_song":"...","progress":11,"album_audio_id":"..."}}）
    final data = asRecord(json['data']) ?? json;
    final progressInfo = asRecord(parseJsonValue(data['progress_info'])) ?? const {};
    // 歌曲身份可能嵌套在 audio/current_audio/song 对象中，先合并再读取
    final merged = <String, dynamic>{
      ...?asRecord(data['audio']),
      ...?asRecord(data['current_audio']),
      ...?asRecord(data['song']),
      ...progressInfo,
      ...data,
    };
    final hash = readString(merged, const ['hash', 'file_hash', 'audio_hash', 'cur_song']);
    final original = readString(merged, const ['genting_hash', 'original_hash']);

    // 播放态：pause 为字符串或数字，1 = 正在播放，2 = 已暂停
    // （与上报口径一致：playing ? 1 : 2，读写必须同源否则会互相回正）
    final stateStr =
        readString(merged, const ['play_status', 'playstate', 'state', 'status']).toLowerCase();
    final pausedByState = stateStr == 'pause' || stateStr == 'paused' || stateStr == '0';
    bool playing;
    final pauseRaw = data['pause'] ?? merged['pause'];
    if (pauseRaw is num) {
      playing = pauseRaw.toInt() == 1;
    } else if (pauseRaw is String && pauseRaw.trim().isNotEmpty) {
      playing = pauseRaw.trim() == '1';
    } else if (stateStr.isNotEmpty) {
      playing = !pausedByState;
    } else {
      playing = readBool(merged, true, const ['is_playing', 'isplay', 'playing']);
    }

    // 快照时间：秒→毫秒；与本机相差 >60s 视为误识别（如歌曲发布时间），回退为 now
    final rawTs = readInt(
      data,
      const ['timestamp', 'server_timestamp', 'server_time', 'update_time'],
    );
    final normTs = rawTs > 0 && rawTs < 10000000000 ? rawTs * 1000 : rawTs;
    final updatedAt = normTs > 0 && (now - normTs).abs() <= 60000 ? normTs : now;

    final progress = readInt(merged, const [
      'progress',
      'play_progress',
      'current_time',
      'current_position',
      'position',
      'play_pos',
      'play_time',
      'pos',
      'offset',
    ]);

    return PlayerSyncState(
      hash: hash.isNotEmpty ? hash : original,
      originalHash: original,
      mixSongId:
          readString(merged, const ['mixsongid', 'mix_song_id', 'album_audio_id', 'audio_id']),
      isPlaying: playing,
      progressMs: progress > 0 ? toMs(progress) : 0,
      durationMs: toMs(readInt(merged, const ['duration_ms', 'total_time_ms', 'duration'])),
      listVersion: readNestedString(json, 'list_version'),
      updatedAtMs: updatedAt,
    );
  }
}

/// 远端位置投影：播放中按 updatedAt 推进，暂停则保持（用于纠偏比较）。
int projectRemotePosition(PlayerSyncState remote, int nowMs) {
  if (!remote.isPlaying) return remote.progressMs;
  final elapsed = ((nowMs - remote.updatedAtMs) / 1000).floor();
  return remote.progressMs + (elapsed > 0 ? elapsed * 1000 : 0);
}

/// 跟随起播时应当落到远端哪个位置；返回 null 表示「从头播，不用 seek」。
///
/// 该值必须随播放源一起交给播放器，在 source ready 之后再 seek。
/// 早期实现在 `playSong` 返回后由调用方自行 seek，但那时 `ProcessingState`
/// 往往还没到 ready（在线源要等首帧缓冲），seek 会被丢弃或落到旧源上，
/// 表现为「进房从 0 开始播，手动暂停再播放才跟上房主进度」。
///
/// [thresholdMs] 为最小对齐阈值：远端进度不超过它时按「从头播」处理。
Duration? roomStartSeekTarget(
  PlayerSyncState remote, {
  required int nowMs,
  int thresholdMs = 1000,
}) {
  final projected = projectRemotePosition(remote, nowMs);
  if (projected <= thresholdMs) return null;
  return Duration(milliseconds: projected);
}

/// 把待富化的曲目重排为「当前播放的歌排最前，其余保持原相对顺序」。
///
/// 富化是严格串行的（每首两次网络往返：`/audio` 详情 + `/search` 搜索），
/// 网络慢时单轮可耗时数秒。若当前歌排在歌单第 N 位，它的封面就要等前 N-1 首
/// 全部跑完才回写——实测「进房后约 3 秒才出封面」即源于此。
///
/// 而这个空窗是**不可恢复**的：原生侧收到 `artUrl=null` 时只记一条
/// 「无有效封面源」且不会自行重试，用户看到的便是「封面丢失」。
/// 因此当前歌必须最优先处理。
///
/// [currentId] 为播放器当前曲目 id（大小写不敏感）；为空时原样返回。
List<RoomSong> prioritizeCurrentForEnrichment(
  List<RoomSong> songs, {
  required String? currentId,
}) {
  final id = currentId?.toLowerCase();
  if (id == null || id.isEmpty) return songs;
  bool isCurrent(RoomSong s) =>
      s.hash.toLowerCase() == id ||
      (s.originalHash.isNotEmpty && s.originalHash.toLowerCase() == id);
  final current = songs.where(isCurrent).toList();
  if (current.isEmpty) return songs;
  return [...current, ...songs.where((s) => !isCurrent(s))];
}

/// 聊天/系统消息。
class ChatMessage {
  final String id;
  final String userId;
  final String text;
  final String nickname;
  final String avatar;

  /// 801 = 普通文本消息，其余为系统消息（房主操作、进出房等）。
  final int type;
  final int timestampMs;
  final bool isSystem;

  /// 上游附带的房间标签（形如 `rm_1009:<房间号>`）。
  ///
  /// 用于跨房间隔离：切换房间后若仍收到其它房间的历史消息，可据此剔除。
  final String roomTag;

  const ChatMessage({
    required this.id,
    required this.userId,
    required this.text,
    required this.nickname,
    required this.avatar,
    required this.type,
    required this.timestampMs,
    required this.isSystem,
    this.roomTag = '',
  });

  /// 该消息所属房间号（标签缺失时为空串，表示无法判定）。
  String get tagRoomId {
    final tag = roomTag.trim();
    if (tag.isEmpty) return '';
    final idx = tag.lastIndexOf(':');
    return idx >= 0 ? tag.substring(idx + 1).trim() : tag;
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rec = asRecord(parseJsonValue(json)) ?? json;
    final msg = asRecord(parseJsonValue(rec['message'] ?? rec['msg'] ?? rec['content'])) ?? rec;
    final type = readInt(msg, const ['msgtype', 'msg_type', 'type']);
    final rawTs = readInt(rec, const ['addtime', 'timestamp', 'time']);
    final ts = rawTs > 0 && rawTs < 10000000000 ? rawTs * 1000 : rawTs;
    final msgUserId = readString(msg, const ['userid', 'uid']);
    final userId =
        msgUserId.isNotEmpty ? msgUserId : readString(rec, const ['uid', 'userid']);
    final nickname0 =
        readString(msg, const ['nickname', 'nick_name', 'username', 'user_name', 'name']);
    final nickname = nickname0.isNotEmpty ? nickname0 : '房间成员';
    final id0 = readString(rec, const ['msgid', 'id']);
    return ChatMessage(
      id: id0.isNotEmpty ? id0 : '$userId:$ts',
      userId: userId,
      text: type == 801
          ? readString(msg, const ['alert', 'message', 'content', 'text', 'msg'])
          : systemMessageText(msg, type),
      nickname: nickname,
      avatar: readString(msg, const ['img', 'avatar', 'avatar_url', 'user_pic', 'pic']),
      type: type,
      timestampMs: ts,
      isSystem: type != 801,
      roomTag: readString(rec, const ['tag', 'room_tag']),
    );
  }
}

/// 系统消息文案码表。
///
/// 上游对部分事件已给出可展示文案（alert 字段），此时优先保留原文；
/// 否则按众乐房/自习室的 msgtype 映射为中文文案，未知类型归一为通用文案。
String systemMessageText(Map msg, int type) {
  final nickname0 =
      readString(msg, const ['nickname', 'nick_name', 'username', 'user_name', 'name']);
  final nickname = nickname0.isNotEmpty ? nickname0 : '房间成员';
  final songName = readString(msg, const ['songname', 'song_name']);
  final flag = readString(msg, const ['flag_name']);
  final target = readString(msg, const ['flag_nickname']);
  final alert = readString(msg, const ['alert', 'content', 'text', 'title', 'prompt']);
  final action = readInt(msg, const ['action', 'event']);
  // 上游已给可展示文案时优先保留原文
  if (alert.isNotEmpty) return alert;
  switch (type) {
    case 2001:
      return '$nickname 开始了学习';
    case 2002:
      return '$nickname 结束了学习';
    case 2003:
      return target.isNotEmpty
          ? '$nickname 向 $target 的 Flag「${flag.isNotEmpty ? flag : "专注学习"}」递了奶茶'
          : '$nickname 为「${flag.isNotEmpty ? flag : "专注学习"}」递了奶茶';
    case 2004:
      return '$nickname 进入了房间';
    case 2005:
      return '$nickname 离开了房间';
    case 2006:
      return '$nickname 暂停了学习';
    case 2007:
      return '$nickname 恢复了学习';
    case 2008:
      return '房间信息已更新';
    case 2009:
      return '房间歌单已更新';
    case 2010:
      return '$nickname 立下了 Flag「${flag.isNotEmpty ? flag : "专注学习"}」';
    case 810:
      return action == 2 ? '$nickname 离开了房间' : '$nickname 进入了房间';
    case 820:
      return '房主已结束一起听';
    case 821:
      // 房主聊天开关广播：消息体 switch.chat（1=开启 2=关闭，switch 为嵌套
      // 对象，兼容平铺 key 'switch.chat'）；均缺失时维持通用文案
      // （上游自带 alert 文案时已在上方优先返回）
      final switchRec = asRecord(parseJsonValue(msg['switch']));
      final chatRaw = switchRec != null && switchRec.containsKey('chat')
          ? switchRec['chat']
          : msg['switch.chat'];
      final chat = chatRaw is num
          ? chatRaw.toInt()
          : int.tryParse('${chatRaw ?? ''}'.trim());
      if (chat == 1) return '房主已开启聊天';
      if (chat == 2) return '房主已关闭聊天';
      return '房间信息已更新';
    case 830:
      return '$nickname 更新了房间成员设置';
    case 3001:
      return '房主开始了一起听';
    case 3002:
      return '房主结束了一起听';
    case 3003:
      return '房间歌单已更新';
    case 3004:
      return songName.isNotEmpty ? '已切换至《$songName》' : '房主切换了歌曲';
    case 3005:
      return '房间播放状态已更新';
    case 4001:
      return '$nickname已加入一起听';
    case 4002:
      return '$nickname 离开了房间';
    case 4003:
      return '$nickname 为房间打了 call';
    case 4004:
      return songName.isNotEmpty ? '$nickname 收藏了《$songName》' : '$nickname 收藏了歌曲';
    case 4005:
      return '$nickname 关注了房主';
    case 5100:
      return songName.isNotEmpty ? '$nickname 点播了《$songName》' : '$nickname 发起了点歌请求';
    default:
      return flag.isNotEmpty ? '$nickname：$flag' : '$nickname 更新了房间状态';
  }
}

/// 点歌列表条目。
class OrderSongEntry {
  final RoomSong song;
  final String orderUserId;
  final String orderNickname;

  const OrderSongEntry({
    required this.song,
    required this.orderUserId,
    required this.orderNickname,
  });

  factory OrderSongEntry.fromJson(Map<String, dynamic> json) {
    final songRec = asRecord(json['song_info']) ?? json;
    final userRec = asRecord(json['user_info']) ?? const <String, dynamic>{};
    final nickname =
        readString(userRec, const ['nick_name', 'nickname', 'name']);
    return OrderSongEntry(
      song: RoomSong.fromJson(songRec),
      orderUserId: readString(userRec, const ['userid', 'user_id', 'uid']),
      orderNickname: nickname.isNotEmpty ? nickname : '房间成员',
    );
  }

  /// 富化后就地替换歌曲（封面/歌名补齐；请求人身份字段不变）。
  OrderSongEntry copyWithSong(RoomSong enriched) => OrderSongEntry(
        song: enriched,
        orderUserId: orderUserId,
        orderNickname: orderNickname,
      );
}
