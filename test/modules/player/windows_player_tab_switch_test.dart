import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m3;
import 'package:md3music/modules/player/player_tab_pager.dart';
import 'package:md3music/widgets/player_tab_strip.dart';

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.reduceMotion,
    this.lightweightSwitch = true,
  });
  final bool reduceMotion;
  final bool lightweightSwitch;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with TickerProviderStateMixin {
  late final m3.TabController controller = m3.TabController(
    length: 3,
    vsync: this,
  );
  final pagerKey = GlobalKey<PlayerTabPagerState>();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: widget.reduceMotion),
    child: Scaffold(
      body: Column(
        children: [
          PlayerTabStrip(
            controller: controller,
            items: const [
              PlayerTabItem(icon: Icons.queue_music, label: '播放列表'),
              PlayerTabItem(icon: Icons.lyrics, label: '歌词'),
              PlayerTabItem(icon: Icons.comment, label: '评论'),
            ],
            activeColor: Colors.blue,
            inactiveColor: Colors.grey,
            instantDesktopTap: widget.lightweightSwitch,
          ),
          Expanded(
            child: PlayerTabPager(
              key: pagerKey,
              tabController: controller,
              lightweightDesktopSwitch: widget.lightweightSwitch,
              children: const [Text('queue'), Text('lyrics'), Text('comments')],
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('Windows 点击落页后淡入160ms，减少动态效果时直接到位', (tester) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(home: _Harness(key: key, reduceMotion: false)),
    );
    await tester.tap(find.bySemanticsLabel('歌词'));
    await tester.pump();
    expect(key.currentState!.controller.index, 1);
    expect(key.currentState!.pagerKey.currentState!.page, 1);
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('desktop-player-tab-fade')),
          )
          .opacity
          .value,
      closeTo(0.8, 0.01),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('desktop-player-tab-fade')),
          )
          .opacity
          .value,
      1,
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(
      MaterialApp(home: _Harness(key: key, reduceMotion: true)),
    );
    await tester.tap(find.bySemanticsLabel('评论'));
    await tester.pump();
    expect(key.currentState!.controller.index, 2);
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('desktop-player-tab-fade')),
          )
          .opacity
          .value,
      1,
    );
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('跨页评论直达且快速再点重启淡入；非轻量路径仍跟手滑动', (tester) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(home: _Harness(key: key, reduceMotion: false)),
    );
    await tester.tap(find.bySemanticsLabel('评论'));
    await tester.pump(const Duration(milliseconds: 48));
    expect(key.currentState!.controller.index, 2);
    expect(key.currentState!.pagerKey.currentState!.page, 2);
    await tester.tap(find.bySemanticsLabel('歌词'));
    await tester.pump();
    expect(key.currentState!.controller.index, 1);
    expect(key.currentState!.pagerKey.currentState!.page, 1);
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('desktop-player-tab-fade')),
          )
          .opacity
          .value,
      closeTo(0.8, 0.01),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('desktop-player-tab-fade')),
          )
          .opacity
          .value,
      1,
    );
    await tester.pump(const Duration(milliseconds: 300));

    final animatedKey = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _Harness(
          key: animatedKey,
          reduceMotion: false,
          lightweightSwitch: false,
        ),
      ),
    );
    expect(
      animatedKey.currentState!.pagerKey.currentState!.viewportWidth,
      greaterThan(0),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('queue')),
    );
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    final draggedPage = animatedKey.currentState!.pagerKey.currentState!.page;
    expect(draggedPage, greaterThan(0));
    expect(draggedPage, lessThan(1));
    await gesture.moveBy(const Offset(-500, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(animatedKey.currentState!.pagerKey.currentState!.page, 1);
  });

  test('Windows 两版播放页页签点击均走即时落页，非桌面仍保留 animateTo', () {
    final root =
        Platform.environment['PLAYER_SOURCE_ROOT'] ?? Directory.current.path;
    String source(String relativePath) => File(
      '$root${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
    ).readAsStringSync();
    final strip = source('lib/widgets/player_tab_strip.dart');
    final md3 = source('lib/modules/player/full_player.dart');
    final am = source('lib/modules/player/full_player_am.dart');

    expect(
      strip,
      contains(
        'if (instantDesktopTap) {\n              controller.index = index;',
      ),
    );
    expect(strip, contains('controller.animateTo(index);'));
    expect(md3, contains('instantDesktopTap: isWindowsDesktop,'));
    expect(am, contains('instantDesktopTap: isWindowsDesktop,'));
    expect(md3, contains('lightweightDesktopSwitch: isWindowsDesktop,'));
    expect(am, contains('lightweightDesktopSwitch: isWindowsDesktop,'));
    expect(
      source('lib/modules/player/player_tab_pager.dart'),
      contains('Tween<double>(begin: 0.8, end: 1)'),
    );
    expect(
      RegExp(r'sheetAnimationStyle: isWindowsDesktop').allMatches(md3).length,
      2,
    );
    expect(
      RegExp(r'sheetAnimationStyle: isWindowsDesktop').allMatches(am).length,
      2,
    );
    expect(md3, contains('MediaQuery.disableAnimationsOf(rootContext)'));
    expect(am, contains('MediaQuery.disableAnimationsOf(rootContext)'));
  });
}
