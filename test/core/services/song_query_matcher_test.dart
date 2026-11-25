import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/song_query_matcher.dart';

QueryCandidate _c(String title, String artist, int index) =>
    QueryCandidate(title: title, artist: artist, index: index);

void main() {
  group('normalizeForMatch', () {
    test('剥离括号版本标注与全角标点', () {
      expect(normalizeForMatch('稻香 (Live)'), '稻香');
      expect(normalizeForMatch('稻香（伴奏）'), '稻香');
      expect(normalizeForMatch('《稻香》'), '稻香');
      expect(normalizeForMatch('Hello，World！'), 'helloworld');
    });

    test('空串与纯标点归一化为空', () {
      expect(normalizeForMatch(''), '');
      expect(normalizeForMatch(' --- '), '');
    });
  });

  group('scoreCandidate', () {
    test('标题完全一致高于前缀高于包含', () {
      final exact = scoreCandidate('稻香', _c('稻香', '周杰伦', 0));
      final prefix = scoreCandidate('稻香', _c('稻香2019', '周杰伦', 1));
      final contains = scoreCandidate('稻香', _c('怀念稻香的味道', '周杰伦', 2));
      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(contains));
    });

    test('歌手命中分数低于标题命中', () {
      final titleHit = scoreCandidate('稻香', _c('稻香', '周杰伦', 0));
      final artistHit = scoreCandidate('稻香', _c('晴天', '稻香合唱团', 1));
      expect(titleHit, greaterThan(artistHit));
    });

    test('翻唱被降权，正版胜出', () {
      final candidates = <QueryCandidate>[
        _c('稻香 (Cover)', '某翻唱', 0),
        _c('稻香', '周杰伦', 1),
      ];
      expect(pickBestIndex('稻香', candidates), 1);
    });

    test('多词共现：「周杰伦的稻香」命中标题+歌手', () {
      final candidates = <QueryCandidate>[
        _c('晴天', '周杰伦', 0),
        _c('稻香', '周杰伦', 1),
      ];
      expect(pickBestIndex('周杰伦的稻香', candidates), 1);
    });

    test('完全不相关返回 0', () {
      expect(scoreCandidate('稻香', _c('晴天', '周杰伦', 0)), 0);
    });

    test('空 query 不匹配任何候选', () {
      expect(pickBestIndex('   ', <QueryCandidate>[_c('稻香', '周杰伦', 0)]), isNull);
    });
  });

  group('pickBestIndex', () {
    test('无任何命中返回 null', () {
      final candidates = <QueryCandidate>[_c('晴天', '周杰伦', 0)];
      expect(pickBestIndex('稻香', candidates), isNull);
    });

    test('同分保留搜索结果原序', () {
      final candidates = <QueryCandidate>[
        _c('稻香', '周杰伦', 0),
        _c('稻香', '周杰伦', 1),
      ];
      expect(pickBestIndex('稻香', candidates), 0);
    });

    test('返回的是候选自身的 index 而非列表下标', () {
      final candidates = <QueryCandidate>[
        _c('晴天', '周杰伦', 7),
        _c('稻香', '周杰伦', 9),
      ];
      expect(pickBestIndex('稻香', candidates), 9);
    });
  });
}
