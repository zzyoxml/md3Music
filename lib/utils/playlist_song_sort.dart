import 'package:pinyin/pinyin.dart';

import '../data/models/song.dart';

/// 歌单页（PlaylistPage）内歌曲的排序维度。
enum PlaylistSongSort { time, title, artist, duration, playCount, lastPlayed }

/// 汉字 → 无声调拼音（小写）的单字缓存：歌手/标题去重后字符集有限，
/// 翻页重排直接命中，不重复转换。
final Map<String, String> _pinyinCharCache = {};

/// 把名称转成按拼音 A→Z 的排序键：CJK 基本区逐字转无声调拼音（「陈」→ chen），
/// ASCII / 数字 / 标点（含多歌手分隔符「、; /」）原样保留，整体小写。
///
/// 为什么不直接用 `String.compareTo`：中文按 Unicode 码位排序时「张学友」会
/// 排在「陈奕迅」前，与用户预期的拼音序不符（歌手名/歌曲名称排序问题主诉）。
/// 多音字逐字取第一读音，歌手名场景个别偏差可接受（与主流播放器一致）；
/// 非汉字（英文歌手）保持原样，与拼音键整体按 a→z 混排。
String pinyinSortKey(String name) {
  final buffer = StringBuffer();
  for (final rune in name.runes) {
    if (rune >= 0x4E00 && rune <= 0x9FFF) {
      final char = String.fromCharCode(rune);
      buffer.write(_pinyinCharCache[char] ??= PinyinHelper.getPinyinE(
        char,
        separator: '',
        defPinyin: char,
        format: PinyinFormat.WITHOUT_TONE,
      ).toLowerCase());
    } else {
      buffer.write(String.fromCharCode(rune));
    }
  }
  return buffer.toString().toLowerCase();
}

/// 按酷狗歌单条目的 sort 顺序位排列，缺失 sort 的旧缓存条目留在末尾。
/// 相同 sort 保留接口原序，避免 List.sort 的不稳定排序改变同位歌曲。
List<Song> sortSongsByPlaylistPosition(List<Song> songs) {
  if (!songs.any((song) => song.playlistSort != null)) return songs;
  final indexed = <({Song song, int index})>[
    for (var i = 0; i < songs.length; i++) (song: songs[i], index: i),
  ];
  indexed.sort((a, b) {
    final left = a.song.playlistSort;
    final right = b.song.playlistSort;
    if (left == null) return right == null ? a.index.compareTo(b.index) : 1;
    if (right == null) return -1;
    final order = left.compareTo(right);
    return order != 0 ? order : a.index.compareTo(b.index);
  });
  return indexed.map((item) => item.song).toList();
}

/// 对 [list] 原地排序。
///
/// - [baseOrder]：歌单未经排序的原始列表。其下标即「添加时间」代理，
///   同时是所有维度的末位决胜键——`List.sort` 不稳定，缺了它同键项的
///   顺序不可复现，升/降序也不是严格互逆的。
/// - [playCounts] / [lastPlayTimes]：songId → 播放次数 / 秒级最近播放时间戳，
///   由 HistoryRepository 提供；缺失按 0 参与比较。
/// - 未知歌手（[isUnknownArtist]）归一为空串：升序排最前，降序自然沉底。
void sortPlaylistSongs(
  List<Song> list, {
  required List<Song> baseOrder,
  required PlaylistSongSort sort,
  required bool ascending,
  Map<String, int> playCounts = const {},
  Map<String, int> lastPlayTimes = const {},
}) {
  final rank = <String, int>{
    for (var i = 0; i < baseOrder.length; i++) baseOrder[i].id: i,
  };
  int indexRank(Song song) => rank[song.id] ?? baseOrder.length;

  String artistKey(Song song) =>
      isUnknownArtist(song.artist) ? '' : pinyinSortKey(song.artist);

  String titleKey(Song song) => pinyinSortKey(song.displayName);

  int compare(Song a, Song b) {
    switch (sort) {
      case PlaylistSongSort.time:
        return indexRank(a).compareTo(indexRank(b));
      case PlaylistSongSort.title:
        return titleKey(a).compareTo(titleKey(b));
      case PlaylistSongSort.artist:
        final byArtist = artistKey(a).compareTo(artistKey(b));
        if (byArtist != 0) return byArtist;
        return titleKey(a).compareTo(titleKey(b));
      case PlaylistSongSort.duration:
        return a.duration.compareTo(b.duration);
      case PlaylistSongSort.playCount:
        return (playCounts[a.id] ?? 0).compareTo(playCounts[b.id] ?? 0);
      case PlaylistSongSort.lastPlayed:
        return (lastPlayTimes[a.id] ?? 0).compareTo(lastPlayTimes[b.id] ?? 0);
    }
  }

  list.sort((a, b) {
    final c = compare(a, b);
    if (c != 0) return ascending ? c : -c;
    final r = indexRank(a).compareTo(indexRank(b));
    return ascending ? r : -r;
  });
}
