import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/artist/artist_song_list_builder.dart';

Song mk(String id, {String? title, String artist = 'A', String album = '',
    Duration? duration}) => Song(
  id: id,
  title: title ?? '歌$id',
  artist: artist,
  album: album,
  duration: duration ?? const Duration(seconds: 200),
);

/// 现状实现（照抄 artist_detail_page.dart:153-158 的 time 分支），用于等价性对照。
List<Song> legacyByOriginal(List<Song> songs, {required bool ascending}) {
  final list = List.of(songs);
  list.sort((a, b) {
    final cmp = songs.indexOf(a).compareTo(songs.indexOf(b));
    return ascending ? -cmp : cmp;
  });
  return list;
}

void main() {
  group('original（热度/最新＝接口顺序）', () {
    test('ascending=false 与旧实现一致：等于接口顺序', () {
      final songs = [mk('1'), mk('2'), mk('3')];
      expect(
        buildArtistDisplaySongs(
            source: songs, field: ArtistSongSortField.original, ascending: false),
        // 计划原文写的是 sameElementsAs，但本仓 matcher 0.12.x 无该顶层函数；
        // Song 未重写 ==（身份比较），orderedEquals 即「同序同元素（按引用）」，语义等价。
        orderedEquals(legacyByOriginal(songs, ascending: false)),
      );
    });

    test('ascending=true 与旧实现一致：等于接口顺序反转', () {
      final songs = List.generate(100, (i) => mk('$i'));
      expect(
        buildArtistDisplaySongs(
            source: songs, field: ArtistSongSortField.original, ascending: true),
        orderedEquals(legacyByOriginal(songs, ascending: true)),
      );
    });

    test('过滤后 original 仍保持接口顺序', () {
      final songs = [mk('1', title: 'aaa'), mk('2', title: 'zzz'), mk('3', title: 'aab')];
      expect(
        buildArtistDisplaySongs(
            source: songs, field: ArtistSongSortField.original,
            ascending: false, query: 'aa').map((s) => s.id),
        ['1', '3'],
      );
    });
  });

  test('title 排序剥离扩展名且忽略大小写', () {
    final songs = [mk('1', title: 'Banana.flac'), mk('2', title: 'apple'), mk('3', title: 'cherry')];
    expect(
      buildArtistDisplaySongs(source: songs, field: ArtistSongSortField.title, ascending: true)
          .map((s) => s.id),
      ['2', '1', '3'],
    );
    expect(
      buildArtistDisplaySongs(source: songs, field: ArtistSongSortField.title, ascending: false)
          .map((s) => s.id),
      ['3', '1', '2'],
    );
  });

  test('duration 排序按总时长数值比较', () {
    final songs = [
      mk('1', duration: const Duration(seconds: 300)),
      mk('2', duration: const Duration(seconds: 120)),
      mk('3', duration: const Duration(seconds: 240)),
    ];
    expect(
      buildArtistDisplaySongs(source: songs, field: ArtistSongSortField.duration, ascending: true)
          .map((s) => s.id),
      ['2', '3', '1'],
    );
  });

  test('过滤命中 title / artist / album 任一即可', () {
    final songs = [
      mk('1', title: '甲', artist: 'Zhou', album: 'X'),
      mk('2', title: '乙', artist: 'Wang', album: 'Y'),
      mk('3', title: '丙', artist: 'Li', album: 'Zhou'),
    ];
    expect(
      buildArtistDisplaySongs(source: songs, field: ArtistSongSortField.original,
          ascending: false, query: 'zhou').map((s) => s.id),
      ['1', '3'],
    );
  });

  test('性能护栏：6000 首 original 路径远低于一帧预算', () {
    final songs = List.generate(6000, (i) => mk('$i'));
    final sw = Stopwatch()..start();
    final out = buildArtistDisplaySongs(
        source: songs, field: ArtistSongSortField.original, ascending: false);
    sw.stop();
    expect(out, hasLength(6000));
    // 旧实现在 6000 首实测 203ms；这里要求 < 30ms（本机应约 0.3ms）
    expect(sw.elapsedMilliseconds, lessThan(30),
        reason: 'original 路径不应是平方级开销');
  });

  test('性能护栏：title 路径随规模近似线性增长', () {
    int cost(int n) {
      final songs = List.generate(n, (i) => mk('$i', title: 't$i.mp3'));
      final sw = Stopwatch()..start();
      buildArtistDisplaySongs(source: songs, field: ArtistSongSortField.title, ascending: true);
      return sw.elapsedMilliseconds;
    }
    final small = cost(1000);
    final big = cost(6000);
    // 旧实现每比较都新建 RegExp：6000/1000 的耗时比会远大于数据规模比 6。
    // 预计算键后应 < 12（O(n log n) 的对数因子余量）。
    expect((big + 1) / (small + 1), lessThan(12),
        reason: 'big=$big ms small=$small ms');
  });

  test('逐字输入 6 次不触发平方级重排（大歌库）', () {
    final songs = List.generate(4000, (i) => mk('$i', title: '歌曲$i', artist: '艺人名$i'));
    final sw = Stopwatch()..start();
    for (final q in ['歌', '歌曲', '歌曲1', '歌曲12', '歌曲123', '歌曲1234']) {
      buildArtistDisplaySongs(
          source: songs, field: ArtistSongSortField.original, ascending: false, query: q);
    }
    sw.stop();
    // 6 次「过滤 + 原序」的合计耗时。旧实现这里会再叠 6 次平方级排序。
    expect(sw.elapsedMilliseconds, lessThan(120),
        reason: '连续输入应只是线性过滤');
  });
}
