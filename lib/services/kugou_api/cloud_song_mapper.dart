import '../../data/models/song.dart';

/// 将酷狗云盘 /v1/get_list 返回的单项 JSON 映射为 [Song]。
///
/// 字段解析规则：
/// - `hash` 为歌曲唯一 ID（即云盘歌曲 id）；
/// - 优先取 `songname` / `singername` / `singer` / `artist` 独立字段；
/// - 缺失时回退到 `filename`（常见为 "歌手 - 歌名.ext"），剥离扩展名后按
///   `" - "` 拆分歌手与歌名；
/// - 时长字段 `duration` 单位通常为秒（少数返回毫秒），落入 (0, 1000) 区间
///   视为秒，自动 ×1000 转为毫秒；
/// - 任何字段缺失都不抛异常，未识别歌曲退化为 "未知歌曲" / "未知歌手"。
Song mapCloudApiItemToSong(Map<String, dynamic> item) {
  final hash = (item['hash'] ?? '').toString();

  // 优先使用独立字段（若存在）
  String songname = (item['songname'] ?? '').toString();
  String singer =
      (item['singername'] ?? item['singer'] ?? item['artist'] ?? '').toString();

  // songname 为空时，从 filename 解析 "歌手 - 歌名.ext"
  if (songname.isEmpty) {
    final filename =
        (item['filename'] ?? item['FileName'] ?? item['name'] ?? '').toString();
    // 剥离音频扩展名
    final withoutExt = filename.replaceFirst(
      RegExp(r'\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$',
          caseSensitive: false),
      '',
    );
    // 按 " - " 拆分歌手与歌名
    final dashIdx = withoutExt.indexOf(' - ');
    if (dashIdx > 0) {
      if (singer.isEmpty) {
        singer = withoutExt.substring(0, dashIdx).trim();
      }
      songname = withoutExt.substring(dashIdx + 3).trim();
    } else {
      songname = withoutExt;
    }
  }
  if (songname.isEmpty) songname = '未知歌曲';
  if (singer.isEmpty) singer = '未知歌手';

  final albumId = item['album_id']?.toString();
  final albumAudioId = item['album_audio_id']?.toString();
  // 云盘文件 ID（删除云盘歌曲时优先使用 kv_id + album_audio_id）
  final fileId = int.tryParse((item['kv_id'] ?? '').toString());

  // 时长：云盘 duration 单位通常为秒，需 ×1000 转毫秒
  // 兼容 timelength/time_length/timelen 等可能的字段名
  final dur = item['duration'] ??
      item['timelength'] ??
      item['time_length'] ??
      item['timelen'];
  int durationMs = 0;
  if (dur is num) {
    durationMs = dur.toInt();
    // 值介于 (0, 1000) 认为是秒，转毫秒
    if (durationMs > 0 && durationMs < 1000) {
      durationMs = durationMs * 1000;
    }
  }

  return Song(
    id: hash,
    title: songname,
    artist: singer,
    album: '',
    duration: Duration(milliseconds: durationMs),
    isOnline: true,
    isCloud: true,
    albumId: albumId,
    albumAudioId: albumAudioId,
    fileId: fileId,
  );
}
