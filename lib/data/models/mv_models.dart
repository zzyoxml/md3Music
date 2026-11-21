/// MV 查询结果：通过 `/kmr/audio/mv` 接口根据 album_audio_id 查询得到。
class MvInfo {
  /// MV 的 video id，用于后续 `/video/detail` 查询。
  final String? mvId;

  /// 对应的歌曲 album_audio_id。
  final String? albumAudioId;

  /// MV 的视频 hash（部分响应直接返回 hash，可直接用于 /video/url）。
  final String? hash;

  bool get hasMv => (mvId != null && mvId!.isNotEmpty) ||
      (hash != null && hash!.isNotEmpty);

  const MvInfo({this.mvId, this.albumAudioId, this.hash});

  factory MvInfo.fromJson(Map<String, dynamic> json) {
    // 响应可能是 {album_audio_id, mv_id, ...} 或嵌套在 data 数组里
    // mvId 字段名容错：mv_id / mvid / id / videoid
    String? mvId;
    for (final key in ['mv_id', 'mvid', 'mvId', 'videoid', 'video_id', 'id']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        mvId = v;
        break;
      } else if (v is num) {
        mvId = v.toString();
        break;
      }
    }
    // hash 字段名容错：hash / mvhash / mv_hash / videohash
    String? hash;
    for (final key in ['hash', 'mvhash', 'mv_hash', 'videohash', 'video_hash']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        hash = v;
        break;
      }
    }
    String? albumAudioId;
    for (final key in ['album_audio_id', 'albumAudioId', 'mixsongid', 'MixSongID']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        albumAudioId = v;
        break;
      } else if (v is num) {
        albumAudioId = v.toString();
        break;
      }
    }
    return MvInfo(mvId: mvId, albumAudioId: albumAudioId, hash: hash);
  }
}

/// 单个清晰度信息：来自 `/video/detail`（show_resolution=1）返回的分辨率列表。
class MvQuality {
  /// 视频 hash，用于 `/video/url` 获取播放地址。
  final String hash;

  /// 清晰度标签，如 "标清" / "高清" / "超清" / "1080P"。
  final String quality;

  /// 视频宽度（像素），可为空。
  final int? width;

  /// 视频高度（像素），可为空。
  final int? height;

  /// 文件大小（字节），可为空。
  final int? size;

  const MvQuality({
    required this.hash,
    required this.quality,
    this.width,
    this.height,
    this.size,
  });

  /// 人类可读的分辨率描述，如 "1920x1080"。
  String get resolutionLabel {
    if (width != null && height != null) return '${width}x$height';
    return quality;
  }

  factory MvQuality.fromJson(Map<String, dynamic> json) {
    String? hash;
    for (final key in ['hash', 'videohash', 'filehash']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        hash = v;
        break;
      }
    }
    String? quality;
    for (final key in ['quality', 'definition', 'level', 'name', 'remark']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        quality = v;
        break;
      } else if (v is num) {
        quality = v.toString();
        break;
      }
    }
    return MvQuality(
      hash: hash ?? '',
      quality: quality ?? '未知',
      width: json['width'] is num ? (json['width'] as num).toInt() : null,
      height: json['height'] is num ? (json['height'] as num).toInt() : null,
      size: json['filesize'] is num
          ? (json['filesize'] as num).toInt()
          : (json['size'] is num ? (json['size'] as num).toInt() : null),
    );
  }
}

/// MV 详情：通过 `/video/detail` 接口获取。
class MvDetail {
  final String mvId;

  /// MV 标题。
  final String? title;

  /// 参演歌手/作者。
  final String? artists;

  /// MV 时长。
  final Duration? duration;

  /// 播放次数。
  final int? playCount;

  /// 封面图 URL。
  final String? coverUrl;

  /// MV 简介。
  final String? desc;

  /// 可用清晰度列表（按清晰度从低到高或按服务端返回顺序）。
  final List<MvQuality> qualities;

  const MvDetail({
    required this.mvId,
    this.title,
    this.artists,
    this.duration,
    this.playCount,
    this.coverUrl,
    this.desc,
    this.qualities = const [],
  });

