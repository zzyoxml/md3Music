// test/modules/coverflow/coverflow_source_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/coverflow/coverflow_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoverFlowSource', () {
    test('values 顺序固定：每日推荐、FM 四档、刷歌推荐', () {
      // 顺序即设置页下拉条目顺序，不许乱；FM 四档摊平（同 StartupAutoPlaySource 口径），
      // 新档位一律追加在小众之后、刷歌之前。
      expect(
        CoverFlowSource.values.map((e) => e.label).toList(),
        [
          '每日推荐',
          '私人FM · 红心',
          '私人FM · 探索',
          '私人FM · 小众',
          '私人FM · 电台',
          '刷歌推荐',
        ],
      );
    });

    test('tryParse：合法 rawValue 命中，非法/空回退每日推荐', () {
      expect(CoverFlowSource.tryParse('daily'), CoverFlowSource.daily);
      expect(CoverFlowSource.tryParse('personalFm'), CoverFlowSource.fmHeart);
      expect(
        CoverFlowSource.tryParse('fmExplore'),
        CoverFlowSource.fmExplore,
      );
      expect(CoverFlowSource.tryParse('fmNiche'), CoverFlowSource.fmNiche);
      expect(CoverFlowSource.tryParse('fmRadio'), CoverFlowSource.fmRadio);
      expect(
        CoverFlowSource.tryParse('homeDiscover'),
        CoverFlowSource.homeDiscover,
      );
      expect(CoverFlowSource.tryParse('nonsense'), CoverFlowSource.daily);
      expect(CoverFlowSource.tryParse(null), CoverFlowSource.daily);
      expect(CoverFlowSource.tryParse(''), CoverFlowSource.daily);
    });

    test('rawValue 与 label 一一对应（持久化契约）', () {
      final raws = CoverFlowSource.values.map((e) => e.rawValue).toSet();
      expect(raws.length, CoverFlowSource.values.length);
      expect(raws, {
        'daily',
        'personalFm',
        'fmExplore',
        'fmNiche',
        'fmRadio',
        'homeDiscover',
      });
    });

    test('kCoverFlowSource 初始值为每日推荐', () {
      expect(kCoverFlowSource.value, CoverFlowSource.daily);
    });

    test('fmStationIndex 对齐 kFmStations：红心0/探索1/小众2/电台3，非 FM 源为 null', () {
      // kFmStations（personal_fm_core）顺序：0=红心(normal/0) 1=探索(normal/2)
      // 2=小众(small/1) 3=电台(radio/0)。档位表只允许末尾追加，插入会让
      // 已持久化的下标整体错位，所以这四个数字是契约。
      expect(CoverFlowSource.fmHeart.fmStationIndex, 0);
      expect(CoverFlowSource.fmExplore.fmStationIndex, 1);
      expect(CoverFlowSource.fmNiche.fmStationIndex, 2);
      expect(CoverFlowSource.fmRadio.fmStationIndex, 3);
      expect(CoverFlowSource.daily.fmStationIndex, isNull);
      expect(CoverFlowSource.homeDiscover.fmStationIndex, isNull);
    });
  });
}
