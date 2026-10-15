// AM 传输控件测试：中央播放/暂停。
//
// 回归点：
// 1) 用的是新增的粗白描边资源 am_play_bold / am_pause_bold；
// 2) 描边 3.0（比上一首/下一首的 2.0 更粗），颜色为白；
// 3) **没有**白色实心圆底（不再是 IconButton.filled）；
// 4) 形变时长 200ms（此前 460ms，用户反馈"太慢"）；
// 5) 点击仍然只回调一次 onPlayPause。
import 'package:flutter_test/flutter_test.dart';
import 'package:iconic_morph/iconic_morph.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/modules/player/am_transport_controls.dart';

void main() {
  Widget host({required bool isPlaying, VoidCallback? onPlayPause}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: AMTransportControls(
            isPlaying: isPlaying,
            onPrevious: () {},
            onPlayPause: onPlayPause ?? () {},
            onNext: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('默认形变时长 200ms（此前 460ms 偏慢）', (tester) async {
    await tester.pumpWidget(host(isPlaying: false));
    await tester.pump();

    final controls = tester.widget<AMTransportControls>(
      find.byType(AMTransportControls),
    );
    expect(controls.morphDuration, const Duration(milliseconds: 200));
  });

  testWidgets('中央用粗白描边的 play↔pause 形变', (tester) async {
    await tester.pumpWidget(host(isPlaying: false));
    await tester.pump();

    final morph = tester.widget<IconicShapeMorph>(
      find.byType(IconicShapeMorph),
    );
    expect(morph.from, 'assets/icons/am_play_bold.svg');
    expect(morph.to, 'assets/icons/am_pause_bold.svg');
    expect(morph.strokeWidth, 3.0);
    expect(morph.color, Colors.white);
  });

  testWidgets('中央按钮没有实心圆底色', (tester) async {
    await tester.pumpWidget(host(isPlaying: false));
    await tester.pumpAndSettle();

    final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
    final middle = buttons.elementAt(1);
    expect(
      middle.style?.backgroundColor?.resolve(<WidgetState>{}),
      isNull,
      reason: '播放/暂停不再使用 IconButton.filled 的白色圆底',
    );
  });

  testWidgets('点击中央按钮回调 onPlayPause 一次', (tester) async {
    int calls = 0;
    await tester.pumpWidget(host(isPlaying: true, onPlayPause: () => calls++));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(IconButton).at(1));
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('播放中时中央形变以暂停态为静止帧', (tester) async {
    await tester.pumpWidget(host(isPlaying: true));
    await tester.pump();

    final morph = tester.widget<IconicShapeMorph>(
      find.byType(IconicShapeMorph),
    );
    expect(morph.autoplay, isTrue);
  });
}
