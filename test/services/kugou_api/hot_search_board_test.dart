import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 上游 hot_tab 真实结构（2026-10-04 由 Rust 服务实测取回，见 tmp/hot_full.txt）：
/// data.list 是「榜单」数组，每个榜单的 keywords 里才是词。
const _realShapePayload = '''
{"status":1,"errcode":0,"data":{"timestamp":1791062026,"list":[
  {"name":"热搜榜","keywords":[
    {"reason":"茶汤","json_url":"","jumpurl":"","keyword":"茶汤","is_cover_word":0,"type":1,"icon":0},
    {"reason":"无奈的思绪","json_url":"","jumpurl":"","keyword":"无奈的思绪","is_cover_word":0,"type":1,"icon":0},
    {"reason":"甲乙丙丁","json_url":"","jumpurl":"","keyword":"甲乙丙丁","is_cover_word":0,"type":1,"icon":0},
    {"reason":"牡丹亭","json_url":"","jumpurl":"","keyword":"牡丹亭","is_cover_word":0,"type":1,"icon":0}
  ]},
  {"name":"飙升榜","keywords":[
    {"reason":"寻屿","json_url":"","jumpurl":"","keyword":"寻屿","is_cover_word":0,"type":1,"icon":0},
    {"reason":"故里逢春","json_url":"","jumpurl":"","keyword":"故里逢春","is_cover_word":0,"type":1,"icon":0}
  ]}
]}}
''';

void main() {
  group('HotSearchBoard.parseList', () {
    test('按上游真实结构抽出榜单与词，顺序保持', () {
      final boards =
          HotSearchBoard.parseList(jsonDecode(_realShapePayload) as Map<String, dynamic>);

      expect(boards.map((b) => b.name), ['热搜榜', '飙升榜']);
      expect(boards.first.keywords, ['茶汤', '无奈的思绪', '甲乙丙丁', '牡丹亭']);
      expect(boards[1].keywords, ['寻屿', '故里逢春']);
    });

    test('旧实现的取值路径是错的（回归：不得把榜名当热搜词）', () {
      final boards =
          HotSearchBoard.parseList(jsonDecode(_realShapePayload) as Map<String, dynamic>);

      // 旧代码 data['list'] → 逐个 m['keyword'] ?? m['name'] → 得到 9 个榜名。
      final allWords = boards.expand((b) => b.keywords).toList();
      for (final board in boards) {
        expect(allWords, isNot(contains(board.name)),
            reason: '榜名混进热搜词即解析退化');
      }
    });

    test('空 keyword 被过滤，整榜无词则丢掉该榜', () {
      final json = jsonDecode('''
      {"status":1,"data":{"list":[
        {"name":"热搜榜","keywords":[{"keyword":""},{"keyword":"有效词"}]},
        {"name":"空榜","keywords":[{"keyword":""}]}
      ]}}
      ''') as Map<String, dynamic>;

      final boards = HotSearchBoard.parseList(json);

      expect(boards.map((b) => b.name), ['热搜榜']);
      expect(boards.first.keywords, ['有效词']);
    });

    test('缺 data / list 非数组 / 结构异常一律返回空列表，不抛', () {
      expect(HotSearchBoard.parseList(<String, dynamic>{}), isEmpty);
      expect(HotSearchBoard.parseList({'data': null}), isEmpty);
      expect(HotSearchBoard.parseList({'data': 'x'}), isEmpty);
      expect(HotSearchBoard.parseList({'data': {'list': 'nope'}}), isEmpty);
      expect(
          HotSearchBoard.parseList({
            'data': {
              'list': [
                {'name': '热搜榜'}
              ]
            }
          }),
          isEmpty);
    });
  });
}
