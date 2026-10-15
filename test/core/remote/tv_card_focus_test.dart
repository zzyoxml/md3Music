// TvCardFocus 的遥控契约测试。
//
// 背景（2026-10-08 真机）：频道详情页「相似频道」带、场景专区「音乐/歌单/视频」
// 标签带都只包了 TvScrollRegion（区域语义），卡片本身是裸 InkWell ——
// 上面的行能落焦点、带里的卡片完全选不中。修复口径是每个可点卡片一个
// DpadFocusable 单停点（AGENTS §0.5）。
//
// kTvBuild 是编译期常量（普通 flutter test 里恒 false），两组用例用 skip 互斥：
// TV 契约需单跑
//   flutter test test/core/remote/tv_card_focus_test.dart --dart-define=MD3_TV=true

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/remote/tv_card_focus.dart';
import 'package:md3music/core/remote/tv_scroll_region.dart';

Widget _band({
  required FocusNode first,
  required FocusNode second,
  required List<VoidCallback> taps,
}) {
  Widget card(int i, FocusNode node, VoidCallback onTap) => TvCardFocus(
    focusNode: node,
    debugLabel: 'card_$i',
    onSelect: onTap,
    child: SizedBox(
      width: 80,
      height: 80,
      child: InkWell(onTap: onTap, child: const ColoredBox(color: Color(0xFF808080))),
    ),
  );

  return MaterialApp(
    builder: Dpad.wrap(theme: const DpadThemeData()),
    // Scaffold 提供 Material 祖先：InkWell 缺它会直接抛「No Material widget found」
    home: Scaffold(
      body: SizedBox(
        height: 100,
        child: TvScrollRegion(
          memoryKey: 'tv/test-band',
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              card(0, first, taps[0]),
              card(1, second, taps[1]),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('非 TV 构建：原样透传 child，不产生 DpadFocusable', (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(
      _band(
        first: first,
        second: second,
        taps: [() {}, () {}],
      ),
    );

    expect(find.byType(TvCardFocus), findsNWidgets(2));
    // kTvBuild 为 const false：DpadFocusable 不应进入元素树
    expect(find.byType(DpadFocusable), findsNothing);
    expect(find.byType(DpadRegion), findsNothing);
  }, skip: kTvBuild);

  group('TV 构建（MD3_TV=true）', () {
    testWidgets('左右键在带内换卡，OK 触发 onSelect 恰好一次', (tester) async {
      final first = FocusNode(debugLabel: 'first');
      final second = FocusNode(debugLabel: 'second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final taps = <int>[0, 0];

      await tester.pumpWidget(
        _band(first: first, second: second, taps: [
          () => taps[0]++,
          () => taps[1]++,
        ]),
      );
      await tester.pumpAndSettle();

      first.requestFocus();
      await tester.pumpAndSettle();
      expect(first.hasFocus, isTrue, reason: '前置条件：焦点在第一张卡');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(second.hasFocus, isTrue,
          reason: '裸 InkWell 卡接了 TvCardFocus 后必须成为可落焦的停点');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(taps[1], 1, reason: 'OK 走 DpadFocusable.onSelect，恰好一次');
      expect(taps[0], 0, reason: '不得误触发相邻卡的动作');
    });

    testWidgets('内层 InkWell 不产生第二个停点（excludeChildFocus 默认 true）',
        (tester) async {
      final first = FocusNode(debugLabel: 'first');
      final second = FocusNode(debugLabel: 'second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await tester.pumpWidget(_band(first: first, second: second, taps: [
        () {},
        () {},
      ]));
      await tester.pumpAndSettle();
      first.requestFocus();
      await tester.pumpAndSettle();

      // dpad 在 excludeChildFocus 为 true 时用 ExcludeFocus 挡掉整个子树，
      // 内层 InkWell 的焦点节点因此不可能成为第二个落点。
      for (final stop in find.byType(DpadFocusable).evaluate()) {
        expect(
          find.descendant(
            of: find.byWidget(stop.widget),
            matching: find.byType(ExcludeFocus),
          ),
          findsWidgets,
          reason: '每张卡必须自带 ExcludeFocus，否则一张卡两个停点',
        );
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus,
        same(second),
        reason: '右键必须精确落在下一张卡的停点上（中间没有 InkWell 停点）',
      );
    });
  }, skip: !kTvBuild);
}
