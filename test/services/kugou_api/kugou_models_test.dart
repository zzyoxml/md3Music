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
}
