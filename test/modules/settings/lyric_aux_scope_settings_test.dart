import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/settings/settings_search_index.g.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_aux_scope.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';

/// 「副行显示范围」设置项的可搜索性与持久化契约。
///
/// 不在此处 pump `SettingsPage`：该页初始化会拉起若干原生服务（如
/// `DesktopLyricService` 的周期探针），测试结束时留下 pending timer，与
/// 本设置项无关。三项 tile 的存在性由 `settings_search_index_test.dart` 的
/// 「索引与源码一致」校验保证——索引正是从源码里的字面量标题解析出来的，
/// 若有人删改这几项，索引比对会立刻失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  test('默认范围为「仅当前行」，且与设置页回退口径一致', () {
    expect(LyricPreferences.instance.auxScope, LyricAuxScope.currentLine);
    expect(auxScopeFromName(null), LyricAuxScope.currentLine);
  });

  test('三项分别写入并落盘，重新解析可还原', () async {
    final prefs = LyricPreferences.instance;
    for (final scope in <LyricAuxScope>[
      LyricAuxScope.allLines,
      LyricAuxScope.hidePlayed,
      LyricAuxScope.currentLine,
    ]) {
      await prefs.setAuxScope(scope);
      expect(prefs.auxScope, scope);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString('lyric_aux_scope'), scope.name);
      expect(auxScopeFromName(stored.getString('lyric_aux_scope')), scope);
    }
  });

  test('reset 后回到默认并清除持久化键', () async {
    final prefs = LyricPreferences.instance;
    await prefs.setAuxScope(LyricAuxScope.hidePlayed);
    await prefs.reset();
    expect(prefs.auxScope, LyricAuxScope.currentLine);
    final stored = await SharedPreferences.getInstance();
    expect(stored.containsKey('lyric_aux_scope'), isFalse);
  });

  test('搜索索引收录副行显示范围（歌词分类，含三档同义词）', () {
    // UI 已改为单行 M3E 字段式下拉（TvDropdownMenu），索引按 tile 标题收录，
    // 三档名（仅当前行 / 所有行 / 已播行除外）不再是独立 tile，而是 aliases
    // 同义词——搜索任一档名都能命中本项。
    final entry = kSettingsSearchIndex.firstWhere(
      (e) => e.label == '副行显示范围',
    );
    expect(entry.category, '歌词');
    expect(entry.aliases, contains('副行'));
    expect(entry.aliases, contains('翻译'));
    expect(entry.aliases, contains('所有行'));
    expect(entry.aliases, contains('已播'));
    expect(entry.aliases, contains('只显示当前'));

    final labels = kSettingsSearchIndex.map((e) => e.label).toSet();
    expect(labels, isNot(contains('仅当前行')), reason: '三档已并入下拉条目');
  });
}
