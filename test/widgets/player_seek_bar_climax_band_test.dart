// 横屏常驻控制带的进度条**不得再画出第三条带**（回归）。
//
// 现象：横屏下「高潮进度显示错误且一直更新」。根因是给常驻带新加的缓冲就绪底带
// —— 它从播放头一路铺到 `bufferedPosition`，而流式播放时这个值基本顶到歌曲结尾，
// 于是整条剩余段都被铺成一条 8dp 的浅色带；它又比高潮带（描边约 3px）更粗，
// 视觉上就成了「被标错的高潮区」，并随缓冲推进每秒变动。
// 竖屏那条进度条没接这个数据源，所以只有横屏出问题。
//
// 这里静止态给了高潮区间，轨道上应当**只有三段**：未播段、高潮带、已播段。
// 任何一条额外的带子都会把这个数字顶上去。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/player_seek_bar.dart';

const Duration _duration = Duration(seconds: 100);

PlayerSeekBar _barWithClimax() => PlayerSeekBar(
  position: const Duration(seconds: 30),
  duration: _duration,
  isPlaying: false,
  md3Style: true,
  activeColor: Colors.blue,
  inactiveColor: Colors.grey,
  labelColor: Colors.black,
  // 高潮区间 60s–80s：静止（未播放、未拖动）时走直线粗带分支
  climaxStart: 60,
  climaxEnd: 80,
  // 常驻带档位开着刻度尺：静止态也不得画出刻线
  tickMarks: true,
);

Finder _canvas() => find.descendant(
  of: find.byType(PlayerSeekBar),
  matching: find.byWidgetPredicate(
    (w) =>
        w is CustomPaint &&
        (w.painter?.runtimeType.toString().contains('SeekBar') ?? false),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('静止态轨道只有三段：未播段 / 高潮带 / 已播段', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _barWithClimax())),
    );

    expect(
      tester.renderObject(_canvas()),
      paintsExactlyCountTimes(#drawRRect, 3),
      reason: '多出一条就是「看起来像高潮」的额外底带，横屏那次的成因',
    );
  });

  testWidgets('高潮带用的是高潮色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _barWithClimax())),
    );

    // PaintingMatcher 按调用顺序匹配：未播段在前，高潮带是第二段
    expect(
      tester.renderObject(_canvas()),
      paints
        ..rrect(color: Colors.grey)
        ..rrect(color: Colors.blue.withValues(alpha: 0.45)),
      reason: '高潮区应按既有高潮色绘制，紧跟在未播段之后',
    );
  });

  testWidgets('开着刻度尺时静止态不画任何刻线', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _barWithClimax())),
    );

    expect(tester.renderObject(_canvas()), isNot(paints..line()));
  });
}
