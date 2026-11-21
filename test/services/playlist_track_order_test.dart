import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/playlist_track_order.dart';

Map<String, dynamic> page(List<int> ids, {int count = 2}) => {
  'status': 1,
  'data': {
    'count': count,
    'info': [
      for (final id in ids)
        {
          'fileid': id,
          'hash': 'same-hash',
          'filename': '歌曲$id',
          'sort': 3 - id,
        },
    ],
  },
};

void main() {
  test('完整分页按云端顺序排列，保留同 hash 的不同歌单条目', () async {
    final order = await loadPlaylistTrackOrder(
      listId: '3',
      metadata: () async => {'list_ver': 7, 'count': 2},
      fetchPage: (number) async => page([number]),
    );
    expect(order.version, 7);
    expect(order.songs.map((song) => song.fileId), [2, 1]);
    expect(
      buildPlaylistTrackOrder(order.songs, order.songs.reversed.toList()),
      '1|0,2|1',
    );
  });

  test('分页中断或重复页不能提交部分歌单', () async {
    for (final duplicate in [false, true]) {
      await expectLater(
        loadPlaylistTrackOrder(
          listId: '3',
          metadata: () async => {'list_ver': 7, 'count': 2},
          fetchPage: (number) async =>
              number == 1 || duplicate ? page([1]) : null,
        ),
        throwsStateError,
      );
    }
  });

  test('读取期间版本变化时拒绝编辑', () async {
    var version = 7;
    await expectLater(
      loadPlaylistTrackOrder(
        listId: '3',
        metadata: () async => {'list_ver': version++, 'count': 2},
        fetchPage: (_) async => page([1, 2]),
      ),
      throwsStateError,
    );
  });

  test('缺少版本号不能用总版本号替代', () async {
    await expectLater(
      loadPlaylistTrackOrder(
        listId: '3',
        metadata: () async => {'total_ver': 7, 'count': 2},
        fetchPage: (_) async => page([1, 2]),
      ),
      throwsStateError,
    );
  });

  test('条目标识校验拒绝缺失、重复、增删和替换，允许重排', () {
    const song = Song(
      id: 'a',
      title: '歌曲',
      artist: '',
      album: '',
      duration: Duration.zero,
      fileId: 1,
    );
    expect(() => buildPlaylistTrackOrder([song], []), throwsStateError);
    final second = song.copyWith(fileId: 2);
    final original = [song, second];
    expect(() => validatePlaylistTrackIds([song, song]), throwsStateError);
    expect(() => validatePlaylistTrackIds([
      Song.fromJson({...song.toJson(), 'fileId': null}),
    ]), throwsStateError);
    for (final invalid in [
      [song, song],
      [song, song.copyWith(fileId: 3)],
      [song, second, song.copyWith(fileId: 3)],
    ]) {
      expect(() => buildPlaylistTrackOrder(original, invalid), throwsStateError);
    }
    expect(buildPlaylistTrackOrder(original, [second, song]), '2|0,1|1');
    expect(original.map((song) => song.fileId), [1, 2]);
  });

  test('逐条失败不能当作云端成功', () {
    expect(
      playlistOrderWriteSucceeded({
        'status': 1,
        'data': [
          {'code': 0},
        ],
      }),
      false,
    );
    expect(
      playlistOrderWriteSucceeded({'status': 1, 'error_code': 20017}),
      false,
    );
    expect(
      playlistOrderWriteSucceeded({
        'status': 1,
        'data': [
          {'code': 1},
        ],
      }),
      true,
    );
  });
}
