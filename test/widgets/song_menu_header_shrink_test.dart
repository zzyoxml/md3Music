// 菜单头封面收缩（「下一首播放」菜单内阶段）：终态正圆矩形 / 中途卸载兜底。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/widgets/song_menu_header.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final song = Song(
    id: 'shrink-target',
    title: '测试曲目',
    artist: '歌手',
    album: '专辑',
    duration: const Duration(minutes: 3),
    url: 'https://audio.invalid/shrink-target.mp3',
    isOnline: true,
  );

  Widget host(SongMenuHeaderShrinkController controller) => MaterialApp(
        home: Scaffold(
          body: SongMenuHeader(song: song, shrinkController: controller),
        ),
      );

  testWidgets('shrinkToCircle：封面收缩为 32×32 正圆，圆心在原 84 槽位中心',
      (tester) async {
    final controller = SongMenuHeaderShrinkController();
    await tester.pumpWidget(host(controller));
    await tester.pump();

    // 槽位中心取实测值：文字列含信息徽章行后行高自适应，
    // 封面 84 槽位在头部行内垂直居中，中心 y 不再是固定值。
    // 静止时内层动画 SizedBox 也是 84×84，取 .first（外层槽位，中心相同）。
    final slotCenter = tester.getCenter(
      find
          .byWidgetPredicate(
            (w) => w is SizedBox && w.width == 84.0 && w.height == 84.0,
          )
          .first,
    );

    final future = controller.shrinkToCircle();
    await tester.pump(const Duration(milliseconds: 250)); // 测试时钟：首个 tick 只建立动画基线
    await tester.pump(const Duration(milliseconds: 250)); // 220ms 收缩完成
    await tester.pump(); // endOfFrame → 探针上报最终矩形
    final rect = await future;

    expect(rect, isNotNull);
    expect(rect!.width, 32);
    expect(rect.height, 32);
    expect(rect.center.dx, closeTo(slotCenter.dx, 0.5));
    expect(rect.center.dy, closeTo(slotCenter.dy, 0.5));
  });

  testWidgets('收缩中组件被卸载：Future 以 null 完成（普通路径兜底）',
      (tester) async {
    final controller = SongMenuHeaderShrinkController();
    await tester.pumpWidget(host(controller));
    await tester.pump();

    final future = controller.shrinkToCircle();
    await tester.pump(const Duration(milliseconds: 100)); // 收缩进行中
    await tester.pumpWidget(const SizedBox.shrink()); // 菜单被关（dispose）
    final rect = await future;
    expect(rect, isNull);
  });

  testWidgets('重复调用 shrinkToCircle 复用同一次收缩', (tester) async {
    final controller = SongMenuHeaderShrinkController();
    await tester.pumpWidget(host(controller));
    await tester.pump();

    final a = controller.shrinkToCircle();
    final b = controller.shrinkToCircle();
    expect(identical(a, b), isTrue);
    await tester.pump(const Duration(milliseconds: 250)); // 建立动画基线帧
    await tester.pump(const Duration(milliseconds: 250)); // 收缩完成
    await tester.pump();
    expect((await a)!.width, 32);
  });
}
