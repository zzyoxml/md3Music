// 小米 CarWith 两条设置项的搜索索引回归。
//
// 覆盖三件事（说明书 §一「主题」段 + §五 改动清单 + §七 文案探针）：
//  1) 两条新条目确实在索引里，且 category / subpage 落在正确层级
//     （歌词 → 设备歌词、外观 → 主题与配色）；
//  2) 索引是编译期常量、看不穿运行时平台，所以这两条由消费端按
//     `supportsCarWith` 过滤 —— 过滤函数双向断言（支持/不支持都要成立）；
//  3) §七 列为「0 命中」的旧文案探针不得出现在索引里（改名没改净的证据）。
//     探针只能用字符串常量，所以这里比对的是 label / aliases 文本本身。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/modules/settings/settings_search_index.g.dart';

typedef SearchEntry =
    ({String label, String category, String subpage, String aliases});

/// 开关文案**逐字**（斜杠两侧各一个空格；少一个空格就是 §七 的旧文案探针）。
const String kLyricLabel = '显示CarWith / Jovi InCar歌词';
const String kThemeLabel = '跟随CarWith';

/// §七 要求成品 libapp.so 里 0 命中的旧文案/旧键名探针（**逐条都是 UI 串**，
/// 所以断言对象是索引文本：索引内容即设置页真实标题/别名，这里干净就等于
/// 编译产物干净）。
const List<String> kZeroHitProbes = [
  '跟随CarWith亮/暗模式切换主题',
  'CarWith连接时跟随日出日落切换主题',
  '主题模式跟随',
  '显示CarWith/Jovi InCar歌词',
  '车机歌词自检',
  '未连着CarWith',
  'settings_follow_sun_dark',
  '日出',
  '日落',
  '极圈地区',
  '定位成功',
  '跟随日出日落',
];

/// 源码层额外拦一遍的串：只放「旧 label / 旧键名」这类**不可能无害出现在
/// 注释里**的复合串。裸「日出」「日落」不列在这里 —— 注释里用它讲人话是允许的
/// （注释不进 libapp.so，不影响 §七 验收），拿它拦源码会误伤。
const List<String> kZeroHitSourceProbes = [
  '跟随CarWith亮/暗模式切换主题',
  'CarWith连接时跟随日出日落切换主题',
  '主题模式跟随',
  '显示CarWith/Jovi InCar歌词',
  '车机歌词自检',
  '未连着CarWith',
  'settings_follow_sun_dark',
  'settings_sun_location',
  'settings_sun_budget',
];

