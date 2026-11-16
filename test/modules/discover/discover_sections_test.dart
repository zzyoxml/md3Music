import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/modules/discover/discover_sections.dart';
import 'package:md3music/data/models/album.dart';
import 'package:md3music/widgets/compact_album_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _layout(DiscoverSectionConfig config, VoidCallback onEdit, {Widget? status}) =>
    MaterialApp(home: Scaffold(body: CustomScrollView(slivers: [
      DiscoverSectionsSliver(
        config: config, onEdit: onEdit, status: status,
        sectionBuilder: (section) => SliverToBoxAdapter(child: SizedBox(
          key: ValueKey('cell-${section.name}'),
          height: section == DiscoverSection.personalFm ? 120 : 260,
          child: Text(section.label),
        )),
      ),
    ])));

Finder _cell(DiscoverSection section) => find.byKey(ValueKey('cell-${section.name}'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认前三项开启，新歌与新碟关闭；与 Tab 配置隔离', () async {
    final config = await DiscoverSectionConfig.load();
    expect(config.visible, DiscoverSection.values.take(3).toList());
    expect(config.order, DiscoverSection.values);
    await config.toggle(DiscoverSection.newSongs).save();
    final restored = await DiscoverSectionConfig.load();
    expect(restored.hidden, {DiscoverSection.newAlbums});
    expect((await SharedPreferences.getInstance()).getKeys(), {DiscoverSectionConfig.preferenceKey});
  });

  test('发现页管理弹层跟随内容高度并受屏幕高度限制', () {
    expect(discoverSectionManagerSheetHeight(720), 440);
    expect(discoverSectionManagerSheetHeight(300), 255);
  });

  test('发现页新碟预览可显示八张，其它紧凑专辑网格仍默认为六张', () {
    const albums = <Album>[];
    final discoverPreview = CompactAlbumGrid(
      albums: albums, onTap: (_) {}, regionKey: 'discover-preview', maxItems: 8,
    );
    final defaultGrid = CompactAlbumGrid(
      albums: albums, onTap: (_) {}, regionKey: 'default-preview',
    );
    expect(discoverPreview.maxItems, 8);
    expect(defaultGrid.maxItems, 6);
  });

  test('上下拖动语义正确，顺序与开关作为同一快照跨重载保留', () async {
    var config = const DiscoverSectionConfig(hidden: {});
    config = config.reorder(4, 1).toggle(DiscoverSection.daily);
    await config.save();
    final loaded = await DiscoverSectionConfig.load();
    expect(loaded.order[1], DiscoverSection.newAlbums);
    expect(loaded.hidden, {DiscoverSection.daily});
    final movedDown = loaded.reorder(1, 5);
    expect(movedDown.order.last, DiscoverSection.newAlbums);
    expect(movedDown.reorder(-1, 0), same(movedDown));
    expect(movedDown.reorder(0, 6), same(movedDown));
  });

  test('旧配置去重、忽略无效 ID，并将新碟等缺失区块补到末尾', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DiscoverSectionConfig.preferenceKey, jsonEncode({
      'order': ['newSongs', 'deleted', 'newSongs', 'daily'],
      'hidden': ['deleted', 'daily'],
    }));
    final config = await DiscoverSectionConfig.load();
    expect(config.order.take(2), [DiscoverSection.newSongs, DiscoverSection.daily]);
    expect(config.order.toSet(), DiscoverSection.values.toSet());
    expect(config.order.length, 5);
    expect(config.hidden, {DiscoverSection.daily});
    await prefs.setString(DiscoverSectionConfig.preferenceKey, '{bad json');
    expect((await DiscoverSectionConfig.load()).visible, DiscoverSection.values.take(3).toList());
  });

  test('还原所有设置清除发现页配置但保留登录状态', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await const DiscoverSectionConfig(hidden: {DiscoverSection.daily}).save();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kugou_current_userid', 'fixture-user');
    await SettingsRepository().resetAllSettingsToDefaults();
    expect(prefs.containsKey(DiscoverSectionConfig.preferenceKey), isFalse);
    expect(prefs.getString('kugou_current_userid'), 'fixture-user');
    expect((await DiscoverSectionConfig.load()).visible, DiscoverSection.values.take(3).toList());
  });

  testWidgets('宽屏保持 FM 整行，四块内容左右等宽配对；编辑只在页尾出现', (tester) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var edits = 0;
    await tester.pumpWidget(_layout(const DiscoverSectionConfig(hidden: {}), () => edits++));
    await tester.pumpAndSettle();
    final daily = tester.getRect(_cell(DiscoverSection.daily));
    final home = tester.getRect(_cell(DiscoverSection.homeDiscover));
    final songs = tester.getRect(_cell(DiscoverSection.newSongs));
    final albums = tester.getRect(_cell(DiscoverSection.newAlbums));
    expect(tester.getSize(_cell(DiscoverSection.personalFm)).width, 1200);
    expect(daily.width, 600);
    expect(home.width, 600);
    expect(daily.top, home.top);
    expect(songs.top, albums.top);
    expect(songs.width, albums.width);
    expect(albums.left, 600);
    final edit = find.byKey(const ValueKey('discover-edit'));
    expect(edit.hitTestable(), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(edit.hitTestable(), findsOneWidget);
    await tester.tap(edit);
    expect(edits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏单列，隐藏后不留空位；FM 换位仍占整行', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final config = const DiscoverSectionConfig(hidden: {}).reorder(0, 4).toggle(DiscoverSection.homeDiscover);
    await tester.pumpWidget(_layout(config, () {}));
    await tester.pumpAndSettle();
    expect(_cell(DiscoverSection.homeDiscover), findsNothing);
    expect(tester.getSize(_cell(DiscoverSection.daily)).width, 390);
    expect(tester.getRect(_cell(DiscoverSection.newSongs)).top,
        greaterThan(tester.getRect(_cell(DiscoverSection.daily)).top));
    expect(tester.getSize(_cell(DiscoverSection.personalFm)).width, 390);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部关闭或加载失败仍能进入编辑，不会锁死布局', (tester) async {
    await tester.pumpWidget(_layout(
      DiscoverSectionConfig(hidden: DiscoverSection.values.toSet()), () {},
      status: const Text('加载中'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('加载中'), findsNothing);
    expect(find.byKey(const ValueKey('discover-edit')).hitTestable(), findsOneWidget);
    await tester.pumpWidget(_layout(const DiscoverSectionConfig(), () {}, status: const Text('网络错误')));
    await tester.pumpAndSettle();
    expect(find.text('网络错误'), findsOneWidget);
    expect(find.byKey(const ValueKey('discover-edit')).hitTestable(), findsOneWidget);
  });

  testWidgets('管理面板沿用 M3E 排序与开关，立即保存；重置恢复截图默认开关', (tester) async {
    var config = const DiscoverSectionConfig(hidden: {});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DiscoverSectionManager(
      config: config,
      onChanged: (next) async { config = next; await next.save(); },
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(M3EReorderableDismissibleList), findsOneWidget);
    final albumRow = find.byKey(const ValueKey('discover-manager-newAlbums'));
    await tester.tap(find.descendant(of: albumRow, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect((await DiscoverSectionConfig.load()).hidden, {DiscoverSection.newAlbums});
    final list = tester.widget<M3EReorderableDismissibleList>(find.byType(M3EReorderableDismissibleList));
    list.onReorder(4, 1);
    await tester.pumpAndSettle();
    expect((await DiscoverSectionConfig.load()).order[1], DiscoverSection.newAlbums);
    expect(config.hidden, {DiscoverSection.newAlbums});
    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(config.visible, DiscoverSection.values.take(3).toList());
    expect((await DiscoverSectionConfig.load()).visible, DiscoverSection.values.take(3).toList());
    expect(tester.takeException(), isNull);
  });
}
