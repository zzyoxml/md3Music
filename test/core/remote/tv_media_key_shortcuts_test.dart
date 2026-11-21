// TvMediaKeyShortcuts 的键位契约测试。
//
// 为什么必须有页级包装：app.dart 的根部兜底 _tvMediaKeyFallback 把 5 个媒体键
// 一律绑成 VoidCallback，即使没有音频（currentSong == null）也会吞键；
// 刷刷竖屏流/MV 的视频播放器不走 PlayerProvider，只有比根部更深的
// CallbackShortcuts 先赢才能把键位改道给页内视频。
//
// 组件本身不带 kTvBuild 门控（与 TvMenuKeyShortcuts 同惯例），
// 普通 flutter test 即可钉住行为。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/remote/tv_media_key_shortcuts.dart';

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onPlayPause,
  VoidCallback? onPlay,
  VoidCallback? onPause,
  VoidCallback? onNext,
  VoidCallback? onPrevious,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TvMediaKeyShortcuts(
        onPlayPause: onPlayPause,
        onPlay: onPlay,
        onPause: onPause,
        onNext: onNext,
        onPrevious: onPrevious,
        // 按键事件从 primaryFocus 向**外**冒泡：child 里必须有一个可聚焦节点
        // 位于 CallbackShortcuts 之下，否则焦点落在根 scope（其祖先），
        // 本页级包装根本收不到键。真机上焦点始终在页内控件上，等价于此。
        child: const Focus(
          autofocus: true,
          child: Placeholder(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('5 个媒体键各自命中对应回调', (tester) async {
    final hits = <String, int>{};
    void bump(String k) => hits[k] = (hits[k] ?? 0) + 1;

    await _pump(
      tester,
      onPlayPause: () => bump('playPause'),
      onPlay: () => bump('play'),
      onPause: () => bump('pause'),
      onNext: () => bump('next'),
      onPrevious: () => bump('prev'),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackPrevious);
    await tester.pumpAndSettle();

    expect(hits, {
      'playPause': 1,
      'play': 1,
      'pause': 1,
      'next': 1,
      'prev': 1,
    });
  });

  testWidgets('传 null 的键不登记绑定，按键穿透不报错', (tester) async {
    var played = 0;
    await _pump(tester, onPlay: () => played++);

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
    await tester.pumpAndSettle();

    expect(played, 1, reason: '已绑定的键照常命中');
  });

  testWidgets('全部为 null 时零包装（child 原样挂载）', (tester) async {
    await _pump(tester);
    expect(find.byType(CallbackShortcuts), findsNothing);
    expect(find.byType(Placeholder), findsOneWidget);
  });
}
