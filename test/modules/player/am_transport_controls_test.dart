// AM 传输控件测试：中央播放/暂停。
//
// 回归点：
// 1) 中央用 PlayPauseMorphIcon 双轨实心形变（参考小宇宙播放页按钮）；
// 2) 形变时长默认 280ms（参考视频实测约 350ms，取更快的手感）；
// 3) 没有白色实心圆底（不是 IconButton.filled）；
// 4) 点击只回调一次 onPlayPause；
// 5) 上一曲/下一曲仍是 iconic_morph 描边重绘。
import 'package:flutter_test/flutter_test.dart';
import 'package:iconic_morph/iconic_morph.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/modules/player/am_transport_controls.dart';
import 'package:md3music/modules/player/widgets/play_pause_morph_icon.dart';

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

  testWidgets('默认形变时长 280ms', (tester) async {
    await tester.pumpWidget(host(isPlaying: false));
    await tester.pump();

    final controls = tester.widget<AMTransportControls>(
      find.byType(AMTransportControls),
    );
    expect(controls.morphDuration, const Duration(milliseconds: 280));
  });

  testWidgets('中央用 PlayPauseMorphIcon 实心形变（白色、54、跟随 isPlaying）',
      (tester) async {
    await tester.pumpWidget(host(isPlaying: true));
    await tester.pump();

    final icon = tester.widget<PlayPauseMorphIcon>(
      find.byType(PlayPauseMorphIcon),
    );
    expect(icon.isPlaying, isTrue);
    expect(icon.color, Colors.white);
    expect(icon.size, 54);
  });

  testWidgets('中央按钮没有实心圆底色', (tester) async {
    await tester.pumpWidget(host(isPlaying: false));
    await tester.pumpAndSettle();

    final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
    final middle = buttons.elementAt(1);
    expect(
      middle.style?.backgroundColor?.resolve(<WidgetState>{}),
      isNull,
      reason: '播放/暂停不使用 IconButton.filled 的白色圆底',
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

  testWidgets('上一曲/下一曲仍是 IconicAnimatedIcon 描边动画', (tester) async {
    await tester.pumpWidget(host(isPlaying: false));
    await tester.pumpAndSettle();

    expect(find.byType(IconicAnimatedIcon), findsNWidgets(2));
    expect(find.byType(PlayPauseMorphIcon), findsOneWidget);
  });
}
