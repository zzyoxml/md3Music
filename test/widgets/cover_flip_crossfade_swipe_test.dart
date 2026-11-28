import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/player/cover_switch_physics.dart';
import 'package:md3music/modules/player/widgets/cover_flip_crossfade.dart';
import 'package:md3music/modules/player/widgets/low_res_blur.dart';

const Duration _frame = Duration(milliseconds: 16);

Widget _swipeHost({
  required String? version,
  required Widget child,
  required void Function(CoverSwitchIntent) onCommit,
  bool swipeEnabled = true,
  bool canGoPrevious = true,
  bool canGoNext = true,
  Widget Function(int direction)? targetBuilder,
}) => MaterialApp(
  home: Center(
    child: SizedBox.square(
      dimension: 300,
      child: CoverFlipCrossfade(
        version: version,
        fallbackFilePath: null,
        iconSize: 48,
        radius: 16,
        enabled: true,
        swipeEnabled: swipeEnabled,
        canGoPrevious: canGoPrevious,
        canGoNext: canGoNext,
        onSwipeCommit: onCommit,
        swipeTargetBuilder: targetBuilder,
        readinessProbe: (_, _, _) async => true,
        child: child,
      ),
    ),
  ),
);

/// 封面的旋转层。前半程（t < 0.5）只有旧层一个 Transform。
Finder _layers() => find.descendant(
  of: find.byType(CoverFlipCrossfade),
  matching: find.byType(Transform),
);

/// 翻转组件下是否挂着模糊层（自动过渡启动后的判据；手势路径恒为 false）。
///
/// 两种形态都算「在糊」：低分辨率快照就绪前是阶梯 [ImageFiltered] 兜底，
/// 就绪后换成 [LowResBlurPainter] 的 CustomPaint α 叠层。
bool _flipBlurring(WidgetTester tester) {
  return find
          .descendant(
            of: find.byType(CoverFlipCrossfade),
            matching: find.byType(ImageFiltered),
          )
          .evaluate()
          .isNotEmpty ||
      find
          .descendant(
            of: find.byType(CoverFlipCrossfade),
            matching: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is LowResBlurPainter,
            ),
          )
          .evaluate()
          .isNotEmpty;
}

/// 等自动过渡真正启动（探测 + 预热 + 快照准备都在微任务里，翻转晚 1~2 帧）。
Future<void> _awaitFlipStart(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    if (find.byType(Transform).evaluate().isNotEmpty) return;
    await tester.pump(_frame);
  }
  fail('自动翻转未在 320ms 内启动');
}

