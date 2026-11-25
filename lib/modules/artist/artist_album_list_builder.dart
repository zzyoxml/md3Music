import '../../data/models/album.dart';

/// 歌手详情页专辑列表的排序字段。
///
/// 与 [ArtistSongSortField] 同一套语义：`original` 表示沿用接口顺序
/// （热度榜 / 最新榜），`title` 是纯客户端排序，不重新请求。
/// 发行年份不做客户端排序——它与服务端的「按发布时间」是同一件事。
enum ArtistAlbumSortField {
  /// 接口返回顺序。`ascending=true` 表示把接口顺序整体反转。
  original,

  /// 按 [Album.name] 小写比较。
  title,
}

List<Album> _filtered(List<Album> source, String query) {
  if (query.isEmpty) return List.of(source);
  final q = query.toLowerCase();
  return source
      .where((a) =>
          a.name.toLowerCase().contains(q) ||
          a.artist.toLowerCase().contains(q))
      .toList();
}

/// 生成专辑展示列表：先过滤再排序，整体 O(n log n)（original 档为 O(n)）。
///
/// 调用方必须缓存返回值：歌手页的滚动闸门会持续 setState，每帧重排
/// 是本页踩过的性能问题（见 artist_song_list_builder.dart 同一约定）。
List<Album> buildArtistDisplayAlbums({
  required List<Album> source,
  required ArtistAlbumSortField field,
  required bool ascending,
  String query = '',
}) {
  final list = _filtered(source, query);
  switch (field) {
    case ArtistAlbumSortField.original:
      return ascending ? list.reversed.toList() : list;
    case ArtistAlbumSortField.title:
      // 预取比较键：否则每次比较都新建 toLowerCase 的子串，
      // 放大成 O(n log n) 次分配（与歌曲列表同一手法）。
      final keyed = [for (final a in list) (album: a, key: a.name.toLowerCase())]
        ..sort((a, b) =>
            ascending ? a.key.compareTo(b.key) : b.key.compareTo(a.key));
      return [for (final e in keyed) e.album];
  }
}
