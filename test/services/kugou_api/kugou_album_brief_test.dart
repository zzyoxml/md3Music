import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/album.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

void main() {
  group('KugouAlbumBrief.fromJson', () {
    test('解析 camelCase 标准字段并替换 {size} 占位符', () {
      final brief = KugouAlbumBrief.fromJson({
        'albumid': 321,
        'albumname': '测试专辑',
        'singername': '测试歌手',
        'imgurl': 'http://imge.kugou.com/{size}/album/321.jpg',
        'publish_time': 1719792000,
      });
      expect(brief.id, '321');
      expect(brief.name, '测试专辑');
      expect(brief.artist, '测试歌手');
      expect(brief.coverUrl, 'http://imge.kugou.com/400/album/321.jpg');
      expect(brief.year, 2024); // 1719792000 = 2024-07-01 (UTC 附近)
    });

    test('解析 snake_case 别名字段', () {
      final brief = KugouAlbumBrief.fromJson({
        'album_id': '999',
        'album_name': '别名专辑',
        'author_name': '别名歌手',
        'cover': 'http://example.com/cover.jpg',
      });
      expect(brief.id, '999');
      expect(brief.name, '别名专辑');
      expect(brief.artist, '别名歌手');
      expect(brief.coverUrl, 'http://example.com/cover.jpg');
    });

    test('publish_date 字符串取年份；全缺失不抛异常', () {
      final brief = KugouAlbumBrief.fromJson({
        'albumid': 1,
        'albumname': 'x',
        'publish_date': '2024-07-01',
      });
      expect(brief.year, 2024);

      // mobile_newalbum_sp 真机取证的真实字段：publishtime（"YYYY-MM-DD HH:MM:SS"）。
      final real = KugouAlbumBrief.fromJson({
        'albumid': 2,
        'albumname': 'y',
        'publishtime': '2024-07-01 12:00:00',
      });
      expect(real.year, 2024);

      final empty = KugouAlbumBrief.fromJson({});
      expect(empty.id, '');
      expect(empty.name, '');
      expect(empty.artist, '');
      expect(empty.coverUrl, isNull);
      expect(empty.year, isNull);
    });

    test('toAlbum 映射为 Album（songCount 恒为 0）', () {
      final brief = KugouAlbumBrief.fromJson({
        'albumid': 321,
        'albumname': '测试专辑',
        'singername': '测试歌手',
        'imgurl': 'http://imge.kugou.com/{size}/album/321.jpg',
        'publish_date': '2024-07-01',
      });
      final Album album = brief.toAlbum();
      expect(album.id, '321');
      expect(album.name, '测试专辑');
      expect(album.artist, '测试歌手');
      expect(album.artworkUri, 'http://imge.kugou.com/400/album/321.jpg');
      expect(album.songCount, 0);
      expect(album.year, 2024);
    });

    test('cover/pic 是裸文件名时必须跳过，取 sizable_cover', () {
      // 真机取证的 /artist/albums 载荷：cover 与 pic 只有文件名，
      // 绝对地址在 sizable_cover（还带 {size} 占位符）。
      // 旧实现按顺序命中 cover 就返回，列表封面全裂（详情页反而正常）。
      final brief = KugouAlbumBrief.fromJson({
        'album_id': 7547427,
        'album_name': '太平盛世',
        'author_name': '陶喆',
        'sizable_cover': 'http://imge.kugou.com/stdmusic/{size}/20260909/20260909032931659085.jpg',
        'cover': '20260909032931659085.jpg',
        'pic': '20260909032931659085.jpg',
        'publish_date': '2005-01-21',
      });
      expect(
        brief.coverUrl,
        'http://imge.kugou.com/stdmusic/400/20260909/20260909032931659085.jpg',
      );
      expect(brief.id, '7547427');
      expect(brief.year, 2005);
    });

    test('没有任何绝对 URL 时封面为 null（不把裸文件名当 URL 用）', () {
      final brief = KugouAlbumBrief.fromJson({
        'albumid': 1,
        'albumname': 'x',
        'cover': 'bare-name.jpg',
        'pic': '',
      });
      expect(brief.coverUrl, isNull);
    });
  });

  group('KugouArtistAlbums.fromJson', () {
    test('data 是数组：不再抛 TypeError（真机 /artist/albums 就是这个形态）', () {
      final result = KugouArtistAlbums.fromJson({
        'total': 29,
        'error_code': 0,
        'data': [
          {
            'album_id': 7547427,
            'album_name': '太平盛世',
            'sizable_cover': 'http://imge.kugou.com/stdmusic/{size}/a.jpg',
          },
          {
            'album_id': 111,
            'album_name': '另一张',
            'sizable_cover': 'http://imge.kugou.com/stdmusic/{size}/b.jpg',
          },
        ],
      });
      expect(result.albums, hasLength(2));
      expect(result.albums.first.id, '7547427');
      expect(
        result.albums.first.coverUrl,
        'http://imge.kugou.com/stdmusic/400/a.jpg',
      );
      // total 只在根节点，数组形态下也要拿到
      expect(result.total, 29);
    });

    test('data 是对象时仍走 list/albums/info 口径', () {
      final result = KugouArtistAlbums.fromJson({
        'data': {
          'list': [
            {'album_id': 1, 'album_name': 'x'},
          ],
          'total': 8,
        },
      });
      expect(result.albums, hasLength(1));
      expect(result.total, 8);
    });
  });
}