void main() {
  testWidgets('跟手：拖动中角度随 dx 增大，松手慢放回正且不提交', (tester) async {
    var commits = 0;
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (_) => commits++,
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    // 第一拍只越过 touch slop（DragStartBehavior.start 把这 30px 并入起点，
    // onUpdate 的 delta 为 0），画面仍停在 0°。
    await gesture.moveBy(const Offset(-30, 0), timeStamp: _frame);
    await tester.pump(_frame);
    expect(_layers(), findsOneWidget);
    final startWidth = tester.widget<Transform>(_layers()).transform.entry(0, 0);

    // 慢拖（200ms 才 40px）：速度远低于甩动阈值，松手只回弹。
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveBy(
      const Offset(-40, 0),
      timeStamp: const Duration(milliseconds: 232),
    );
    await tester.pump(_frame);
    expect(_layers(), findsOneWidget); // 前半程新层不出树（省一层栅格）
    final draggedWidth = tester.widget<Transform>(_layers()).transform.entry(0, 0);
    expect(draggedWidth, lessThan(startWidth)); // 绕纵轴转起来 → 投影变窄
    expect(draggedWidth, lessThan(1.0));
    // 方向镜像：左拖 = 下一曲，角度为正 → rotateY 的 (0,2) 元素 = sin > 0。
    expect(tester.widget<Transform>(_layers()).transform.entry(0, 2),
        greaterThan(0));

    await gesture.up(timeStamp: const Duration(milliseconds: 248));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(commits, 0);
    expect(find.byType(Transform), findsNothing); // 收敛回 idle，零额外层级
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('快甩：提交切歌，version 变化后不重启自动过渡', (tester) async {
    CoverSwitchIntent? intent;
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (i) => intent = i,
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    await gesture.moveBy(const Offset(-90, 0), timeStamp: _frame); // 越 slop
    await tester.pump(_frame);
    // 未过半（90/186 ≈ 0.48 页）但 90px / 32ms ≈ 2800px/s：速度判据提交。
    await gesture.moveBy(
      const Offset(-90, 0),
      timeStamp: const Duration(milliseconds: 48),
    );
    await tester.pump(_frame);
    await gesture.up(timeStamp: const Duration(milliseconds: 64));
    await tester.pump();

    expect(intent, CoverSwitchIntent.next);
    // 提交瞬间仍在「前半程」：手势路径零模糊（不挂 ImageFiltered）。
    expect(find.byType(ImageFiltered), findsNothing);

    // provider 换歌：沿同一个 _motion 时钟翻完后半场，不重启 500ms 自动过渡。
    await tester.pumpWidget(
      _swipeHost(
        version: 'b',
        child: const SizedBox.expand(),
        onCommit: (i) => intent = i,
      ),
    );
    // 路径归属判据：手势路径全程零模糊。给自动过渡足够的启动窗口
    // （探测 + 预热 + 快照都是异步的，100ms 内可能还没挂上模糊层，太早断言
    // 会把「误走自动过渡」放过去）；若真走了自动过渡，320ms 内必然命中。
    var blurredByAutoFlip = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (_flipBlurring(tester)) {
        blurredByAutoFlip = true;
        break;
      }
    }
    expect(blurredByAutoFlip, isFalse, reason: '手势提交误走了自动过渡（挂上了模糊层）');
    await tester.pumpAndSettle();
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('右拖 = 上一曲：方向镜像，角度取负', (tester) async {
    CoverSwitchIntent? intent;
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (i) => intent = i,
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    await gesture.moveBy(const Offset(90, 0), timeStamp: _frame); // 越过 slop
    await tester.pump(_frame);

    // 方向符号要在**前半程**读：拖过 90° 旧层已移出树，读到的会是卡背。
    // rotateY 的 (0,2) = sin(angle)：右拖必须是负角，否则方向镜像反了。
    expect(
      tester.widget<Transform>(_layers()).transform.entry(0, 2),
      lessThan(0),
    );

    await gesture.moveBy(
      const Offset(90, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await tester.pump(_frame);
    await gesture.up(timeStamp: const Duration(milliseconds: 48));
    await tester.pump();
    expect(intent, CoverSwitchIntent.previous);
    // 提交后等 provider 换歌：version 变化才走后半场并收尾（与「快甩」同款）。
    await tester.pumpWidget(
      _swipeHost(
        version: 'b',
        child: const SizedBox.expand(),
        onCommit: (i) => intent = i,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('翻过 90°：卡背显示目标邻居封面（不是当前歌）', (tester) async {
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const Center(child: Text('current')),
        onCommit: (_) {},
        targetBuilder: (dir) => Center(child: Text(dir > 0 ? 'next' : 'prev')),
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    await gesture.moveBy(const Offset(-30, 0), timeStamp: _frame); // 越过 slop
    await tester.pump(_frame);
    // 前半程：卡背恒零宽、不入树（画面是锁存的旧封面，不含 child 的文本）。
    expect(find.text('next'), findsNothing);

    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(
        const Offset(-30, 0),
        timeStamp: Duration(milliseconds: 32 + i * 32),
      );
      await tester.pump(const Duration(milliseconds: 32));
    }
    // 拖到 ≈0.7 页（>90°）：旧层已退场，卡背翻入的是目标邻居。
    expect(find.text('current'), findsNothing);
    expect(find.text('next'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle();
  });

  testWidgets('拖动中 version 变化（封面富化）：不打断手势', (tester) async {
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    await gesture.moveBy(const Offset(-30, 0), timeStamp: _frame);
    await tester.pump(_frame);
    final before = tester.widget<Transform>(_layers()).transform.entry(0, 2);

    // 同一首歌的封面被富化补齐（songId 不变、只换图 URL）→ 页面重建。
    await tester.pumpWidget(
      _swipeHost(
        version: 'a2',
        child: const SizedBox.expand(),
        onCommit: (_) {},
      ),
    );
    await tester.pump(_frame);

    // 仍在拖动里：继续滑还能推进角度（旧实现这里会 _cancelSwipe 弹回）。
    await gesture.moveBy(
      const Offset(-30, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await tester.pump(_frame);
    final after = tester.widget<Transform>(_layers()).transform.entry(0, 2);
    expect(after, greaterThan(before));

    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle();
  });

  testWidgets('自动过渡在飞时起手：接管手势而不是被吞', (tester) async {
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _swipeHost(
        version: 'b',
        child: const SizedBox.expand(),
        onCommit: (_) {},
      ),
    );
    await _awaitFlipStart(tester); // 自动过渡已在飞（_flip.isAnimating）

    final center = tester.getCenter(find.byType(CoverFlipCrossfade));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    await gesture.moveBy(const Offset(-30, 0), timeStamp: _frame);
    await tester.pump(_frame);
    await gesture.moveBy(
      const Offset(-30, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await tester.pump(_frame);

    // 接管成功：手势时钟在推进（angle>0），且手势路径零模糊。
    expect(
      tester.widget<Transform>(_layers()).transform.entry(0, 2),
      greaterThan(0),
    );
    expect(find.byType(ImageFiltered), findsNothing);

    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle();
  });

  testWidgets('回拉否决：拖过半程但末段反向甩，不提交', (tester) async {
    var commits = 0;
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (_) => commits++,
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    // 拖过交接点：进度 ≈ 1.07 页（t 钳在 0.5）。
    for (var i = 1; i <= 4; i++) {
      await gesture.moveBy(const Offset(-50, 0), timeStamp: _frame * i);
      await tester.pump(_frame);
    }
    // 停 200ms：让「往前甩」的样本滑出速度估计窗口（100ms），
    // 否则平均速度仍朝前，回拉否决不会被触发。
    await tester.pump(const Duration(milliseconds: 200));
    // 末段反向快速回拉 60px（进度仍在 0.75 页 > 0.5）：位移判据达标，
    // 但释放速度朝反方向 → 回拉否决优先，不切歌。
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(
        const Offset(15, 0),
        timeStamp: Duration(milliseconds: 264 + i * 8),
      );
      await tester.pump(const Duration(milliseconds: 8));
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 296));
    await tester.pump();

    expect(commits, 0);
    await tester.pumpAndSettle();
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('无邻居侧仍上报一次提交（供 Toast），角度不越过 90°', (tester) async {
    var commits = 0;
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        canGoNext: false,
        onCommit: (_) => commits++,
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    await gesture.moveBy(const Offset(-100, 0), timeStamp: _frame);
    await tester.pump(_frame);
    await gesture.moveBy(
      const Offset(-100, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await tester.pump(_frame);

    // 越界钳到 0.12 页 → 时钟 t ≤ 0.12 → 角度 ≈ 21.6°，投影仍然很宽。
    final width = tester.widget<Transform>(_layers()).transform.entry(0, 0);
    expect(width, greaterThan(0.9));

    await gesture.up(timeStamp: const Duration(milliseconds: 48));
    await tester.pump();
    await tester.pumpAndSettle();
    // 上报给 provider 复用「已经是最后一首了」Toast，画面仍回弹不翻页。
    expect(commits, 1);
  });

  testWidgets('swipeEnabled=false：不挂手势，自动过渡照旧', (tester) async {
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        swipeEnabled: false,
        onCommit: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _swipeHost(
        version: 'b',
        child: const SizedBox.expand(),
        swipeEnabled: false,
        onCommit: (_) {},
      ),
    );
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Transform), findsWidgets);
    // 自动过渡路径仍带模糊（低分辨率快照叠层或量化滤镜兜底）。
    expect(find.byType(ImageFiltered), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('同版本重建不打断在飞回弹', (tester) async {
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(CoverFlipCrossfade));

    // 时间戳全为 0（手指几乎没速度）：进度约 0.16 页 < 0.5，松手只回弹。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(center);
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(_frame);
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump(_frame);
    await gesture.up();
    await tester.pump();
    expect(find.byType(Transform), findsOneWidget); // 回弹在飞

    // 模拟宿主页 setState（歌词到达等）：同版本重建一次。
    await tester.pumpWidget(
      _swipeHost(
        version: 'a',
        child: const SizedBox.expand(),
        onCommit: (_) {},
      ),
    );
    expect(find.byType(Transform), findsOneWidget); // 回弹仍在飞
    await tester.pumpAndSettle();
    expect(find.byType(Transform), findsNothing);
  });
}
