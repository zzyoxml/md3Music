import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/utils/playlist_write_payload.dart';

/// 构造 Song。[albumAudioId] / [fileId] 用 -1 表示「显式传 null」。
Song _song(
  String id, {
  String title = '歌名',
  String? albumId,
  Object? albumAudioId = '',
  Object? fileId,
}) {
  return Song(
    id: id,
    title: title,
    artist: '歌手',
    album: '专辑',
    duration: const Duration(seconds: 200),
    albumId: albumId,
    albumAudioId: albumAudioId == -1 ? null : albumAudioId as String?,
    fileId: fileId == -1 ? null : fileId as int?,
  );
}

void main() {
  group('buildTrackAddData', () {
    test('四段齐全：歌名|hash|专辑id|album_audio_id', () {
      expect(
        buildTrackAddData(
          _song('ABC123', title: '我们应该算爱过吧', albumId: '67026620', albumAudioId: '477417208'),
        ),
        '我们应该算爱过吧|ABC123|67026620|477417208',
      );
    });

    test('albumId 缺失 → 0', () {
      expect(
        buildTrackAddData(_song('H1', title: 'T')),
        'T|H1|0|0',
      );
    });

    test('albumAudioId 非数字 → 0（不是原样透传）', () {
      expect(
        buildTrackAddData(_song('H1', title: 'T', albumId: '9', albumAudioId: 'abc')),
        'T|H1|9|0',
      );
    });

    test('与重构前两处内联拼装的输出逐字节一致（防回归）', () {
      // 这两处曾各自内联拼装：add_to_playlist_dialog.dart 与 favorites_provider.dart
      for (final albumAudioId in [null, '', '0', '123', 'xyz']) {
        final song = _song(
          'ABCDEF',
          title: '有些',
          albumId: '42',
          albumAudioId: albumAudioId == null ? -1 : albumAudioId,
        );
        final legacy =
            '${song.title}|${song.id}|${song.albumId ?? 0}|${int.tryParse(song.albumAudioId ?? '') ?? 0}';
        expect(buildTrackAddData(song), legacy,
            reason: 'albumAudioId=$albumAudioId 时与旧内联实现不一致');
      }
    });
  });

  group('buildTrackAddBatches', () {
    test('按批切分并用逗号连接', () {
      final songs = [for (var i = 0; i < 5; i++) _song('H$i', title: 'T$i')];
      final batches = buildTrackAddBatches(songs, batchSize: 2);
      expect(batches, hasLength(3));
      expect(batches[0], 'T0|H0|0|0,T1|H1|0|0');
      expect(batches[1], 'T2|H2|0|0,T3|H3|0|0');
      expect(batches[2], 'T4|H4|0|0');
    });

    test('空列表 → 空批次（不发请求）', () {
      expect(buildTrackAddBatches(const []), isEmpty);
    });

    test('batchSize <= 0 回落默认批大小而不是死循环/空批', () {
      final songs = [for (var i = 0; i < 3; i++) _song('H$i', title: 'T$i')];
      final batches = buildTrackAddBatches(songs, batchSize: 0);
      expect(batches, hasLength(1));
    });

    test('默认批大小覆盖整批边界（50 首 → 2 批）', () {
      final songs = [for (var i = 0; i < 50; i++) _song('H$i', title: 'T$i')];
      expect(buildTrackAddBatches(songs), hasLength(1));
      songs.add(_song('H50', title: 'T50'));
      expect(buildTrackAddBatches(songs), hasLength(2));
    });
  });

  group('buildListSortData', () {
    test('listid|type|sort', () {
      expect(
        buildListSortData(const [
          PlaylistSortEntry(listId: '11', type: 0, sort: 0),
          PlaylistSortEntry(listId: '22', type: 0, sort: 1),
          PlaylistSortEntry(listId: '33', type: 1, sort: 0),
        ]),
        '11|0|0,22|0|1,33|1|0',
      );
    });

    test('非数字 listid 被跳过（上游 Number() 会产出 NaN，整条请求可能被拒）', () {
      expect(
        buildListSortData(const [
          PlaylistSortEntry(listId: '11', type: 0, sort: 0),
          PlaylistSortEntry(listId: 'abc', type: 0, sort: 1),
          PlaylistSortEntry(listId: '', type: 0, sort: 2),
          PlaylistSortEntry(listId: '44', type: 0, sort: 3),
        ]),
        '11|0|0,44|0|3',
      );
    });
  });

  group('buildPlaylistSortEntries', () {
    test('按传入顺序编号，type 由调用方指定', () {
      final entries = buildPlaylistSortEntries(
        [
          KugouPlaylistBrief.fromJson(const {'listid': '11', 'name': 'A'}),
          KugouPlaylistBrief.fromJson(const {'listid': '22', 'name': 'B'}),
        ],
        type: 1,
      );
      expect(entries.map((e) => '${e.listId}|${e.type}|${e.sort}').toList(),
          ['11|1|0', '22|1|1']);
    });

    test('listId 为空时回落 listCreateListid', () {
      final entries = buildPlaylistSortEntries(
        [
          KugouPlaylistBrief.fromJson(
            const {'list_create_listid': '77', 'name': 'A'},
          ),
        ],
        type: 0,
      );
      expect(entries.single.listId, '77');
    });

    test('两者都取不到 → 跳过该条（不产出空 listid）', () {
      final entries = buildPlaylistSortEntries(
        [KugouPlaylistBrief.fromJson(const {'name': 'A'})],
        type: 0,
      );
      expect(entries, isEmpty);
    });
  });

  group('normalizeStdmusicPic', () {
    test('完整 URL → 末段补 stdmusic/ 前缀', () {
      expect(
        normalizeStdmusicPic(
          'https://imge.kugou.com/stdmusic/240/20210111/20210111184454391203.jpg',
        ),
        'stdmusic/20210111184454391203.jpg',
      );
      expect(
        normalizeStdmusicPic('http://imge.kugou.com/stdmusic/{size}/a.jpg'),
        'stdmusic/a.jpg',
      );
    });

    test('已带前缀的相对路径原样返回', () {
      expect(
        normalizeStdmusicPic('stdmusic/20210111/x.jpg'),
        'stdmusic/20210111/x.jpg',
      );
    });

    test('裸文件名补前缀', () {
      expect(normalizeStdmusicPic('x.jpg'), 'stdmusic/x.jpg');
    });
  });

  group('KugouApiClient.parseUserPlaylistTotalVer', () {
    test('data 段优先取 total_ver', () {
      expect(
        KugouApiClient.parseUserPlaylistTotalVer(const {
          'data': {'total_ver': 9},
        }),
        9,
      );
    });

    test('data.list_ver 兜底', () {
      expect(
        KugouApiClient.parseUserPlaylistTotalVer(const {
          'data': {'list_ver': 7},
        }),
        7,
      );
    });

    test('顶层兜底（部分上游把 total_ver 放外层）', () {
      expect(
        KugouApiClient.parseUserPlaylistTotalVer(const {'total_ver': 12}),
        12,
      );
    });

    test('字符串数字可解析（上游偶发回字符串）', () {
      expect(
        KugouApiClient.parseUserPlaylistTotalVer(const {
          'data': {'total_ver': '15'},
        }),
        15,
      );
    });

    test('缺失 / null / 0 → 0（不把失败响应当版本号）', () {
      expect(KugouApiClient.parseUserPlaylistTotalVer(null), 0);
      expect(KugouApiClient.parseUserPlaylistTotalVer(const {}), 0);
      expect(
        KugouApiClient.parseUserPlaylistTotalVer(const {
          'data': {'total_ver': 0},
        }),
        0,
      );
      expect(
        KugouApiClient.parseUserPlaylistTotalVer(const {
          'data': {'total_ver': 'abc'},
        }),
        0,
      );
    });
  });

  group('模型新增版本号字段', () {
    test('KugouPlaylistBrief.totalVer 读 total_ver 并回落 list_ver', () {
      expect(
        KugouPlaylistBrief.fromJson(const {'name': 'A', 'total_ver': 9}).totalVer,
        9,
      );
      expect(
        KugouPlaylistBrief.fromJson(const {'name': 'A', 'list_ver': 3}).totalVer,
        3,
      );
      expect(KugouPlaylistBrief.fromJson(const {'name': 'A'}).totalVer, 0);
    });

    test('KugouPlaylistBrief.toPlaylist 透传 totalVer', () {
      final p = KugouPlaylistBrief.fromJson(
        const {'name': 'A', 'total_ver': 21},
      ).toPlaylist();
      expect(p.totalVer, 21);
    });
  });
}
