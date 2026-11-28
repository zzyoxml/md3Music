import '../../data/models/song.dart';

/// 歌手详情页列表的排序字段。
enum ArtistSongSortField {
  /// 接口返回顺序（热度榜 / 最新榜）。**不做任何比较**，直接复用源序或反转。
  original,

  /// 按 [Song.displayName]（去扩展名）小写比较。
  title,

  /// 按 [Song.duration] 数值比较。
  duration,
}

/// 扩展名正则提升为顶层常量：`Song.displayName` 每次调用都新建 RegExp，
/// 排序时逐比较复用它会放大成 O(n log n) 次构造。
final RegExp _audioExtPattern = RegExp(
  r'\.(mp3|flac|wav|ape|m4a|ogg|aac|wma|opus)$',
  caseSensitive: false,
);

String _titleKey(Song song) =>
    song.title.replaceFirst(_audioExtPattern, '').toLowerCase();

List<Song> _filtered(List<Song> source, String query) {
  if (query.isEmpty) return List.of(source);
  final q = query.toLowerCase();
  return source
      .where((s) =>
          s.title.toLowerCase().contains(q) ||
          s.artist.toLowerCase().contains(q) ||
          s.album.toLowerCase().contains(q))
      .toList();
}

/// 生成展示列表：先过滤再排序，整体 O(n log n)（original 档为 O(n)）。
///
/// 语义与 `ArtistDetailPage` 旧实现逐条对齐：`original` 的 `ascending=true`
/// 表示「接口顺序反转」（旧代码是 `_songs.indexOf` 比较后取负）。
List<Song> buildArtistDisplaySongs({
  required List<Song> source,
  required ArtistSongSortField field,
  required bool ascending,
  String query = '',
}) {
  final list = _filtered(source, query);
  switch (field) {
    case ArtistSongSortField.original:
      return ascending ? list.reversed.toList() : list;
    case ArtistSongSortField.title:
      final keyed = [for (final s in list) (song: s, key: _titleKey(s))]..sort(
          (a, b) => ascending ? a.key.compareTo(b.key) : b.key.compareTo(a.key));
      return [for (final e in keyed) e.song];
    case ArtistSongSortField.duration:
      final keyed = [for (final s in list) (song: s, key: s.duration)]..sort(
          (a, b) => ascending ? a.key.compareTo(b.key) : b.key.compareTo(a.key));
      return [for (final e in keyed) e.song];
  }
}
