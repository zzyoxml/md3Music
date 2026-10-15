import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/room_song_patch.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

/// 一起听「晚期富化」回写策略回归。
///
/// 跟随端起播瞬间只有 hash 身份（PlaceholderSong），真实元数据由富化补齐。
/// 本组用例锁定两个已修复的缺陷：
///   1. 历史记录里一起听歌曲没有时长（duration 未被搬运）
///   2. 封面间歇性加载失败（与回写条件无关，但回写是最后一道关卡）
Song placeholderSong({
  String id = '9c719c80',
  String title = '未知歌曲',
  String artist = '未知歌手',
  String? artworkUri,
  Duration duration = Duration.zero,
  String? artistId,
  String? albumId,
}) =>
    Song(
      id: id,
      title: title,
      artist: artist,
      album: '',
      duration: duration,
      isOnline: true,
      artworkUri: artworkUri,
      artistId: artistId,
      albumId: albumId,
    );

RoomSong enriched({
  String hash = '9c719c80',
  String name = '室内系的TrackMaker',
  String singer = 'hanser',
  int durationSeconds = 219,
  String coverUrl = 'http://imge.kugou.com/stdmusic/400/20230226/x.jpg',
  String artistId = '183107',
  String albumId = '8519436',
}) =>
    RoomSong(
      hash: hash,
      originalHash: '',
      mixSongId: '1',
      name: name,
      singer: singer,
      durationSeconds: durationSeconds,
      coverUrl: coverUrl,
      orderUserId: '',
      artistId: artistId,
      albumId: albumId,
    );

void main() {
  group('patchSongFromRoomSong（富化回写）', () {
    test('占位歌曲：名称/歌手/封面/时长/身份全部补齐', () {
      final out = patchSongFromRoomSong(placeholderSong(), enriched())!;
      expect(out.title, '室内系的TrackMaker');
      expect(out.artist, 'hanser');
      expect(out.artworkUri, 'http://imge.kugou.com/stdmusic/400/20230226/x.jpg');
      expect(out.duration, const Duration(seconds: 219));
      expect(out.artistId, '183107');
      expect(out.albumId, '8519436');
    });

    test('关键回归：只有时长待补时也必须回写（历史无时长的根因）', () {
      // 标题/歌手/封面都已就位，唯独时长为 0 —— 富化前恰是这种状态
      final cur = placeholderSong(
        title: '室内系的TrackMaker',
        artist: 'hanser',
        artworkUri: 'http://x/a.jpg',
        duration: Duration.zero,
      );
      final out = patchSongFromRoomSong(cur, enriched());
      expect(out, isNotNull, reason: '若返回 null，回写被跳过，历史永远无时长');
      expect(out!.duration, const Duration(seconds: 219));
      expect(out.title, '室内系的TrackMaker', reason: '已就位的字段不应被改');
    });

    test('时长已存在时不覆盖（避免粗粒度上游值反向污染）', () {
      final cur = placeholderSong(duration: const Duration(seconds: 220));
      final out = patchSongFromRoomSong(cur, enriched(durationSeconds: 219))!;
      // 其他占位字段仍会被补，但时长必须保持 220
      expect(out.duration, const Duration(seconds: 220));
      expect(out.title, '室内系的TrackMaker');
    });

    test('仅时长一项不同且其余齐备时，仍会返回补丁（时长不算齐备）', () {
      final cur = placeholderSong(
        title: '室内系的TrackMaker',
        artist: 'hanser',
        artworkUri: 'http://x/a.jpg',
        duration: const Duration(seconds: 220),
        artistId: '183107',
        albumId: '8519436',
      );
      final out = patchSongFromRoomSong(cur, enriched(durationSeconds: 219));
      expect(out, isNull, reason: '时长不做覆盖，故无字段可补 → null');
    });

    test('时长已存在时保留原值，仅补其他空字段', () {
      final cur = placeholderSong(duration: const Duration(seconds: 220));
      final out = patchSongFromRoomSong(cur, enriched(durationSeconds: 219))!;
      expect(out.duration, const Duration(seconds: 220));
      expect(out.title, '室内系的TrackMaker');
    });

    test('全部字段齐备 → 返回 null（不产生无意义重推）', () {
      final cur = placeholderSong(
        title: '室内系的TrackMaker',
        artist: 'hanser',
        artworkUri: 'http://x/a.jpg',
        duration: const Duration(seconds: 219),
        artistId: '183107',
        albumId: '8519436',
      );
      expect(patchSongFromRoomSong(cur, enriched()), isNull);
    });

    test('本地侧占位「未知艺术家」也视为待补', () {
      final cur = placeholderSong(artist: kUnknownArtistPlaceholderLocal);
      final out = patchSongFromRoomSong(cur, enriched())!;
      expect(out.artist, 'hanser');
    });

    test('空歌手（未登录兜底）也视为待补', () {
      final cur = placeholderSong(artist: '');
      final out = patchSongFromRoomSong(cur, enriched())!;
      expect(out.artist, 'hanser');
    });

    test('富化结果为空时不覆盖已有值（避免把好数据刷成空）', () {
      final cur = placeholderSong(
        title: '室内系的TrackMaker',
        artist: 'hanser',
        artworkUri: 'http://x/a.jpg',
        duration: const Duration(seconds: 219),
        artistId: '183107',
        albumId: '8519436',
      );
      final out = patchSongFromRoomSong(
        cur,
        enriched(
          name: '',
          singer: '',
          durationSeconds: 0,
          coverUrl: '',
          artistId: '',
          albumId: '',
        ),
      );
      expect(out, isNull, reason: '无任何可补字段时应返回 null');
    });

    test('id 保持不变（回写不得打断播放）', () {
      final out = patchSongFromRoomSong(placeholderSong(id: '9c719c80'), enriched())!;
      expect(out.id, '9c719c80');
    });

    test('封面已有时不覆盖，但仍补其他字段', () {
      final cur = placeholderSong(artworkUri: 'http://old/cover.jpg');
      final out = patchSongFromRoomSong(cur, enriched())!;
      expect(out.artworkUri, 'http://old/cover.jpg');
      expect(out.title, '室内系的TrackMaker');
    });

    test('身份 id 已有时不覆盖（保留更准的既有值）', () {
      final cur = placeholderSong(artistId: '999', albumId: '888');
      final out = patchSongFromRoomSong(cur, enriched())!;
      expect(out.artistId, '999');
      expect(out.albumId, '888');
    });

    test('时长 0 且上游也为 0 → 不补（避免写入无意义的 0）', () {
      final cur = placeholderSong(title: '未知歌曲', duration: Duration.zero);
      final out = patchSongFromRoomSong(
        cur,
        enriched(name: '未知歌曲', durationSeconds: 0),
      );
      // 名称仍会被补上，但 duration 不应被显式写成 0
      expect(out!.duration, Duration.zero);
    });
  });
}
