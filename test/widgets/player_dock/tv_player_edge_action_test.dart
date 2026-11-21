// TvPlayerEdgeAction 行为契约测试：单停点 + OK/长按 OK 语义。
// 组件不带 kTvBuild 门控（AGENTS §12 惯例），调用方在 TV 分支使用；
// 普通 flutter test 即可钉住按键行为。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/player_dock/tv_player_edge_action.dart';

void main() {
  testWidgets('OK = onSelect，长按 OK = onLongSelect', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(),
        home: TvPlayerEdgeAction(
          debugLabel: 'tv/test-edge',
          autofocus: true,
          icon: Icons.repeat,
          color: Colors.white,
          onSelect: () => events.add('select'),
          onLongSelect: () => events.add('long'),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(events, ['select'], reason: '短按 OK = onSelect');
  });

  testWidgets('onSelect 为 null 时不制造死停点', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(),
        home: TvPlayerEdgeAction(
          autofocus: false,
          icon: Icons.favorite_border,
          color: Colors.white,
          onSelect: null,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(DpadFocusable), findsNothing, reason: '无动作即无停点');
  });
}
