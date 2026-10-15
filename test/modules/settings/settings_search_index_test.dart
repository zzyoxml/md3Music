// 设置搜索索引一致性校验：产物必须与设置页源码同步。
//
// 新增或改名设置项后忘记重新生成索引时，本测试失败并给出生成命令。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../scripts/tools/gen_settings_search_index.dart';

void main() {
  final root = Directory.current.path.replaceAll(r'\', '/');

  test('settings_search_index.g.dart 与设置页源码一致', () {
    final expected = generateSettingsSearchIndexSource(projectRoot: root);
    final actual = File('$root/$kIndexOutputRelPath').readAsStringSync();
    expect(
      actual.replaceAll('\r\n', '\n'),
      expected.replaceAll('\r\n', '\n'),
      reason: '设置项有变动，请运行：'
          'dart run scripts/tools/gen_settings_search_index.dart',
    );
  });

  test('索引条目非空且四元组字段完整', () {
    final entries = collectSettingsSearchEntries(projectRoot: root);
    expect(entries, isNotEmpty);
    for (final entry in entries) {
      expect(entry.label.trim(), isNotEmpty);
      expect(entry.category.trim(), isNotEmpty);
      // subpage 允许为空串（二级页内联项），但不允许 null
      expect(entry.subpage, isA<String>());
      expect(entry.aliases, isA<String>());
    }
  });

  test('未下钻分类的设置项 subpage 一律为空串', () {
    final entries = collectSettingsSearchEntries(projectRoot: root);
    for (final entry in entries.where(
      (e) => e.category == '缓存与数据' || e.category == '关于',
    )) {
      expect(entry.subpage, isEmpty, reason: '${entry.label} 不应带三级页归属');
    }
  });
}
