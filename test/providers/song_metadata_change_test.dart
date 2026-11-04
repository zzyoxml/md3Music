import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/song_metadata_change.dart';

/// 元数据变化判据回归。
///
/// 这个判据守卫 updateCurrentSongMetadata 的整个方法体：返回 false 就直接
/// return，连带跳过 refreshHistoryEntry。因此漏掉任何一个字段，
/// 都会让该字段「晚到」时永远无法落到历史/通知/歌词渠道。
Song song({
  String id = 'h1',
  String title = '未知歌曲',
  String artist = '未知歌手',
  String? artworkUri,
  Duration duration = Duration.zero,
}) =>
    Song(
      id: id,
      title: title,
      artist: artist,
      album: '',
      duration: duration,
      isOnline: true,
      artworkUri: artworkUri,
    );

void main() {
  group('hasMetadataChanged（晚到元数据的实质变化判据）', () {
    test('完全相同 → 无变化（保证回写幂等，不产生推送风暴）', () {
      final a = song(
        title: '晴天',
        artist: '周杰伦',
        artworkUri: 'http://x/a.jpg',
        duration: const Duration(seconds: 269),
      );
      final b = song(
        title: '晴天',
        artist: '周杰伦',
        artworkUri: 'http://x/a.jpg',
        duration: const Duration(seconds: 269),
      );
      expect(hasMetadataChanged(a, b), isFalse);
    });

    test('标题变化 → 检出', () {
      expect(hasMetadataChanged(song(title: '未知歌曲'), song(title: '晴天')), isTrue);
    });

    test('歌手变化 → 检出', () {
      expect(hasMetadataChanged(song(artist: '未知歌手'), song(artist: '周杰伦')), isTrue);
    });

    test('封面变化 → 检出', () {
      expect(
        hasMetadataChanged(song(artworkUri: null), song(artworkUri: 'http://x/a.jpg')),
        isTrue,
      );
    });

    test('关键回归：只有时长变化也必须检出', () {
      // 这是一起听历史「无时长」的根因场景：起播时时长为 0，
      // 富化补齐时长时标题/歌手/封面可能都已就位。
      final before = song(
        title: '室内系的TrackMaker',
        artist: 'hanser',
        artworkUri: 'http://x/a.jpg',
        duration: Duration.zero,
      );
      final after = song(
        title: '室内系的TrackMaker',
        artist: 'hanser',
        artworkUri: 'http://x/a.jpg',
        duration: const Duration(seconds: 219),
      );
      expect(hasMetadataChanged(before, after), isTrue,
          reason: '旧实现只比 title/artist/artworkUri，会在此处漏判 → 历史永远无时长');
    });

    test('时长从有到无也算变化（不静默丢弃）', () {
      expect(
        hasMetadataChanged(
          song(duration: const Duration(seconds: 219)),
          song(duration: Duration.zero),
        ),
        isTrue,
      );
    });

    test('时长相差 1 秒即视为变化（毫秒级比较，不做模糊容忍）', () {
      expect(
        hasMetadataChanged(
          song(duration: const Duration(seconds: 219)),
          song(duration: const Duration(milliseconds: 219999)),
        ),
        isTrue,
      );
    });

    test('多字段同时变化 → 检出', () {
      expect(
        hasMetadataChanged(
          song(title: '未知歌曲', artist: '未知歌手', duration: Duration.zero),
          song(
            title: '晴天',
            artist: '周杰伦',
            artworkUri: 'http://x/a.jpg',
            duration: const Duration(seconds: 269),
          ),
        ),
        isTrue,
      );
    });

    test('id 不同但元数据相同 → 无变化（id 由调用方单独守卫）', () {
      // updateCurrentSongMetadata 先比对 id，不等则直接 return；
      // 本判据只负责「同一首歌的元数据是否变了」。
      expect(
        hasMetadataChanged(song(id: 'a', title: '晴天'), song(id: 'b', title: '晴天')),
        isFalse,
      );
    });
  });
}
