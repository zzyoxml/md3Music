import '../../core/services/remote/remote_storage_config.dart';

/// 元数据缺失时使用的占位值。
///
/// **为什么需要统一常量**：项目里有两条产生占位值的路径，字面量曾经不一致——
/// - 在线侧（`KugouSongDetail.toSong` / `RoomSong.toSong`）：`未知歌手`
/// - 本地侧（`local_music_repository` / `audio_scanner`）：`未知艺术家`
///
/// 消费方若只比较其中一个，另一条路径就会漏判。实例：歌词检索词守卫曾写
/// `song.artist != '未知艺术家'`，但一起听跟随端的值是 `未知歌手` → 守卫恒真
/// → 检索词退化成「未知歌曲 未知歌手」，歌词匹配质量下降。
///
/// 因此判断「歌手是否未知」一律用 [isUnknownArtist]，不要直接比较字面量。
const String kUnknownSongTitle = '未知歌曲';
const String kUnknownArtistPlaceholder = '未知歌手';
const String kUnknownArtistPlaceholderLocal = '未知艺术家';

/// 判断歌手名是否为占位值（同时覆盖在线侧与本地侧两种写法）。
///
/// 空串也算未知：部分接口返回空字符串而非占位文本。
bool isUnknownArtist(String? artist) {
  if (artist == null) return true;
  final v = artist.trim();
  return v.isEmpty ||
      v == kUnknownArtistPlaceholder ||
      v == kUnknownArtistPlaceholderLocal;
}

