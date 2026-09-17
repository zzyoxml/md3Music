// 设置搜索索引一致性校验：产物必须与设置页源码同步。
//
// 新增或改名设置项后忘记重新生成索引时，本测试失败并给出生成命令。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../scripts/tools/gen_settings_search_index.dart';

void main() {
  test('settings_search_index.g.dart 与设置页源码一致', () {
    final root = Directory.current.path.replaceAll(r'\', '/');
    final expected = generateSettingsSearchIndexSource(projectRoot: root);
    final actual = File('$root/$kIndexOutputRelPath').readAsStringSync();
    expect(
      actual.replaceAll('\r\n', '\n'),
      expected.replaceAll('\r\n', '\n'),
      reason: '设置项有变动，请运行：'
          'dart run scripts/tools/gen_settings_search_index.dart',
    );
  });

  test('索引条目非空且字段完整', () {
    final root = Directory.current.path.replaceAll(r'\', '/');
    final entries = collectSettingsSearchEntries(projectRoot: root);
    expect(entries, isNotEmpty);
    for (final entry in entries) {
      expect(entry.label.trim(), isNotEmpty);
      expect(entry.category.trim(), isNotEmpty);
    }
  });
}
