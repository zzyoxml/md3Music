import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/album.dart';
import 'package:md3music/modules/artist/artist_album_list_builder.dart';

Album _a(String id, String name, {String artist = '歌手', int? year}) =>
    Album(id: id, name: name, artist: artist, songCount: 0, year: year);

void main() {
  group('buildArtistDisplayAlbums', () {
    final source = [
      _a('1', 'B专辑', year: 2020),
      _a('2', 'a专辑', year: 2015),
      _a('3', 'C专辑'),
      _a('4', 'D专辑', year: 2024),
    ];

    test('original 保持接口顺序；ascending=true 整体反转', () {
      expect(
        buildArtistDisplayAlbums(
          source: source,
          field: ArtistAlbumSortField.original,
          ascending: false,
        ).map((e) => e.id),
        ['1', '2', '3', '4'],
      );
      expect(
        buildArtistDisplayAlbums(
          source: source,
          field: ArtistAlbumSortField.original,
          ascending: true,
        ).map((e) => e.id),
        ['4', '3', '2', '1'],
      );
    });

    test('title 按名称小写比较，大小写不敏感', () {
      final mixed = [
        _a('x', 'beta'),
        _a('y', 'Alpha'),
        _a('z', 'gamma'),
      ];
      expect(
        buildArtistDisplayAlbums(
          source: mixed,
          field: ArtistAlbumSortField.title,
          ascending: true,
        ).map((e) => e.id),
        ['y', 'x', 'z'],
      );
      expect(
        buildArtistDisplayAlbums(
          source: mixed,
          field: ArtistAlbumSortField.title,
          ascending: false,
        ).map((e) => e.id),
        ['z', 'x', 'y'],
      );
    });

    test('query 命中名称或歌手；空串不过滤', () {
      expect(
        buildArtistDisplayAlbums(
          source: source,
          field: ArtistAlbumSortField.original,
          ascending: false,
          query: 'B专',
        ).map((e) => e.id),
        ['1'],
      );
      expect(
        buildArtistDisplayAlbums(
          source: [
            _a('1', '无名', artist: '陶喆'),
            _a('2', '也无名', artist: '方大同'),
          ],
          field: ArtistAlbumSortField.original,
          ascending: false,
          query: '陶喆',
        ).map((e) => e.id),
        ['1'],
      );
      expect(
        buildArtistDisplayAlbums(
          source: source,
          field: ArtistAlbumSortField.original,
          ascending: false,
          query: '',
        ),
        hasLength(4),
      );
    });

    test('过滤+排序叠加：先过滤再按字段排', () {
      expect(
        buildArtistDisplayAlbums(
          source: source,
          field: ArtistAlbumSortField.title,
          ascending: true,
          query: '专辑',
        ).map((e) => e.id),
        ['2', '1', '3', '4'],
      );
    });

    test('不修改传入的源列表', () {
      final ids = source.map((e) => e.id).toList();
      buildArtistDisplayAlbums(
        source: source,
        field: ArtistAlbumSortField.title,
        ascending: false,
      );
      buildArtistDisplayAlbums(
        source: source,
        field: ArtistAlbumSortField.original,
        ascending: true,
      );
      expect(source.map((e) => e.id), ids);
    });
  });
}
