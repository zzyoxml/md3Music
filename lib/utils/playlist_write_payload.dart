/// 歌单写接口（cloudlist）的 `data` 参数拼装。
///
/// 这几个 payload 是**上游按 `|` / `,` 手工切分的裸字符串**，不是 JSON：
/// 少一段、多一个空格、字段顺序错了都不会报错，而是静默写错数据。故统一收在这里，
/// 用纯函数覆盖测试（`test/utils/playlist_write_payload_test.dart`）。
///
/// 逐条协议出处（参考 MakcRe/KuGouMusicApi）：
/// - `buildTrackAddData`    → `module/playlist_tracks_add.js:8-21`
/// - `buildListSortData`    → `module/playlist_sort.js:10-13`
/// - `normalizeStdmusicPic` → `module/playlist_pic.js:13`（Rust 侧同口径再归一一次）
library;

import '../data/models/song.dart';
import '../services/kugou_api/kugou_models.dart';

/// 单首歌的「添加到歌单」数据段：`歌曲名称|歌曲hash|专辑id|album_audio_id`。
///
/// 上游最少只需要前两段，但少了后两段在部分曲库下会返回错误，故始终给全。
/// `albumId` 缺失 → 0；`albumAudioId` 非数字 → 0（对齐本仓既有两处实现的输出，
/// 改动这里等于改动红心收藏与「添加到歌单」的既有行为）。
String buildTrackAddData(Song song) {
  final albumAudioId = int.tryParse(song.albumAudioId ?? '') ?? 0;
  return '${song.title}|${song.id}|${song.albumId ?? 0}|$albumAudioId';
}

/// 批量构造时每批的歌曲数上限。
///
/// `/playlist/tracks/add` 的 data 走 **URL query**（不是 body），一首歌约 70~100 字符，
/// 50 首约 5KB，安全落在 servers/proxy 的 URI 长度限内；再大（尤其中文标题经百分号
/// 编码后 3 倍膨胀）有被网关 414 截断的风险。
const int kPlaylistTrackAddBatchSize = 50;

/// 把 [songs] 切成每批 [batchSize] 首的 data 段列表，供逐批调用
/// `/playlist/tracks/add`（收藏歌单后搬歌用）。
List<String> buildTrackAddBatches(
  List<Song> songs, {
  int batchSize = kPlaylistTrackAddBatchSize,
}) {
  if (songs.isEmpty) return const [];
  final size = batchSize <= 0 ? kPlaylistTrackAddBatchSize : batchSize;
  final batches = <String>[];
  for (var i = 0; i < songs.length; i += size) {
    final end = (i + size).clamp(0, songs.length);
    batches.add(
      songs.sublist(i, end).map(buildTrackAddData).join(','),
    );
  }
  return batches;
}

/// 「我的歌单」列表排序的一条记录。
class PlaylistSortEntry {
  /// 用户自己那份 listid（不是原作者的 list_create_listid）。
  final String listId;

  /// 0 = 自建歌单，1 = 收藏歌单（两类各自独立编号）。
  final int type;

  /// 组内排序号。
  final int sort;

  const PlaylistSortEntry({
    required this.listId,
    required this.type,
    required this.sort,
  });
}

/// 拼 `/playlist/sort` 的 data：`listid|type|sort,listid|type|sort`。
///
/// listid 非数字的条目会被跳过——上游对它做 `Number()`，非法值会变成 `NaN`
/// 混进 data，整条请求可能被拒。
String buildListSortData(List<PlaylistSortEntry> entries) {
  return entries
      .where((e) => e.listId.isNotEmpty && int.tryParse(e.listId) != null)
      .map((e) => '${e.listId}|${e.type}|${e.sort}')
      .join(',');
}

/// 从用户歌单 brief 列表构造排序条目（按传入顺序编号）。
///
/// [listIdOf] 由调用方决定取哪个 listid 字段：自建歌单用 `listId`，
/// 收藏歌单也用 `listId`（订阅后的版本才是可写的那份），
/// 取不到时回落到 `listCreateListid`。
List<PlaylistSortEntry> buildPlaylistSortEntries(
  List<KugouPlaylistBrief> playlists, {
  required int type,
}) {
  final entries = <PlaylistSortEntry>[];
  for (var i = 0; i < playlists.length; i++) {
    final p = playlists[i];
    final id = p.listId.isNotEmpty ? p.listId : (p.listCreateListid ?? '');
    if (id.isEmpty) continue;
    entries.add(PlaylistSortEntry(listId: id, type: type, sort: i));
  }
  return entries;
}

/// 封面路径归一：完整 URL 取末段补 `stdmusic/`，已是相对路径则原样。
///
/// 与 Rust `playlist::normalize_stdmusic_pic` 同口径，供 UI 预览与测试对拍。
String normalizeStdmusicPic(String pic) {
  if (pic.startsWith('stdmusic/')) return pic;
  final last = pic.split('/').last;
  return 'stdmusic/$last';
}
