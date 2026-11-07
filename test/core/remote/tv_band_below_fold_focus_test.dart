// tv: 「横向卡片带能否被方向键进入」的定案与回归测试（2026-10-08）。
//
// 真机现象：频道详情页「相似频道」带、场景专区「音乐/歌单/视频」标签带，
// 上方的行能选、带里的卡片怎么都落不下焦点；给卡片补上 DpadFocusable 之后**仍然**落不下。
//
// 定案（读 dpad 3.0.0 `traversal.dart:65-71` + 本测试的 A~D 四组对照）：
// dpad 的方向搜索只比**同一个 DpadRegion 的成员**，而每个 Tab 的内容都被
// `responsive_shell` 包了一层 `verticalEdge/horizontalEdge: stop` 的 DpadRegion
// （为了在边缘把焦点桥接给导航栏 / FAB / 常驻播放条）。卡片带自己的
// TvScrollRegion 因此成了屏障：从带外的行按「下」，tab 区域内没有候选 →
// 直接走 stop 分支吃掉按键，**根本不会做跨区域搜索** → 焦点永远留在原行。
//
// 修复：`lib/core/remote/tv_edge_nested_handoff.dart` 的 focusNestedRegionBeyond，
// 在 onEdge 的第一步先找「别的区域里、该方向上最近」的候选并移交。
// 下面 C/D 两组即钉这条链路（E 组钉住：确实没有候选时，原有的播放条桥接不能被抢掉）。
//
// 跑法（kTvBuild 为编译期常量）：
//   flutter test test/core/remote/tv_band_below_fold_focus_test.dart --dart-define=MD3_TV=true

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/remote/tv_card_focus.dart';
import 'package:md3music/core/remote/tv_edge_nested_handoff.dart';
import 'package:md3music/core/remote/tv_scroll_region.dart';

String _focusLabel() {
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return '<null>';
  if (node is FocusScopeNode) return '<scope>';
  return node.debugLabel ?? '<unlabeled>';
}

