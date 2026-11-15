import '../../data/models/album.dart';
import '../../data/models/song.dart';

/// 已购接口单页解包结果。
///
/// [total] 为上游 `data.total`（缺失时为 0，此时 [hasMore] 恒 false，
/// 退化为「无更多」，不再无限加载）。
class PurchasedList<T> {
  const PurchasedList({required this.items, required this.total});

  final List<T> items;
  final int total;

  bool get hasMore => total > 0 && items.length < total;
}

/// 上游列表字段名候选顺序。
///
/// `goods` 必须排在最前：已购版权 openapi 的真实形状是 `data.goods`
/// （对齐 EchoMusic Purchased.vue:83/130）。其余为历史/其他形态兜底。
const List<String> kPurchasedListKeys = <String>[
  'goods',
  'info',
  'audio_list',
  'list',
  'songs',
  'albums',
  'album_list',
  'data',
];

/// 从已购接口响应中取出列表；兼容 `data` 直接是数组的形态。
List<dynamic> purchasedGoodsList(Map<String, dynamic> response) {
  final data = response['data'];
  if (data is List) return data;
  final Map<String, dynamic> src = data is Map<String, dynamic>
      ? data
      : response;
  for (final key in kPurchasedListKeys) {
    final v = src[key];
    if (v is List) return v;
  }
  return const <dynamic>[];
}

/// 已购条目总数（`data.total`，兼容 count / total_count）。
int purchasedTotal(Map<String, dynamic> response) {
  final data = response['data'];
  final Map<String, dynamic> src = data is Map<String, dynamic>
      ? data
      : response;
  return _firstPositiveInt(<dynamic>[
    src['total'],
    src['count'],
    src['total_count'],
  ]);
}

/// 解析已购单曲一页。
PurchasedList<Song> parsePurchasedSongs(Map<String, dynamic> response) {
  final raw = purchasedGoodsList(response);
  final out = <Song>[];
  for (final e in raw) {
    if (e is! Map<String, dynamic>) continue;
    final song = purchasedSongFromJson(e);
    if (song != null) out.add(song);
  }
  return PurchasedList<Song>(items: out, total: purchasedTotal(response));
}

/// 单条已购单曲 → [Song]。hash 取不到时返回 null（不留空 id 脏数据）。
///
/// 字段来源：EchoMusic Purchased.vue:86-118。`need_audio_info=1` 时
/// hash 家族与时长都在 `audio_info` 里，顶层没有 `hash`。
Song? purchasedSongFromJson(Map<String, dynamic> item) {
  final audioRaw = item['audio_info'];
  final audio = audioRaw is Map<String, dynamic>
      ? audioRaw
      : const <String, dynamic>{};

  // Song.id 会被 player_provider 当 hash 请求 song_url
  // （player_provider.dart:2963），必须取真实 hash，不能用 album_audio_id。
  final hash = _firstString(<dynamic>[
    audio['hash'],
    audio['hash_128'],
    audio['hash_320'],
    audio['hash_high'],
    audio['hash_flac'],
    item['hash'],
    item['fileHash'],
    item['FileHash'],
  ]);
  if (hash == null) return null;

  // 上游 audio_info.duration 是毫秒；其余候选按毫秒处理。
  final durationMs = _firstPositiveInt(<dynamic>[
    audio['duration'],
    item['duration'],
    item['time_length'],
  ]);

  return Song(
    id: hash,
    title:
        _firstString(<dynamic>[
          item['songname'],
          item['audio_name'],
          item['name'],
          item['FileName'],
        ]) ??
        '未知歌曲',
    artist:
        _firstString(<dynamic>[
          item['author_name'],
          audio['author_name'],
          item['singername'],
          item['artist_name'],
        ]) ??
        '未知歌手',
    album:
        _firstString(<dynamic>[audio['album_name'], item['album_name']]) ?? '',
    duration: Duration(milliseconds: durationMs),
    isOnline: true,
    albumId: _firstString(<dynamic>[audio['album_id'], item['album_id']]),
    albumAudioId: _firstString(<dynamic>[
      item['album_audio_id'],
      item['good_scid'],
      item['mixsongid'],
    ]),
    artworkUri: _cover(<dynamic>[
      item['album_cover'],
      audio['album_cover'],
      item['cover'],
      item['sizable_cover'],
      item['img'],
      item['imgurl'],
    ]),
  );
}

/// 解析已购专辑一页。
PurchasedList<Album> parsePurchasedAlbums(Map<String, dynamic> response) {
  final raw = purchasedGoodsList(response);
  final out = <Album>[];
  for (final e in raw) {
    if (e is! Map<String, dynamic>) continue;
    final album = purchasedAlbumFromJson(e);
    if (album != null) out.add(album);
  }
  return PurchasedList<Album>(items: out, total: purchasedTotal(response));
}

/// 单条已购专辑 → [Album]。
///
/// 歌手字段是 `singer_name`（EchoMusic Purchased.vue:143-144），
/// 既不在 KugouAlbumBrief 的候选链里，也不在原页面兜底里。
Album? purchasedAlbumFromJson(Map<String, dynamic> item) {
  final id = _firstString(<dynamic>[
    item['album_id'],
    item['albumid'],
    item['AlbumID'],
    item['id'],
  ]);
  if (id == null) return null;
  return Album(
    id: id,
    name:
        _firstString(<dynamic>[
          item['album_name'],
          item['albumname'],
          item['AlbumName'],
          item['name'],
        ]) ??
        '未知专辑',
    artist:
        _firstString(<dynamic>[
          item['singer_name'],
          item['singerName'],
          item['singername'],
          item['artist_name'],
          item['author_name'],
        ]) ??
        '',
    artworkUri: _cover(<dynamic>[
      item['cover'],
      item['album_cover'],
      item['sizable_cover'],
      item['img'],
      item['imgurl'],
      item['pic'],
    ]),
    songCount: 0,
  );
}

String? _firstString(Iterable<dynamic> candidates) {
  for (final c in candidates) {
    if (c == null) continue;
    final s = c.toString().trim();
    if (s.isNotEmpty && s != 'null') return s;
  }
  return null;
}

int _firstPositiveInt(Iterable<dynamic> candidates) {
  for (final c in candidates) {
    if (c is num && c > 0) return c.toInt();
    if (c is String) {
      final v = int.tryParse(c);
      if (v != null && v > 0) return v;
    }
  }
  return 0;
}

/// 封面归一化：`{size}` 占位替换为 400（与 kugou_models.dart:1632-1637 同口径），
/// `//` 协议相对路径补 `https:`。
String? _cover(Iterable<dynamic> candidates) {
  final raw = _firstString(candidates);
  if (raw == null) return null;
  var s = raw.replaceAll('{size}', '400');
  if (s.startsWith('//')) s = 'https:$s';
  return s;
}
