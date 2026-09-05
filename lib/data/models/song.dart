class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String? url;
  final String? localPath;
  final String? artworkUri;
  final bool isOnline;
  final String? albumId;
  final String? artistId;
  final String? quality;
  final String? albumAudioId;
  final int? fileId;
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

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.url,
    this.localPath,
    this.artworkUri,
    this.isOnline = false,
    this.albumId,
    this.artistId,
    this.quality,
    this.albumAudioId,
    this.fileId,
    this.isCloud = false,
    this.climaxStart,
    this.climaxEnd,
    this.bpm,
    this.isLocallyFavorited = false,
    this.isLongAudio = false,
    this.loudnessLufs,
    this.loudnessPeakDb,
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
      artworkUri: json['artworkUri'] as String?,
      isOnline: (json['isOnline'] as bool?) ?? false,
      albumId: json['albumId'] as String?,
      artistId: json['artistId'] as String?,
      quality: json['quality'] as String?,
      albumAudioId: json['albumAudioId'] as String?,
      fileId: json['fileId'] as int?,
      isCloud: (json['isCloud'] as bool?) ?? false,
      climaxStart: (json['climaxStart'] as num?)?.toDouble(),
      climaxEnd: (json['climaxEnd'] as num?)?.toDouble(),
      bpm: (json['bpm'] as num?)?.toInt(),
      isLocallyFavorited: (json['isLocallyFavorited'] as bool?) ?? false,
      isLongAudio: (json['isLongAudio'] as bool?) ?? false,
      loudnessLufs: (json['loudnessLufs'] as num?)?.toDouble(),
      loudnessPeakDb: (json['loudnessPeakDb'] as num?)?.toDouble(),
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
      'artworkUri': artworkUri,
      'isOnline': isOnline,
      'albumId': albumId,
      'artistId': artistId,
      'quality': quality,
      'albumAudioId': albumAudioId,
      'fileId': fileId,
      'isCloud': isCloud,
      'climaxStart': climaxStart,
      'climaxEnd': climaxEnd,
      'bpm': bpm,
      'isLocallyFavorited': isLocallyFavorited,
      'isLongAudio': isLongAudio,
      'loudnessLufs': loudnessLufs,
      'loudnessPeakDb': loudnessPeakDb,
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
    String? artworkUri,
    bool? isOnline,
    String? albumId,
    String? artistId,
    String? quality,
    String? albumAudioId,
    int? fileId,
    bool? isCloud,
    double? climaxStart,
    double? climaxEnd,
    int? bpm,
    bool? isLocallyFavorited,
    bool? isLongAudio,
    double? loudnessLufs,
    double? loudnessPeakDb,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      url: url ?? this.url,
      localPath: localPath ?? this.localPath,
      artworkUri: artworkUri ?? this.artworkUri,
      isOnline: isOnline ?? this.isOnline,
      albumId: albumId ?? this.albumId,
      artistId: artistId ?? this.artistId,
      quality: quality ?? this.quality,
      albumAudioId: albumAudioId ?? this.albumAudioId,
      fileId: fileId ?? this.fileId,
      isCloud: isCloud ?? this.isCloud,
      climaxStart: climaxStart ?? this.climaxStart,
      climaxEnd: climaxEnd ?? this.climaxEnd,
      bpm: bpm ?? this.bpm,
      isLocallyFavorited: isLocallyFavorited ?? this.isLocallyFavorited,
      isLongAudio: isLongAudio ?? this.isLongAudio,
      loudnessLufs: loudnessLufs ?? this.loudnessLufs,
      loudnessPeakDb: loudnessPeakDb ?? this.loudnessPeakDb,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
