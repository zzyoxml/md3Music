// 「歌词位置」设置项的可搜索性与持久化契约。
//
// 与 lyric_aux_scope_settings_test.dart 同口径：不 pump SettingsPage
// （该页初始化会拉起若干原生服务，留下与本设置项无关的 pending timer），
// tile 存在性由索引一致性测试保证。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/settings/settings_search_index.g.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  test('默认置左，且未知持久化值回退置左', () {
    expect(LyricPreferences.instance.lyricPosition, LyricPosition.left);
    expect(lyricPositionFromName(null), LyricPosition.left);
    expect(lyricPositionFromName('unknown'), LyricPosition.left);
    expect(lyricPositionFromName('center'), LyricPosition.center);
    expect(lyricPositionFromName('right'), LyricPosition.right);
  });

  test('三档分别写入并落盘，重新解析可还原', () async {
    final prefs = LyricPreferences.instance;
    // setter 对同值早退；先离开默认值，保证循环里的 left 也产生一次真实写入。
    await prefs.setLyricPosition(LyricPosition.right);
    for (final position in LyricPosition.values) {
      await prefs.setLyricPosition(position);
      expect(prefs.lyricPosition, position);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString('lyric_position'), position.name);
      expect(
        lyricPositionFromName(stored.getString('lyric_position')),
        position,
      );
    }
  });

  test('reset 后回到默认并清除持久化键', () async {
    final prefs = LyricPreferences.instance;
    await prefs.setLyricPosition(LyricPosition.right);
    await prefs.reset();
    expect(prefs.lyricPosition, LyricPosition.left);
    final stored = await SharedPreferences.getInstance();
    expect(stored.containsKey('lyric_position'), isFalse);
  });

  test('搜索索引收录歌词位置（歌词效果子页，含三档同义词）', () {
    final entry = kSettingsSearchIndex.firstWhere(
      (e) => e.label == '歌词位置',
    );
    expect(entry.category, '播放页样式');
    expect(entry.subpage, '歌词效果');
    for (final alias in <String>['置左', '居中', '置右', '对齐']) {
      expect(entry.aliases, contains(alias));
    }
  });
}