void main() {
  final root = Directory.current.path.replaceAll(r'\', '/');

  final settingsPageSource = File(
    '$root/lib/modules/settings/settings_page.dart',
  ).readAsStringSync();

  /// 索引里按 label 精确取条目（同名可能多条，如「桌面歌词外观」）。
  List<SearchEntry> byLabel(String label) =>
      kSettingsSearchIndex.where((e) => e.label == label).toList();

  /// 索引里全部可比对文本（label + aliases 逐条，不拼接）。
  List<String> indexTexts() =>
      kSettingsSearchIndex.expand((e) => [e.label, e.aliases]).toList();

  group('CarWith 两条索引条目存在且层级正确', () {
    test('歌词开关条目在索引里', () {
      expect(
        byLabel(kLyricLabel),
        hasLength(1),
        reason: '索引 label 必须与设置页开关文案逐字一致',
      );
    });

    test('歌词开关条目归属 歌词 › 设备歌词', () {
      final entry = byLabel(kLyricLabel).single;
      expect(entry.category, '歌词');
      expect(entry.subpage, '设备歌词');
    });

    test('主题条目 跟随CarWith 在索引里且归属 外观 › 主题与配色', () {
      final entry = byLabel(kThemeLabel).single;
      expect(entry.category, '外观');
      expect(entry.subpage, '主题与配色');
    });

    test('两条都带别名，且别名含用户最可能输入的「车机」', () {
      for (final label in const [kLyricLabel, kThemeLabel]) {
        final entry = byLabel(label).single;
        expect(entry.aliases, isNotEmpty, reason: '$label 需要别名才搜得到');
        expect(
          entry.aliases,
          contains('车机'),
          reason: '$label 的别名应覆盖「车机」这一入口词',
        );
      }
    });
  });

  group('按平台过滤（索引为编译期常量，过滤在消费端）', () {
    test('过滤名单恰好覆盖这两条，且文案与索引逐字一致', () {
      expect(
        kCarWithOnlySearchLabels,
        equals(const {kLyricLabel, kThemeLabel}),
      );
      for (final label in kCarWithOnlySearchLabels) {
        expect(
          byLabel(label),
          isNotEmpty,
          reason: '过滤名单里的「$label」必须在索引里真实存在，'
              '否则名单本身写错了字（例如空格）也不会有人发现',
        );
      }
    });

    test('反向核对：索引里凡是 label 含 CarWith 的都进了过滤名单', () {
      // 防止将来新增车机条目时忘了同步名单，导致桌面端搜到不渲染的死条目。
      final carWithEntries = kSettingsSearchIndex
          .where((e) => e.label.toLowerCase().contains('carwith'))
          .toList();
      expect(carWithEntries, isNotEmpty, reason: '本测试不应空转');
      for (final entry in carWithEntries) {
        expect(
          kCarWithOnlySearchLabels.contains(entry.label),
          isTrue,
          reason: '「${entry.label}」是车机专属条目，必须列入'
              ' kCarWithOnlySearchLabels',
        );
      }
    });

    test('支持 CarWith 的平台：两条都应被放行', () {
      for (final label in const [kLyricLabel, kThemeLabel]) {
        expect(
          carWithEntryAllowed(byLabel(label).single, carWithSupported: true),
          isTrue,
          reason: '$label 在 Android 必须出现在搜索结果里',
        );
      }
    });

    test('不支持 CarWith 的平台：两条都应被过滤', () {
      for (final label in const [kLyricLabel, kThemeLabel]) {
        expect(
          carWithEntryAllowed(byLabel(label).single, carWithSupported: false),
          isFalse,
          reason: '$label 在桌面端整项不渲染，搜到就是死路',
        );
      }
    });

    test('过滤只针对这两条，其余条目一律放行', () {
      final allowed = kSettingsSearchIndex
          .where((e) => carWithEntryAllowed(e, carWithSupported: false))
          .length;
      expect(
        allowed,
        kSettingsSearchIndex.length - kCarWithOnlySearchLabels.length,
      );
    });
  });

  group('说明书 §七 的 0 命中探针不出现在索引里', () {
    for (final probe in kZeroHitProbes) {
      test('索引不含旧文案「$probe」', () {
        expect(
          indexTexts().where((t) => t.contains(probe)),
          isEmpty,
          reason: '「$probe」是成品验收要求 0 命中的探针串，'
              '不能出现在任何 label 或 aliases 里',
        );
      });
    }

    test('设置页源码不含旧 label / 旧键名一类的探针串', () {
      // 用 kZeroHitSourceProbes 而非 kZeroHitProbes：裸「日出」「日落」在注释里
      // 讲人话是允许的（注释不进 libapp.so，不影响 §七 验收），拿它拦源码会误伤。
      for (final probe in kZeroHitSourceProbes) {
        expect(
          settingsPageSource.contains(probe),
          isFalse,
          reason: '源码里留着「$probe」说明改名没改净',
        );
      }
    });
  });

  group('索引与设置页源码一致（同一份文案两处不分裂）', () {
    test('索引 label 来自设置页真实标题文本', () {
      for (final label in const [kLyricLabel, kThemeLabel]) {
        expect(
          settingsPageSource.contains("Text('$label')"),
          isTrue,
          reason: '「$label」在源码里找不到，说明控件标题被改走而索引没跟上'
              '（或反之）——请重新生成索引',
        );
      }
    });

    test('车机分组标签与说明文案符合说明书口径', () {
      // §七 要求的 UTF-16LE 文案「车机投屏歌词」（分组标签）
      expect(settingsPageSource.contains("'车机投屏歌词'"), isTrue);
      // 「跟随CarWith」的说明要提车机，且不用日出日落一类旧文案
      expect(
        settingsPageSource.contains('连接小米 CarWith 时跟随车机深浅色'),
        isTrue,
      );
    });
  });

  test('索引产物与源码同步（忘重新生成时在此失败）', () {
    final actual = File(
      '$root/lib/modules/settings/settings_search_index.g.dart',
    ).readAsStringSync();
    // 只核对这两条是否都在产物里（全量一致性由
    // settings_search_index_test.dart 用生成器逐字节比对，不在此重复）。
    expect(actual.contains("label: '$kLyricLabel'"), isTrue);
    expect(actual.contains("label: '$kThemeLabel'"), isTrue);
  });
}
