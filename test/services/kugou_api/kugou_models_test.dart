import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// KugouLyric.fromJson 双格式歌词（LRC + KRC）解析与 getter 降级行为测试
void main() {
  group('KugouLyric.fromJson', () {
    test('同时有 decodeContent 与 decodeKrcContent 时，displayLyric 优先返回 KRC', () {
      const lrcText = '[00:01.00]Hello LRC';
      const krcText = '[1000,2000]<0,1000,0>Hello';
      final lyric = KugouLyric.fromJson({
        'content': 'BASE64_RAW',
        'decodeContent': lrcText,
        'decodeKrcContent': krcText,
      });

      expect(lyric.content, 'BASE64_RAW');
      expect(lyric.decodedContent, lrcText);
      expect(lyric.decodedKrcContent, krcText);

      // 优先返回 KRC
      expect(lyric.displayLyric, krcText);
      // 单独 getter
      expect(lyric.displayLrcLyric, lrcText);
      expect(lyric.displayKrcLyric, krcText);
    });

    test('仅 decodeContent 时，displayLyric 返回 LRC，displayKrcLyric 为 null', () {
      const lrcText = '[00:01.00]Hello LRC';
      final lyric = KugouLyric.fromJson({
        'content': 'BASE64_RAW',
        'decodeContent': lrcText,
      });

      expect(lyric.decodedContent, lrcText);
      expect(lyric.decodedKrcContent, isNull);

      // 无 KRC 时降级到 LRC
      expect(lyric.displayLyric, lrcText);
      expect(lyric.displayLrcLyric, lrcText);
      expect(lyric.displayKrcLyric, isNull);
    });

    test('两者都无，只有 content 时，displayLyric 返回原始 content', () {
      final lyric = KugouLyric.fromJson({
        'content': 'BASE64_RAW',
      });

      expect(lyric.content, 'BASE64_RAW');
      expect(lyric.decodedContent, isNull);
      expect(lyric.decodedKrcContent, isNull);

      // KRC、LRC 均无，最终降级到原始 content
      expect(lyric.displayLyric, 'BASE64_RAW');
      expect(lyric.displayLrcLyric, isNull);
      expect(lyric.displayKrcLyric, isNull);
    });

    test('KRC 字段名降级：decoded_krc_content 与 krcContent 也能被解析', () {
      const krcSnake = '[1000,2000]<0,1000,0>snake';
      const krcCamel = '[2000,2000]<0,1000,0>camel';

      final lyricSnake = KugouLyric.fromJson({
        'decoded_krc_content': krcSnake,
      });
      expect(lyricSnake.decodedKrcContent, krcSnake);
      expect(lyricSnake.displayKrcLyric, krcSnake);
      expect(lyricSnake.displayLrcLyric, isNull);

      final lyricCamel = KugouLyric.fromJson({
        'krcContent': krcCamel,
      });
      expect(lyricCamel.decodedKrcContent, krcCamel);
      expect(lyricCamel.displayKrcLyric, krcCamel);
    });

    test('空 JSON 时 content 为空字符串，所有 getter 均降级为空/null', () {
      final lyric = KugouLyric.fromJson(<String, dynamic>{});

      expect(lyric.content, '');
      expect(lyric.decodedContent, isNull);
      expect(lyric.decodedKrcContent, isNull);
      expect(lyric.displayLyric, '');
      expect(lyric.displayLrcLyric, isNull);
      expect(lyric.displayKrcLyric, isNull);
    });
  });

  group('KugouLoginAccount.fromJson', () {
    test('解析 user_list 字段名兼容', () {
      // 酷狗接口返回的多种字段名
      final a1 = KugouLoginAccount.fromJson({
        'userid': '123', 'nickname': '测试用户', 'avatar': 'https://example.com/avatar.jpg',
      });
      expect(a1.userid, '123');
      expect(a1.nickname, '测试用户');
      expect(a1.avatar, 'https://example.com/avatar.jpg');

      // 驼峰字段名
      final a2 = KugouLoginAccount.fromJson({
        'userId': '456', 'user_name': '用户B', 'pic': 'http://example.com/pic.jpg',
      });
      expect(a2.userid, '456');
      expect(a2.nickname, '用户B');
      expect(a2.avatar, 'http://example.com/pic.jpg');

      // 空字段
      final a3 = KugouLoginAccount.fromJson({'id': '789'});
      expect(a3.userid, '789');
      expect(a3.nickname, isNull);
      expect(a3.avatar, isNull);
    });
  });

  /// /search 接口返回的是「搜索形态」记录：SingerId 为数组、歌手在 Singers
  /// 数组里、封面在 Image / trans_param.union_cover、专辑在 AlbumID/AlbumName。
  /// 这些用例的字段形状取自真机实测响应（tmp/search.json），不是构造的。
  group('KugouSongDetail.fromJson 搜索形态', () {
    test('SingerId 为数组时取首个 id 作为 artistId', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'SongName': '桃花诺',
        'SingerName': 'G.E.M.邓紫棋',
        'SingerId': [4490],
        'Singers': [
          {'name': 'G.E.M.邓紫棋', 'id': 4490, 'ip_id': 0},
        ],
        'AlbumID': '2681514',
        'AlbumName': '桃花诺',
      });

      expect(d.artistId, '4490');
      expect(d.artistName, 'G.E.M.邓紫棋');
      expect(d.albumId, '2681514');
      expect(d.albumName, '桃花诺');
    });

    test('合唱曲目 SingerId 多元素时取首个 id（与 Singers 顺序一致）', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': '6BDE4FD59A63A21F5DA182C29FBA25B4',
        'SongName': '桃花诺 (Live)',
        'SingerName': '罗云熙、黄霄雲',
        'SingerId': [184908, 194052],
        'Singers': [
          {'name': '罗云熙', 'id': 184908, 'ip_id': 0},
          {'name': '黄霄雲', 'id': 194052, 'ip_id': 0},
        ],
        'AlbumID': '198053621',
        'AlbumName': '天赐的声音第七季 第4期',
      });

      expect(d.artistId, '184908');
      expect(d.artistName, '罗云熙、黄霄雲');
      expect(d.albumId, '198053621');
    });

    test('SingerId 为标量字符串时仍能解析（不回归其他接口形态）', () {
      final d = KugouSongDetail.fromJson({
        'hash': 'ABC',
        'songname': '某歌',
        'SingerId': '4490',
      });

      expect(d.artistId, '4490');
    });

    test('SingerId 为空数组时回退到其他候选键，不返回空串 id', () {
      final d = KugouSongDetail.fromJson({
        'hash': 'ABC',
        'songname': '某歌',
        'SingerId': <dynamic>[],
        'artist_id': '777',
      });

      expect(d.artistId, '777');
    });

    test('Image 作为封面来源，{size} 占位符替换为 400', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'SongName': '桃花诺',
        'Image':
            'http://imge.kugou.com/stdmusic/{size}/20200909/20200909124212131553.jpg',
      });

      expect(
        d.artworkUri,
        'http://imge.kugou.com/stdmusic/400/20200909/20200909124212131553.jpg',
      );
    });

    test('trans_param.union_cover 作为封面兜底来源', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'SongName': '桃花诺',
        'trans_param': {
          'union_cover':
              'http://imge.kugou.com/stdmusic/{size}/20230226/20230226114315528773.jpg',
        },
      });

      expect(
        d.artworkUri,
        'http://imge.kugou.com/stdmusic/400/20230226/20230226114315528773.jpg',
      );
    });

    test('toSong() 带出 artistId/albumId/封面，供详情页跳转使用', () {
      final d = KugouSongDetail.fromJson({
        'FileHash': 'FF3BA0A7AD50D5BEBB2ED7907F15608C',
        'FileName': 'G.E.M.邓紫棋 - 桃花诺',
        'SongName': '桃花诺',
        'SingerName': 'G.E.M.邓紫棋',
        'SingerId': [4490],
        'Singers': [
          {'name': 'G.E.M.邓紫棋', 'id': 4490, 'ip_id': 0},
        ],
        'AlbumID': '2681514',
        'AlbumName': '桃花诺',
        'Image':
            'http://imge.kugou.com/stdmusic/{size}/20200909/20200909124212131553.jpg',
      });

      final song = d.toSong();
      expect(song.artistId, '4490');
      expect(song.albumId, '2681514');
      expect(song.artist, 'G.E.M.邓紫棋');
      expect(song.title, '桃花诺');
      expect(
        song.artworkUri,
        'http://imge.kugou.com/stdmusic/400/20200909/20200909124212131553.jpg',
      );
    });
  });
}
