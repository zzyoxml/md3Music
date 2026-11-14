import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/user/purchased_parser.dart';

/// 按 EchoMusic Purchased.vue:76-160 的契约构造（data.goods + audio_info.*）。
Map<String, dynamic> _songsPayload() => {
  'status': 1,
  'error_code': 0,
  'data': {
    'total': 2,
    'goods': [
      {
        'album_audio_id': '123456',
        'good_scid': '789',
        'songname': '晴天',
        'author_name': '周杰伦',
        'album_cover':
            'https://imge.kugou.com/stdmusic/{size}/20230101/aaa.jpg',
        'album_id': '999',
        'audio_info': {
          'hash': '',
          'hash_128': 'hash128aaa',
          'hash_320': 'hash320aaa',
          'hash_high': 'hashhighaaa',
          'hash_flac': 'hashflacaaa',
          'duration': 269000,
          'album_name': '叶惠美',
          'album_id': '999',
        },
      },
      {
        'songname': '稻香',
        'author_name': '周杰伦',
        'audio_info': {'hash_320': 'hash320bbb', 'duration': 223000},
      },
    ],
  },
};

void main() {
  group('purchasedGoodsList', () {
    test('读取 data.goods（上游真实形状）', () {
      expect(purchasedGoodsList(_songsPayload()).length, 2);
    });

    test('兼容历史形状 data.info / data.list', () {
      expect(
        purchasedGoodsList({
          'data': {
            'info': [1, 2],
          },
        }).length,
        2,
      );
      expect(
        purchasedGoodsList({
          'data': {
            'list': [1],
          },
        }).length,
        1,
      );
    });

    test('无列表字段时返回空', () {
      expect(
        purchasedGoodsList({
          'data': {'total': 0},
        }),
        isEmpty,
      );
      expect(purchasedGoodsList({}), isEmpty);
    });
  });

  group('purchasedTotal', () {
    test('读 data.total', () {
      expect(purchasedTotal(_songsPayload()), 2);
    });
    test('缺失时为 0', () {
      expect(purchasedTotal({'data': {}}), 0);
    });
  });

  group('parsePurchasedSongs', () {
    test('id 取 audio_info 里的 hash（播放链路依赖 Song.id 当 hash）', () {
      final list = parsePurchasedSongs(_songsPayload());
      expect(list.items.length, 2);
      expect(list.items.first.id, 'hash128aaa');
      expect(list.items.last.id, 'hash320bbb');
    });

    test('时长按毫秒解析（audio_info.duration）', () {
      final list = parsePurchasedSongs(_songsPayload());
      expect(list.items.first.duration, const Duration(milliseconds: 269000));
    });

    test('歌手/专辑名/封面来自 author_name 与 audio_info', () {
      final song = parsePurchasedSongs(_songsPayload()).items.first;
      expect(song.artist, '周杰伦');
      expect(song.album, '叶惠美');
      expect(song.albumId, '999');
      expect(song.albumAudioId, '123456');
      expect(song.isOnline, isTrue);
    });

    test('封面替换 {size} 占位符', () {
      final song = parsePurchasedSongs(_songsPayload()).items.first;
      expect(
        song.artworkUri,
        'https://imge.kugou.com/stdmusic/400/20230101/aaa.jpg',
      );
    });

    test('无 hash 的条目被丢弃（不留空 id 脏数据）', () {
      final list = parsePurchasedSongs({
        'data': {
          'goods': [
            {'songname': '无 hash'},
          ],
        },
      });
      expect(list.items, isEmpty);
    });

    test('hasMore 由 total 与已取条数决定', () {
      final list = parsePurchasedSongs(_songsPayload());
      expect(list.total, 2);
      expect(list.hasMore, isFalse);
    });
  });

  group('parsePurchasedAlbums', () {
    test('映射 album_id / album_name / singer_name / cover', () {
      final list = parsePurchasedAlbums({
        'data': {
          'total': 1,
          'goods': [
            {
              'album_id': '888',
              'album_name': '七里香',
              'singer_name': '周杰伦',
              'cover': '//imge.kugou.com/stdmusic/{size}/bbb.jpg',
            },
          ],
        },
      });
      expect(list.items.length, 1);
      expect(list.items.first.id, '888');
      expect(list.items.first.name, '七里香');
      expect(list.items.first.artist, '周杰伦');
      expect(
        list.items.first.artworkUri,
        'https://imge.kugou.com/stdmusic/400/bbb.jpg',
      );
    });

    test('无 album_id 的条目被丢弃', () {
      expect(
        parsePurchasedAlbums({
          'data': {
            'goods': [
              {'album_name': 'x'},
            ],
          },
        }).items,
        isEmpty,
      );
    });
  });
}