/// 页面：若干占位高度 + 可聚焦行 + 一条横向卡片带（可省略，用于 E 组）。
Widget _page({required double headerHeight, required List<FocusNode> rowNodes, required int cards}) {
  return ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      SizedBox(height: headerHeight),
      for (var i = 0; i < rowNodes.length; i++)
        ListTile(
          focusNode: rowNodes[i],
          title: Text('row $i'),
          onTap: () {},
        ),
      if (cards > 0) ...[
        const SizedBox(height: 12),
        SizedBox(
          height: 130,
          child: TvScrollRegion(
            memoryKey: 'tv/band',
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: cards,
              itemBuilder: (context, i) => TvCardFocus(
                onSelect: () {},
                debugLabel: 'band-card-$i',
                child: SizedBox(
                  width: 110,
                  height: 110,
                  child: InkWell(
                    onTap: () {},
                    child: Container(color: Colors.blue),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

/// 与 responsive_shell 的 TV 分支同参数地包一层 tab 区域，onEdge 先走跨区域移交，
/// 没移交成功再落到「播放条桥接」（这里用一个 scope 外的可聚焦节点代替）。
Future<void> pumpPage(
  WidgetTester tester, {
  required double headerHeight,
  int rows = 3,
  int cards = 6,
  required List<TraversalDirection> handoffs,
}) async {
  final rowNodes = <FocusNode>[
    for (var i = 0; i < rows; i++) FocusNode(debugLabel: 'row-$i'),
  ];
  final playerBar = FocusNode(debugLabel: 'player-bar'); // 模拟 tab scope 之外的常驻播放条
  addTearDown(() {
    for (final n in rowNodes) {
      n.dispose();
    }
    playerBar.dispose();
  });

  await tester.pumpWidget(
    MaterialApp(
      builder: Dpad.wrap(
        theme: const DpadThemeData(
          effects: [DpadGlowEffect()],
          scrollPadding: 64,
        ),
      ),
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: DpadRegion(
                memoryKey: 'tv/tab-x',
                horizontalEdge: DpadEdgeBehavior.stop,
                verticalEdge: DpadEdgeBehavior.stop,
                onEdge: (direction) {
                  final primary = FocusManager.instance.primaryFocus;
                  if (primary != null &&
                      focusNestedRegionBeyond(primary, direction)) {
                    return;
                  }
                  handoffs.add(direction);
                  playerBar.requestFocus();
                },
                child: _page(
                  headerHeight: headerHeight,
                  rowNodes: rowNodes,
                  cards: cards,
                ),
              ),
            ),
            // 常驻播放条在 tab 的 Navigator scope 之外（这里是兄弟子树），
            // 因此 focusNestedRegionBeyond 永远找不到它，不会被抢焦。
            Focus(
              focusNode: playerBar,
              child: const SizedBox(
                width: 100,
                height: 40,
                child: ColoredBox(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  rowNodes.last.requestFocus();
  await tester.pumpAndSettle();
}

Future<void> pressDown(WidgetTester tester, {int times = 6}) async {
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    if (_focusLabel().startsWith('band-card')) return;
  }
}

void main() {
  group('TV 构建（MD3_TV=true）：横向卡片带必须能被方向键进入', () {
  testWidgets('C 带在首屏外（tab 区域 stop + 移交）：按「下」应滚出来并进带',
      (tester) async {
    final handoffs = <TraversalDirection>[];
    await pumpPage(tester, headerHeight: 350, handoffs: handoffs);
    expect(_focusLabel(), 'row-2');

    await pressDown(tester);
    expect(_focusLabel(), startsWith('band-card'),
        reason: '移交前 onEdge 会先把焦点交给播放条；焦点停在行上=屏障未解除');
  });

  testWidgets('D 带已完整在视口内（tab 区域 stop + 移交）：按「下」直接进带',
      (tester) async {
    final handoffs = <TraversalDirection>[];
    await pumpPage(tester, headerHeight: 100, handoffs: handoffs);
    expect(_focusLabel(), 'row-2');

    await pressDown(tester);
    expect(_focusLabel(), startsWith('band-card'));
    expect(handoffs, isEmpty, reason: '有可移交候选时不该再走播放条桥接');
  });

  testWidgets('E 页面没有嵌套区域：边缘仍按原样交给常驻播放条', (tester) async {
    final handoffs = <TraversalDirection>[];
    await pumpPage(tester, headerHeight: 100, cards: 0, handoffs: handoffs);
    expect(_focusLabel(), 'row-2');

    await pressDown(tester, times: 2);
    expect(handoffs, contains(TraversalDirection.down),
        reason: '没有别的区域的候选时，stop 边缘的原桥接必须照常发生');
    expect(_focusLabel(), 'player-bar');
  });

  testWidgets('D 对照组：不接移交（线上原行为）时焦点卡在最后一行', (tester) async {
    // 定案用的负向用例：去掉 focusNestedRegionBeyond 这一步，现象与真机一致。
    final rowNodes = <FocusNode>[
      for (var i = 0; i < 3; i++) FocusNode(debugLabel: 'row-$i'),
    ];
    addTearDown(() {
      for (final n in rowNodes) {
        n.dispose();
      }
    });
    final handoffs = <TraversalDirection>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: Scaffold(
          body: DpadRegion(
            memoryKey: 'tv/tab-y',
            verticalEdge: DpadEdgeBehavior.stop,
            horizontalEdge: DpadEdgeBehavior.stop,
            onEdge: handoffs.add,
            child: _page(headerHeight: 100, rowNodes: rowNodes, cards: 6),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    rowNodes.last.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusLabel(), 'row-2', reason: '没有跨区域移交 → 按键被 stop 吃掉');
    expect(handoffs, contains(TraversalDirection.down));
  });
  }, skip: !kTvBuild);
}