  factory MvDetail.fromJson(Map<String, dynamic> json, String mvId) {
    int? pi(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

    String? title;
    for (final key in ['video_name', 'videoname', 'title', 'name', 'mv_name']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        title = v;
        break;
      }
    }
    String? artists;
    for (final key in ['author_name', 'singer', 'singername', 'singers', 'artist']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        artists = v;
        break;
      }
    }
    if (artists == null) {
      final v = json['authors'];
      if (v is List && v.isNotEmpty) {
        artists = v
            .map((e) => e is Map ? (e['author_name'] ?? e['name'] ?? '').toString() : '')
            .where((s) => s.isNotEmpty)
            .join(' / ');
      }
    }
    // timelength 为字符串毫秒（如 "329920"）
    Duration? duration;
    final dur = json['timelength'] ?? json['duration'] ?? json['length'];
    final durMs = pi(dur);
    if (durMs != null) {
      duration = Duration(milliseconds: durMs > 1000 ? durMs : durMs * 1000);
    }
    // history_heat 为字符串
    int? playCount;
    final pc = json['history_heat'] ?? json['play_times'] ?? json['playcount'] ?? json['play_count'] ?? json['plays'];
    playCount = pi(pc);
    String? coverUrl;
    for (final key in ['hdpic', 'thumb', 'cover', 'coverurl', 'cover_url', 'img', 'pic']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        coverUrl = v.replaceAll('{size}', '480');
        break;
      }
    }
    String? desc;
    for (final key in ['intro', 'desc', 'description', 'content']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        desc = v;
        break;
      }
    }
    // 清晰度：扁平字段 ld_hash/sd_hash/hd_hash/qhd_hash/fhd_hash（h264 版本）
    // 按清晰度从低到高，仅当 xxx_hash 非空时加入。
    List<MvQuality> qualities = [];
    const defs = <List<String>>[
      ['ld', '流畅'],
      ['sd', '标清'],
      ['hd', '高清'],
      ['qhd', '超清'],
      ['fhd', '蓝光'],
    ];
    for (final def in defs) {
      final prefix = def[0];
      final label = def[1];
      final h = json['${prefix}_hash'];
      if (h is String && h.isNotEmpty) {
        qualities.add(MvQuality(
          hash: h,
          quality: label,
          width: pi(json['${prefix}_width']),
          height: pi(json['${prefix}_height']),
          size: pi(json['${prefix}_filesize']),
        ));
      }
    }
    return MvDetail(
      mvId: mvId,
      title: title,
      artists: artists,
      duration: duration,
      playCount: playCount,
      coverUrl: coverUrl,
      desc: desc,
      qualities: qualities,
    );
  }

  /// 播放次数的友好显示：>=10000 显示为 "x.x万"。
  String get playCountLabel {
    if (playCount == null) return '';
    if (playCount! >= 100000000) {
      return '${(playCount! / 100000000).toStringAsFixed(1)}亿';
    } else if (playCount! >= 10000) {
      return '${(playCount! / 10000).toStringAsFixed(1)}万';
    }
      return playCount.toString();
  }
}

/// MV 的单个片源：来自 `/kmr/audio/mv` 响应里 `h264`/`h265`/`mkv` 编码映射。
///
/// 每个编码映射按清晰度（fhd/hd/qhd/sd/ld）提供 `${quality}_hash` 与
/// `${quality}_filesize`，本模型据此汇总成一个可请求 `/video/url` 的片源。
class MvSource {
  /// 视频 hash，用于 `/video/url` 获取播放地址。
  final String hash;

  /// 清晰度标签，如 "1080P" / "720P"。
  final String label;

  /// 编码族标签："H.264" / "H.265" / "MKV"。
  final String codec;

  /// 文件大小（字节），供「取较小片源」排序；可为空。
  final int? size;

  const MvSource({
    required this.hash,
    required this.label,
    required this.codec,
    this.size,
  });
}

/// 曲库 MV 候选：含 MV 音频兜底筛选所需的标记字段。
///
/// 字段口径对齐 EchoMusic `pickCatalogMv`：只有「官方发布、非 UGC、非平台短视频、
/// 非其他版本、有片源、时长 > 0」的记录才可用于兜底。
class MvCandidate {
  /// MV 的 video_id。
  final String videoId;

  /// 顶层 hash（部分响应直接返回，可作为片源 hash 的补充）。
  final String? hash;

  /// MV 时长（秒）；0 视为不可用。
  final int durationSeconds;

  /// 上游是否推荐该版本（`is_recommend == 1`）。
  final bool recommend;

  /// 上游 `is_publish`；未发布（!=1）不可用。
  final int? isPublish;

  /// 上游 `is_ugc`；UGC 版本（==1）不可用，字段缺失（null）也视为不可用。
  final int? isUgc;

  /// 上游 `is_short`；平台短视频（!=0）不可用，字段缺失（null）也视为不可用。
  final int? isShort;

  /// 上游 `is_other`；其他版本（==1）不可用，字段缺失（null）也视为不可用。
  final int? isOther;

  /// 记录内 `__status`；为 null 表示未返回（放行），==1 放行。
  final int? status;

  /// 该 MV 的全部片源。
  final List<MvSource> sources;

  const MvCandidate({
    required this.videoId,
    this.hash,
    this.durationSeconds = 0,
    this.recommend = false,
    this.isPublish,
    this.isUgc,
    this.isShort,
    this.isOther,
    this.status,
    this.sources = const [],
  });

  bool get hasSources => sources.isNotEmpty;
}

