import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/discover/discover_sections.dart';

Widget layout({TargetPlatform platform = TargetPlatform.android}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: Scaffold(body: CustomScrollView(slivers: [DiscoverSectionsSliver(
    config: const DiscoverSectionConfig(hidden: {}), onEdit: () {},
    sectionBuilder: (section) => SliverToBoxAdapter(child: SizedBox(
      key: ValueKey(section.name), height: 100)),
  )])),
);

void main() {
  for (final width in [680.0, 719.0, 720.0, 855.0, 1200.0]) {
    testWidgets('大屏内容宽 $width 时按实际面板宽度排列', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: SizedBox.expand(child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: layout()),
      ))));
      await tester.pumpAndSettle();
      final songs = tester.getRect(find.byKey(const ValueKey('newSongs')));
      final albums = tester.getRect(find.byKey(const ValueKey('newAlbums')));
      final paired = width >= 720;
      expect(songs.width, paired ? width / 2 : width);
      expect(albums.top, paired ? songs.top : songs.bottom);
      if (paired) expect(albums.width, greaterThanOrEqualTo(360));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('手机横屏保持原 600dp 并排断点', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(680, 390);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(layout());
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('newSongs'))).width, 340);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Windows 矮窗口不误判为手机横屏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(680, 390);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(layout(platform: TargetPlatform.windows));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('newSongs'))).width, 680);
    expect(tester.takeException(), isNull);
  });
}
