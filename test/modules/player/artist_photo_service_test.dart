import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/artist_photo_service.dart';

void main() {
  group('ArtistPhotoService.parseUrls', () {
    test('status=1 + 二维数组 → 按 sizable_portrait 去重', () {
      final urls = ArtistPhotoService.parseUrls('''
{"status":1,"data":[[{"author":"A","imgs":{"320":[
  {"sizable_portrait":"https://p/1.jpg"},
  {"sizable_portrait":"https://p/2.jpg"},
  {"sizable_portrait":"https://p/1.jpg"}
]}}]]}''');
      expect(urls, ['https://p/1.jpg', 'https://p/2.jpg']);
    });

    test('多分组多尺寸全部摊平', () {
      final urls = ArtistPhotoService.parseUrls('''
{"status":1,"data":[
  [{"imgs":{"320":[{"sizable_portrait":"https://p/a.jpg"}]}}],
  [{"imgs":{"640":[{"sizable_portrait":"https://p/b.jpg"}],"480":[{"sizable_portrait":"https://p/c.jpg"}]}}]
]}''');
      expect(urls, ['https://p/a.jpg', 'https://p/b.jpg', 'https://p/c.jpg']);
    });

    for (final (name, body) in <(String, String)>[
      ('非 JSON', 'not json'),
      ('顶层非 Map', '[]'),
      ('status != 1', '{"status":0,"data":[]}'),
      ('data 缺失', '{"status":1}'),
      ('data 非 List', '{"status":1,"data":{}}'),
      ('imgs 非 Map', '{"status":1,"data":[[{"imgs":[]}]]}'),
      ('sizable_portrait 缺失', '{"status":1,"data":[[{"imgs":{"320":[{}]}}]]}'),
      ('sizable_portrait 空串', '{"status":1,"data":[[{"imgs":{"320":[{"sizable_portrait":""}]}}]]}'),
    ]) {
      test('$name → 空列表（不抛异常）', () {
        expect(ArtistPhotoService.parseUrls(body), isEmpty);
      });
    }
  });

  group('ArtistPhotoService.parseUrls 写真归属过滤', () {
    // 缺陷的真实形状：合作曲 hash 下 A、B 两位歌手各返回一组条目。
    const duet = '''
{"status":1,"data":[[
  {"author_id":11,"author_name":"甲","imgs":{"320":[{"sizable_portrait":"https://p/a.jpg"}]}},
  {"author_id":22,"author_name":"乙","imgs":{"320":[{"sizable_portrait":"https://p/b.jpg"}]}}
]]}''';

    test('按 artistId 过滤：只保留目标歌手条目', () {
      expect(
        ArtistPhotoService.parseUrls(duet, artistId: '22'),
        ['https://p/b.jpg'],
      );
    });

    test('按 artistName 过滤：忽略大小写与首尾空格', () {
      expect(
        ArtistPhotoService.parseUrls(duet, artistName: ' 甲 '),
        ['https://p/a.jpg'],
      );
      const stringAuthor = '''
{"status":1,"data":[[
  {"author":"Jay Chou","imgs":{"320":[{"sizable_portrait":"https://p/1.jpg"}]}},
  {"author":"A-Mei","imgs":{"320":[{"sizable_portrait":"https://p/2.jpg"}]}}
]]}''';
      expect(ArtistPhotoService.parseUrls(stringAuthor, artistName: 'jay chou'), [
        'https://p/1.jpg',
      ]);
    });

    test('author 为 {name,id} 嵌套 Map 时按作者作用域内的 id/name 判定', () {
      const nested = '''
{"status":1,"data":[[
  {"author":{"name":"甲","id":11},"imgs":{"320":[{"sizable_portrait":"https://p/a.jpg"}]}},
  {"author":{"name":"乙","id":22},"imgs":{"320":[{"sizable_portrait":"https://p/b.jpg"}]}}
]]}''';
      expect(ArtistPhotoService.parseUrls(nested, artistId: '11'), [
        'https://p/a.jpg',
      ]);
      expect(ArtistPhotoService.parseUrls(nested, artistName: '乙'), [
        'https://p/b.jpg',
      ]);
    });

    test('id 与 name 同时给出：任一维度命中即保留', () {
      expect(
        ArtistPhotoService.parseUrls(duet, artistId: '99', artistName: '乙'),
        ['https://p/b.jpg'],
      );
      expect(ArtistPhotoService.parseUrls(duet, artistId: '11', artistName: '丙'),
          ['https://p/a.jpg']);
    });

    test('可比字段全部不命中 → 条目丢弃（写真为空由调用方兜底头像）', () {
      const onlyOther =
          '{"status":1,"data":[[{"author_id":22,"author_name":"乙","imgs":{"320":[{"sizable_portrait":"https://p/b.jpg"}]}}]]}';
      expect(
        ArtistPhotoService.parseUrls(onlyOther, artistId: '11', artistName: '甲'),
        isEmpty,
      );
    });

    test('回归钉：条目无任何作者字段 → 判定不了，保留（现状不误伤）', () {
      const noAuthor =
          '{"status":1,"data":[[{"imgs":{"320":[{"sizable_portrait":"https://p/x.jpg"}]}}]]}';
      expect(ArtistPhotoService.parseUrls(noAuthor, artistId: '1'), [
        'https://p/x.jpg',
      ]);
      expect(ArtistPhotoService.parseUrls(noAuthor, artistName: '甲'), [
        'https://p/x.jpg',
      ]);
    });

    test('回归钉：只要 id 但条目只带名字 → 名字映射不到 id，保留而非清空', () {
      const nameOnly =
          '{"status":1,"data":[[{"author_name":"乙","imgs":{"320":[{"sizable_portrait":"https://p/b.jpg"}]}}]]}';
      expect(ArtistPhotoService.parseUrls(nameOnly, artistId: '11'), [
        'https://p/b.jpg',
      ]);
    });

    test('条目顶层裸 id/name 不当作者标识用（语义可能是图集 id/名）', () {
      const ambiguous =
          '{"status":1,"data":[[{"id":777,"name":"写真集","imgs":{"320":[{"sizable_portrait":"https://p/x.jpg"}]}}]]}';
      // 要求核对作者 id=11：条目里没有作者标识 → 不判定 → 保留
      expect(ArtistPhotoService.parseUrls(ambiguous, artistId: '11'), [
        'https://p/x.jpg',
      ]);
    });

    test('author 是「全部歌手」连写时判为命中（放行等于旧行为，不会全空）', () {
      const joined =
          '{"status":1,"data":[[{"author":"甲、乙","imgs":{"320":[{"sizable_portrait":"https://p/j.jpg"}]}}]]}';
      expect(ArtistPhotoService.parseUrls(joined, artistName: '甲'), [
        'https://p/j.jpg',
      ]);
    });

    test('单人艺名本身含分隔符时整串优先命中（不被拆分误伤）', () {
      const tricky =
          '{"status":1,"data":[[{"author":"Tom & Jerry","imgs":{"320":[{"sizable_portrait":"https://p/t.jpg"}]}}]]}';
      expect(ArtistPhotoService.parseUrls(tricky, artistName: 'Tom & Jerry'), [
        'https://p/t.jpg',
      ]);
      // 该条目里没有「Jerry」这个独立作者名以外的信息，整串不等 + 分段都不等 → 丢弃
      expect(
        ArtistPhotoService.parseUrls(tricky, artistId: '1', artistName: 'Spike'),
        isEmpty,
      );
    });

    test('不传归属参数 → 与历史行为逐条等价', () {
      expect(ArtistPhotoService.parseUrls(duet), [
        'https://p/a.jpg',
        'https://p/b.jpg',
      ]);
      expect(ArtistPhotoService.parseUrls(duet, artistName: ''), [
        'https://p/a.jpg',
        'https://p/b.jpg',
      ]);
      expect(ArtistPhotoService.parseUrls(duet, artistId: '', artistName: null), [
        'https://p/a.jpg',
        'https://p/b.jpg',
      ]);
    });
  });

  group('ArtistPhotoService.load', () {
    test('归属参数透传：合作曲响应只拿到本歌手写真', () async {
      final s = ArtistPhotoService(fetcher: (_) async => '''
{"status":1,"data":[[
  {"author_id":11,"imgs":{"320":[{"sizable_portrait":"https://p/a.jpg"}]}},
  {"author_id":22,"imgs":{"320":[{"sizable_portrait":"https://p/b.jpg"}]}}
]]}''');
      expect(await s.load(hash: 'h', artistId: '11'), ['https://p/a.jpg']);
      // 不传（播放页用法）→ 两人写真都返回，行为不变
      expect(await s.load(hash: 'h'), ['https://p/a.jpg', 'https://p/b.jpg']);
    });

    test('hash 为空 → 不发请求，返回空', () async {
      var called = 0;
      final s = ArtistPhotoService(fetcher: (_) async {
        called++;
        return '';
      });
      expect(await s.load(hash: ''), isEmpty);
      expect(called, 0);
    });

    test('fetcher 抛异常 → 返回空（不冒泡）', () async {
      final s = ArtistPhotoService(fetcher: (_) async => throw Exception('boom'));
      expect(await s.load(hash: 'abc'), isEmpty);
    });

    test('instance 可被测试替换', () async {
      final previous = ArtistPhotoService.instance;
      addTearDown(() => ArtistPhotoService.instance = previous);
      ArtistPhotoService.instance = ArtistPhotoService(
        fetcher: (_) async => '{"status":1,"data":[]}',
      );
      expect(ArtistPhotoService.instance, isNot(same(previous)));
    });
  });
}
