import '../data/models/song.dart';
import '../services/kugou_api/listen_together_models.dart';

/// 把房间歌单条目（富化后的 [RoomSong]）的元数据并入当前播放的 [Song]。
///
/// 抽成纯函数是为了可测：这段逻辑承担一起听跟随端的「晚期富化」回写，
/// 字段多、守卫条件各不相同，历史上两次出问题都在这里：
///
///   1. 身份字段（artistId/albumId）缺失 → 详情页跳不过去
///   2. 时长缺失 → 历史记录里一起听歌曲没有时长
///
/// 各字段的覆盖策略是刻意的，不是统一的「非空即覆盖」：
///   - 名称/歌手/封面/时长：仅在当前为空（或占位值）时补，避免富化结果
///     反向覆盖已有的准确值（如播放器已探测出的真实时长）
///   - 身份 id：同上，避免搜索结果覆盖更准的 id
///
/// 返回 null 表示无可补字段（调用方应跳过回写，避免无意义的重推）。
Song? patchSongFromRoomSong(Song current, RoomSong enriched) {
  final titleEmpty = current.title.isEmpty || current.title == kUnknownSongTitle;
  final artistEmpty = isUnknownArtist(current.artist);
  final artworkEmpty = current.artworkUri == null || current.artworkUri!.isEmpty;
  final artistIdEmpty = current.artistId == null || current.artistId!.isEmpty;
  final albumIdEmpty = current.albumId == null || current.albumId!.isEmpty;
  // 时长：起播瞬间只有 hash 身份（_followRemoteSong 造的是 durationSeconds: 0），
  // 历史条目落库时时长为 0。富化拿到 /audio 的 timelength 后才能补。
  // 只在当前为 0 时覆盖，避免用上游粗粒度时长反向覆盖播放器已探测的准确值。
  final durationEmpty = current.duration == Duration.zero;

  final nextTitle = titleEmpty && enriched.name.isNotEmpty ? enriched.name : null;
  final nextArtist = artistEmpty && enriched.singer.isNotEmpty ? enriched.singer : null;
  final nextArtwork =
      artworkEmpty && enriched.coverUrl.isNotEmpty ? enriched.coverUrl : null;
  final nextArtistId =
      artistIdEmpty && enriched.artistId.isNotEmpty ? enriched.artistId : null;
  final nextAlbumId =
      albumIdEmpty && enriched.albumId.isNotEmpty ? enriched.albumId : null;
  final nextDuration = durationEmpty && enriched.durationSeconds > 0
      ? Duration(seconds: enriched.durationSeconds)
      : null;

  final nothingToPatch = nextTitle == null &&
      nextArtist == null &&
      nextArtwork == null &&
      nextArtistId == null &&
      nextAlbumId == null &&
      nextDuration == null;
  if (nothingToPatch) return null;

  return current.copyWith(
    title: nextTitle,
    artist: nextArtist,
    artworkUri: nextArtwork,
    artistId: nextArtistId,
    albumId: nextAlbumId,
    duration: nextDuration,
  );
}