/// 拆分「多位歌手连写」的 artist 字段。
///
/// 酷狗 API 的歌手字段多位歌手用「、」「;」「/」「&」「，」等分隔符连接（与
/// `Singers`/`singerinfo` 数组 join('、') 的写法同源）。判定「这首歌是不是独唱」
/// 全靠本函数，故必须与播放页跳歌手菜单用的是同一套分隔符——历史上
/// `full_player.dart` / `full_player_am.dart` 各有一份私有实现，这里收为唯一真值。
///
/// 返回空列表表示「无歌手信息」；单元素表示独唱。
List<String> splitSongArtistNames(String? artist) {
  if (artist == null || artist.isEmpty) return const [];
  return artist
      .split(RegExp(r'[、;；/,，&]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String? url;
  final String? localPath;
  /// SAF 扫描时的授权目录 URI；普通文件由 localPath 推导所属目录。
  final String? folderPath;
  final String? artworkUri;
  /// SAF 本地音频的内嵌/同目录歌词（Dart File 无法直接读取 content://）。
  final String? localLyrics;
  final bool isOnline;
  final String? albumId;
  final String? artistId;
  final String? quality;
  final String? albumAudioId;
  final int? fileId;
  /// 云端歌单顺序位；缓存后仍需保留，不能用响应数组下标代替。
  final int? playlistSort;
  /// 是否为酷狗云盘歌曲（用户上传到云盘）。
  /// 播放/投屏时 URL 解析优先走 /user/cloud/url，而非通用 /song/url。
  final bool isCloud;
  /// 高潮部分开始时间（秒），由酷狗 /song/climax 接口返回。
  final double? climaxStart;
  /// 高潮部分结束时间（秒），由酷狗 /song/climax 接口返回。
  final double? climaxEnd;
  /// 歌曲 BPM（节拍/分钟），可空。
  ///
  /// 用于歌词辉光等按快慢歌区分效果的触发判定：
  /// 酷狗公开接口暂不返回该字段，当前主要由本地音频标签（如 MP3 TBPM）
  /// 或未来接口填充；缺失时上层回落 KRC 歌词字长统计推断快慢。
  final int? bpm;
  /// 本地收藏标志位（区别于云端"我喜欢"）。
  /// true 表示用户在本机收藏过；旧 JSON 缺省时默认为 false，向后兼容。
  final bool isLocallyFavorited;
  /// 是否为酷狗听书（长音频）章节。
  /// 仅听书专辑详情页构造章节时置 true，用于播放失败时给出更明确的提示
  /// （付费边界已按列表接口 fail_process 过滤隐藏；无免费部分的付费章节
  /// 点开仍会失败，此时提示该章节为听书VIP单独付费内容）。
  final bool isLongAudio;
  /// 音量均衡（响度归一）用：歌曲集总响度（LUFS），可空。
  final double? loudnessLufs;
  /// 音量均衡（响度归一）用：歌曲真峰值（dBTP/dBFS），可空。
  final double? loudnessPeakDb;
  /// 远程存储来源类型：none=非远程，webdav/ftp 见 [SongRemoteType]。
  /// 与 [isOnline] 语义独立：远程歌曲不触发在线歌曲的富化/歌词检索/CDN 逻辑。
  final SongRemoteType remoteType;
  /// 所属远程存储配置 id（RemoteStorageConfig.id），用于播放时取鉴权头/按需下载。
  final String? remoteSourceId;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.url,
    this.localPath,
    this.folderPath,
    this.artworkUri,
    this.localLyrics,
    this.isOnline = false,
    this.albumId,
    this.artistId,
    this.quality,
    this.albumAudioId,
    this.fileId,
    this.playlistSort,
    this.isCloud = false,
    this.climaxStart,
    this.climaxEnd,
    this.bpm,
    this.isLocallyFavorited = false,
    this.isLongAudio = false,
    this.loudnessLufs,
    this.loudnessPeakDb,
    this.remoteType = SongRemoteType.none,
    this.remoteSourceId,
  });

  String get displayDuration {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// 用于 UI 显示的标题——剥离常见音频文件扩展名后缀。
  ///
  /// 酷狗 API 返回的 `songname`/`FileName` 字段有时带 `.mp3`/`.flac` 等后缀，
  /// 在 UI 显示时应当剥离。原始 [title] 字段保持不变用于搜索/收藏 key 等场景。
  /// 支持的扩展名：mp3, flac, wav, ape, m4a, ogg, aac, wma, opus（大小写不敏感）。
  String get displayName {
    final pattern = RegExp(r'\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$',
        caseSensitive: false);
    return title.replaceFirst(pattern, '');
  }

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String,
      duration: Duration(milliseconds: (json['duration'] as num).toInt()),
      url: json['url'] as String?,
      localPath: json['localPath'] as String?,
      folderPath: json['folderPath'] as String?,
      artworkUri: json['artworkUri'] as String?,
      localLyrics: json['localLyrics'] as String?,
      isOnline: (json['isOnline'] as bool?) ?? false,
      albumId: json['albumId'] as String?,
      artistId: json['artistId'] as String?,
      quality: json['quality'] as String?,
      albumAudioId: json['albumAudioId'] as String?,
      fileId: json['fileId'] as int?,
      playlistSort: (json['playlistSort'] as num?)?.toInt(),
      isCloud: (json['isCloud'] as bool?) ?? false,
      climaxStart: (json['climaxStart'] as num?)?.toDouble(),
      climaxEnd: (json['climaxEnd'] as num?)?.toDouble(),
      bpm: (json['bpm'] as num?)?.toInt(),
      isLocallyFavorited: (json['isLocallyFavorited'] as bool?) ?? false,
      isLongAudio: (json['isLongAudio'] as bool?) ?? false,
      loudnessLufs: (json['loudnessLufs'] as num?)?.toDouble(),
      loudnessPeakDb: (json['loudnessPeakDb'] as num?)?.toDouble(),
      remoteType: SongRemoteType.fromJson(json['remoteType'] as String?),
      remoteSourceId: json['remoteSourceId'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration.inMilliseconds,
      'url': url,
      'localPath': localPath,
      'folderPath': folderPath,
      'artworkUri': artworkUri,
      'localLyrics': localLyrics,
      'isOnline': isOnline,
      'albumId': albumId,
      'artistId': artistId,
      'quality': quality,
      'albumAudioId': albumAudioId,
      'fileId': fileId,
      'playlistSort': playlistSort,
      'isCloud': isCloud,
      'climaxStart': climaxStart,
      'climaxEnd': climaxEnd,
      'bpm': bpm,
      'isLocallyFavorited': isLocallyFavorited,
      'isLongAudio': isLongAudio,
      'loudnessLufs': loudnessLufs,
      'loudnessPeakDb': loudnessPeakDb,
      'remoteType': remoteType.toJson(),
      'remoteSourceId': remoteSourceId,
    };
  }

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? url,
    String? localPath,
    String? folderPath,
    String? artworkUri,
    String? localLyrics,
    bool? isOnline,
    String? albumId,
    String? artistId,
    String? quality,
    String? albumAudioId,
    int? fileId,
    int? playlistSort,
    bool? isCloud,
    double? climaxStart,
    double? climaxEnd,
    int? bpm,
    bool? isLocallyFavorited,
    bool? isLongAudio,
    double? loudnessLufs,
    double? loudnessPeakDb,
    SongRemoteType? remoteType,
    String? remoteSourceId,
    bool clearUrl = false,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      url: clearUrl ? null : url ?? this.url,
      localPath: localPath ?? this.localPath,
      folderPath: folderPath ?? this.folderPath,
      artworkUri: artworkUri ?? this.artworkUri,
      localLyrics: localLyrics ?? this.localLyrics,
      isOnline: isOnline ?? this.isOnline,
      albumId: albumId ?? this.albumId,
      artistId: artistId ?? this.artistId,
      quality: quality ?? this.quality,
      albumAudioId: albumAudioId ?? this.albumAudioId,
      fileId: fileId ?? this.fileId,
      playlistSort: playlistSort ?? this.playlistSort,
      isCloud: isCloud ?? this.isCloud,
      climaxStart: climaxStart ?? this.climaxStart,
      climaxEnd: climaxEnd ?? this.climaxEnd,
      bpm: bpm ?? this.bpm,
      isLocallyFavorited: isLocallyFavorited ?? this.isLocallyFavorited,
      isLongAudio: isLongAudio ?? this.isLongAudio,
      loudnessLufs: loudnessLufs ?? this.loudnessLufs,
      loudnessPeakDb: loudnessPeakDb ?? this.loudnessPeakDb,
      remoteType: remoteType ?? this.remoteType,
      remoteSourceId: remoteSourceId ?? this.remoteSourceId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
