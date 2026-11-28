import '../../data/models/song.dart';
import '../../utils/playlist_song_sort.dart';
import 'kugou_models.dart';

/// 排序编辑快照；可来自已加载列表，保存前与完整云端列表核对。
class PlaylistTrackOrder {
  final String listId;
  /// 已加载列表可能没有版本号；保存时先核对云端完整顺序再取最新版本。
  final int? version;
  final List<Song> songs;
  final String? accountId;

  const PlaylistTrackOrder(
    this.listId,
    this.version,
    this.songs, {
    this.accountId,
  });
}

int? _number(dynamic value) => int.tryParse('$value');

bool playlistOrderWriteSucceeded(Map<String, dynamic>? response) {
  if (response == null || _number(response['status']) != 1) return false;
  bool failed(dynamic value) {
    if (value is List) return value.any(failed);
    if (value is Map) {
      if (value.containsKey('code') && _number(value['code']) != 1) return true;
      if (value.containsKey('error_code') &&
          _number(value['error_code']) != 0) {
        return true;
      }
      return value.values.any(failed);
    }
    return false;
  }

  return !failed(response);
}

/// 前后核对单个歌单的 list_ver，拒绝分页失败、截断及缺失条目标识。
Future<PlaylistTrackOrder> loadPlaylistTrackOrder({
  required String listId,
  String? accountId,
  required Future<Map<String, dynamic>> Function() metadata,
  required Future<Map<String, dynamic>?> Function(int page) fetchPage,
}) async {
  final before = await metadata();
  final version = _number(before['list_ver']);
  final count = _number(before['count']);
  if (version == null || count == null || count < 0) {
    throw StateError('无法取得歌单版本或歌曲总数，请刷新后重试');
  }
  if (count > 9999) throw StateError('暂不支持调整超过 9999 首歌曲的歌单');
  final songs = <Song>[];
  for (var page = 1; songs.length < count; page++) {
    final response = await fetchPage(page);
    if (response == null || _number(response['status']) != 1) {
      throw StateError('歌曲未完整加载，请重新打开排序');
    }
    final result = KugouPlaylistSongs.fromJson(response);
    if (result.songs.isEmpty || result.total != count) {
      throw StateError('歌单内容已变化或未完整加载，请重新打开排序');
    }
    songs.addAll(result.songs.map((song) => song.toSong()));
    if (songs.length > count) throw StateError('歌单内容已变化，请重新打开排序');
  }
  final after = await metadata();
  if (_number(after['list_ver']) != version ||
      _number(after['count']) != count) {
    throw StateError('歌单已在其他设备更新，请重新打开排序');
  }
  final ids = songs.map((song) => song.fileId).toSet();
  if (ids.length != count ||
      songs.any(
        (song) =>
            song.fileId == null ||
            song.fileId! <= 0 ||
            song.playlistSort == null,
      )) {
    throw StateError('歌曲排序信息不完整，暂时无法调整顺序');
  }
  return PlaylistTrackOrder(
    listId,
    version,
    sortSongsByPlaylistPosition(songs),
    accountId: accountId,
  );
}

bool samePlaylistTrackOrder(List<Song> left, List<Song> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i].fileId != right[i].fileId) return false;
  }
  return true;
}

/// 校验条目标识，供进入排序与构造提交数据共用。
Set<int?> validatePlaylistTrackIds(List<Song> songs) {
  final ids = songs.map((song) => song.fileId).toSet();
  if (ids.contains(null) || ids.length != songs.length) {
    throw StateError('排序歌曲与云端歌单不一致，请重新打开排序');
  }
  return ids;
}

String buildPlaylistTrackOrder(List<Song> original, List<Song> reordered) {
  final remaining = validatePlaylistTrackIds(original);
  if (reordered.length != original.length ||
      reordered.any((song) => !remaining.remove(song.fileId))) {
    throw StateError('排序歌曲与云端歌单不一致，请重新打开排序');
  }
  return [
    for (var i = 0; i < reordered.length; i++) '${reordered[i].fileId}|$i',
  ].join(',');
}
