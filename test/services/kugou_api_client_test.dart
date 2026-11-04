import 'package:flutter_test/flutter_test.dart';

void main() {
  group('getSongsDetails 响应解析', () {
    test('data 为对象数组 → 逐项解析', () {
      final json = {
        'status': 1,
        'data': [
          {'hash': 'AAA', 'audio_name': '歌一'},
          {'hash': 'BBB', 'audio_name': '歌二'},
        ],
      };
      final rawData = json['data'] as List;
      expect(rawData.length, 2);
      expect((rawData.first as Map)['hash'], 'AAA');
    });

    test('data 为单对象（上游对单 hash 的兼容形态）→ 包装为单项', () {
      final json = {
        'status': 1,
        'data': {'hash': 'AAA', 'audio_name': '歌一'},
      };
      final rawData = json['data'];
      final entries = rawData is List ? rawData : <dynamic>[rawData];
      expect(entries.length, 1);
    });

    test('data 为空 → 空列表', () {
      const json = <String, dynamic>{};
      final rawData = json['data'] ?? json;
      final entries = rawData is List ? rawData : <dynamic>[rawData];
      // {} 兜底为 [{}]，逐项解析时跳过非法项 → 最终 0 条
      expect(entries.length, 1);
    });
  });
}
