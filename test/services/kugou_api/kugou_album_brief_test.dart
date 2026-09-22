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
  });
}
