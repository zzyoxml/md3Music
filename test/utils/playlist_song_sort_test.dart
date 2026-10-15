import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/utils/playlist_song_sort.dart';

Song s(
  String id, {
  String? title,
  String artist = '某歌手',
  int seconds = 60,
}) {
  return Song(
    id: id,
    title: title ?? '歌$id',
    artist: artist,
    album: '',
    duration: Duration(seconds: seconds),
  );
}

List<String> ids(List<Song> list) => list.map((e) => e.id).toList();

/// 固定基准序（即"添加时间"代理序）：d1 c2 b3 a4
List<Song> base() => [
      s('1', title: 'D大调', artist: '丁歌手', seconds: 40),
      s('2', title: 'c小调', artist: '丙歌手', seconds: 30),
      s('3', title: 'B夜曲', artist: '乙歌手', seconds: 20),
      s('4', title: 'a晴天', artist: '甲歌手', seconds: 10),
    ];

void main() {
  group('sortPlaylistSongs', () {
    test('time 升序 = 基准原序', () {
      final list = List.of(base());
      list.shuffle();
      sortPlaylistSongs(
        list,
        baseOrder: base(),
        sort: PlaylistSongSort.time,
        ascending: true,
      );
      expect(ids(list), ['1', '2', '3', '4']);
    });

    test('time 降序 = 基准倒序', () {
      final list = List.of(base());
      sortPlaylistSongs(
        list,
        baseOrder: base(),
        sort: PlaylistSongSort.time,
        ascending: false,
      );
      expect(ids(list), ['4', '3', '2', '1']);
    });

    test('title 升序按小写 displayName', () {
      final list = List.of(base());
      sortPlaylistSongs(
        list,
        baseOrder: base(),
        sort: PlaylistSongSort.title,
        ascending: true,
      );
      expect(ids(list), ['4', '3', '2', '1']); // a晴天 B夜曲 c小调 D大调
    });

    test('title 剥离扩展名后参与排序', () {
      final b = [
        s('x', title: 'zzz.mp3'),
        s('y', title: 'aaa'),
      ];
      final list = List.of(b);
      sortPlaylistSongs(
        list,
        baseOrder: b,
        sort: PlaylistSongSort.title,
        ascending: true,
      );
      expect(ids(list), ['y', 'x']); // displayName 'aaa' < 'zzz'
    });

    test('artist 升序，未知歌手归一空串排最前', () {
      final b = [
        s('1', artist: '乙歌手'),
        s('2', artist: '未知歌手'),
        s('3', artist: '甲歌手'),
        s('4', artist: ''),
      ];
      final list = List.of(b);
      sortPlaylistSongs(
        list,
        baseOrder: b,
        sort: PlaylistSongSort.artist,
        ascending: true,
      );
      // 未知（'2','4' 归一为空串）在前：两者 artistKey 相同走 displayName
      // 决胜（'歌2' < '歌4'）；其后按 String.compareTo 的 UTF-16 码元序，
      // 乙(U+4E59) < 甲(U+7532)，故 1 先于 3（码元序，非笔画/拼音序）。
      expect(ids(list), ['2', '4', '1', '3']);
    });

    test('artist 同名按 displayName 决胜', () {
      final b = [
        s('1', title: '贝', artist: '甲歌手'),
        s('2', title: '阿', artist: '甲歌手'),
      ];
      final list = List.of(b);
      sortPlaylistSongs(
        list,
        baseOrder: b,
        sort: PlaylistSongSort.artist,
        ascending: true,
      );
      expect(ids(list), ['1', '2']); // 同 artist 走 displayName 决胜：贝(U+8D1D) < 阿(U+963F)，码元序
    });

    test('duration 升序', () {
      final list = List.of(base());
      sortPlaylistSongs(
        list,
        baseOrder: base(),
        sort: PlaylistSongSort.duration,
        ascending: true,
      );
      expect(ids(list), ['4', '3', '2', '1']); // 10s 20s 30s 40s
    });

    test('playCount 降序，缺失按 0 沉底', () {
      final b = base();
      final list = List.of(b);
      sortPlaylistSongs(
        list,
        baseOrder: b,
        sort: PlaylistSongSort.playCount,
        ascending: false,
        playCounts: {'2': 7, '4': 3},
      );
      expect(ids(list), ['2', '4', '3', '1']); // 7 3 然后缺键两项按基准倒序（3 在前）
    });

    test('lastPlayed 升序，缺失按 0 在最前', () {
      final b = base();
      final list = List.of(b);
      sortPlaylistSongs(
        list,
        baseOrder: b,
        sort: PlaylistSongSort.lastPlayed,
        ascending: true,
        lastPlayTimes: {'3': 100, '1': 55},
      );
      // 缺键两项（2、4）按基准正序在前，其后 55 < 100
      expect(ids(list), ['2', '4', '1', '3']);
    });

    test('键值相同的项升/降序互为完全逆序（tie-break 确定性）', () {
      final b = [
        s('1', artist: '甲'),
        s('2', artist: '甲'),
        s('3', artist: '甲'),
      ];
      final asc = List.of(b);
      final desc = List.of(b);
      sortPlaylistSongs(asc,
          baseOrder: b, sort: PlaylistSongSort.title, ascending: true);
      sortPlaylistSongs(desc,
          baseOrder: b, sort: PlaylistSongSort.title, ascending: false);
      expect(ids(desc), ids(asc.reversed.toList()));
    });
  });
}
