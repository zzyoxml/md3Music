/// 横屏常驻控制带给进度条加的四项能力的回归测试（计划
/// docs/2026-10-03-landscape-control-dock-redesign-plan.md §2.5、§2.7）。
///
/// 覆盖两件事：
/// 1. **默认全关 = 旧观**：不画刻线、右侧恒为「−剩余」、点按即时 seek。
///    这条是「不新建第二个进度条控件」（R3）的前提 —— 竖屏 compact 走的仍是默认档。
/// 2. 打开后各自生效，其中双击平移与点按跳转的仲裁（第一次点按延后 250ms 让位
///    给双击判定）是本文件最容易退化的地方。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/widgets/player_seek_bar.dart';

const Duration _duration = Duration(seconds: 100);
const Duration _position = Duration(seconds: 30);

PlayerSeekBar _bar({
  bool tickMarks = false,
  bool showRemaining = false,
  Widget? labelRowBadge,
  ValueChanged<int>? onDoubleTapSkip,
  ValueChanged<Duration>? onSeekEnd,
  VoidCallback? onSeekStart,
}) => PlayerSeekBar(
  position: _position,
  duration: _duration,
  isPlaying: false,
  md3Style: true,
  activeColor: Colors.blue,
  inactiveColor: Colors.grey,
  labelColor: Colors.black,
  tickMarks: tickMarks,
  showRemaining: showRemaining,
  labelRowBadge: labelRowBadge,
  onDoubleTapSkip: onDoubleTapSkip,
  onSeekStart: onSeekStart,
  onSeekEnd: onSeekEnd,
);

Widget _harness(PlayerSeekBar bar) => MaterialApp(home: Scaffold(body: bar));

/// 一次完整点按：起手/松手之间的泵数由测试控制，保证双击窗口判定可复现。
Future<void> _tapAt(WidgetTester tester, Offset point) async {
  final gesture = await tester.startGesture(point);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 20));
}

/// 轨道画布（挂着 _SeekBarPainter 的那个 CustomPaint）
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

  group('默认全关 = 旧观', () {
    testWidgets('静止态右侧是「−剩余」，且轨道上不画任何刻线', (tester) async {
      await tester.pumpWidget(_harness(_bar()));

      expect(find.text('0:30'), findsOneWidget);
      expect(find.text('-1:10'), findsOneWidget);
      expect(tester.renderObject(_canvas()), isNot(paints..line()));
    });

    testWidgets('点按轨道即时 seek 到落点，不延后', (tester) async {
      Duration? seeked;
      await tester.pumpWidget(_harness(_bar(onSeekEnd: (v) => seeked = v)));

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      await _tapAt(tester, Offset(rect.center.dx, rect.center.dy));
      await tester.pump();

      expect(
        seeked,
        isNotNull,
        reason: '未启用双击平移时，松手即 seek（旧行为）',
      );
    });
  });

  group('刻度尺 tickMarks', () {
    testWidgets('静止态不画刻线', (tester) async {
      await tester.pumpWidget(_harness(_bar(tickMarks: true)));
      expect(tester.renderObject(_canvas()), isNot(paints..line()));
    });

    testWidgets('拖动时浮现刻线', (tester) async {
      await tester.pumpWidget(_harness(_bar(tickMarks: true)));

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      final gesture = await tester.startGesture(
        Offset(rect.center.dx, rect.center.dy),
      );
      // moveBy 要越过拖拽识别器的 slop，把手势定性成拖动；轨道膨胀动画 180ms，
      // 刻线随它淡入，所以再泵 220ms。
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.renderObject(_canvas()), paints..line());

      await gesture.up();
    });

    testWidgets('时长未知时不画刻线', (tester) async {
      await tester.pumpWidget(
        _harness(
          PlayerSeekBar(
            position: Duration.zero,
            duration: Duration.zero,
            isPlaying: false,
            md3Style: true,
            activeColor: Colors.blue,
            inactiveColor: Colors.grey,
            labelColor: Colors.black,
            tickMarks: true,
          ),
        ),
      );
      expect(tester.renderObject(_canvas()), isNot(paints..line()));
    });
  });

  group('showRemaining', () {
    testWidgets('静止显示总时长，按下切成「−剩余」', (tester) async {
      await tester.pumpWidget(_harness(_bar(showRemaining: true)));
      expect(find.text('0:30'), findsOneWidget);
      expect(find.text('1:40'), findsOneWidget, reason: '静止态右侧是总时长');
      expect(find.text('-1:10'), findsNothing);

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      final gesture = await tester.startGesture(
        Offset(rect.center.dx, rect.center.dy),
      );
      // 按下期间落点即展示位置：轨道中心 → 已播 0:50 / 剩 0:50。
      // onTapDown 要等手势竞技场让拖拽识别器先表态（约 100ms 之后）才落到这里，
      // 所以按下态要泵过 150ms 才观察得到，同时不能越过 ~200ms 的点按取消线。
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('-0:50'), findsOneWidget, reason: '按下即切成「−剩余」');

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.text('1:40'),
        findsOneWidget,
        reason: '松开回到静止态：右侧又是总时长',
      );
    });
  });

  group('双击平移 onDoubleTapSkip', () {
    testWidgets('单击延后到判定窗口之后才 seek 到落点', (tester) async {
      Duration? seeked;
      var startCalls = 0;
      await tester.pumpWidget(
        _harness(
          _bar(
            onDoubleTapSkip: (_) {},
            onSeekStart: () => startCalls++,
            onSeekEnd: (v) => seeked = v,
          ),
        ),
      );

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      await _tapAt(tester, Offset(rect.right - 20, rect.center.dy));
      await tester.pump();
      expect(
        seeked,
        isNull,
        reason: '第一次点按只预览，必须等双击判定落定',
      );
      expect(startCalls, 0, reason: '预览期间不得暂停播放');

      await tester.pump(const Duration(milliseconds: 400));
      expect(startCalls, 1);
      expect(seeked, isNotNull);
    });

    testWidgets('双击左半区请求 −15 秒，且取消落点 seek', (tester) async {
      final deltas = <int>[];
      Duration? seeked;
      await tester.pumpWidget(
        _harness(
          _bar(
            onDoubleTapSkip: deltas.add,
            onSeekEnd: (v) => seeked = v,
          ),
        ),
      );

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      await _tapAt(tester, Offset(rect.left + 20, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 100));
      await _tapAt(tester, Offset(rect.left + 20, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 500));

      expect(deltas, [-PlayerSeekBar.skipSeconds]);
      expect(seeked, isNull, reason: '双击被吸收为平移，不得再跳落点');
    });

    testWidgets('双击右半区请求 +15 秒', (tester) async {
      final deltas = <int>[];
      await tester.pumpWidget(_harness(_bar(onDoubleTapSkip: deltas.add)));

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      await _tapAt(tester, Offset(rect.right - 20, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 100));
      await _tapAt(tester, Offset(rect.right - 20, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 500));

      expect(deltas, [PlayerSeekBar.skipSeconds]);
    });

    testWidgets('按下后改成拖动：按真拖动处理，松手 seek 到落点', (tester) async {
      Duration? seeked;
      var startCalls = 0;
      await tester.pumpWidget(
        _harness(
          _bar(
            onDoubleTapSkip: (_) {},
            onSeekStart: () => startCalls++,
            onSeekEnd: (v) => seeked = v,
          ),
        ),
      );

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      final gesture = await tester.startGesture(
        Offset(rect.center.dx, rect.center.dy),
      );
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(startCalls, 1, reason: '拖拽定性为真拖动，必须补发 onSeekStart');
      expect(seeked, isNotNull);
    });

    testWidgets('无障碍出口挂上滑条增减动作', (tester) async {
      await tester.pumpWidget(_harness(_bar(onDoubleTapSkip: (_) {})));

      final semantics = tester.getSemantics(
        find.descendant(
          of: find.byType(PlayerSeekBar),
          matching: find.byType(Semantics),
        ),
      );
      // 增减动作背后走的是与双击同一个 onDoubleTapSkip 回调（同一对 ±15 增量），
      // 这里钉住「动作已挂上」；TalkBack 触发路径由平台语义桥承担。
      expect(
        semantics,
        isSemantics(
          isSlider: true,
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );
    });

    testWidgets('未启用双击平移时不挂增减动作', (tester) async {
      await tester.pumpWidget(_harness(_bar()));

      final semantics = tester.getSemantics(
        find.descendant(
          of: find.byType(PlayerSeekBar),
          matching: find.byType(Semantics),
        ),
      );
      expect(
        semantics,
        isSemantics(
          isSlider: true,
          hasIncreaseAction: false,
          hasDecreaseAction: false,
        ),
      );
    });
  });
  group('visible（Zen 淡出后停帧）', () {
    // AGENTS §10.4 第 3/6 条：组件不可见时不能继续产帧。Offstage 只停绘制与命中，
    // 共享节拍的订阅与 2fps 自驱动 Timer 都得靠 visible 显式解绑。
    PlayerSeekBar bar({required bool visible}) => PlayerSeekBar(
      position: const Duration(seconds: 30),
      duration: _duration,
      isPlaying: true,
      md3Style: true,
      activeColor: Colors.blue,
      inactiveColor: Colors.grey,
      labelColor: Colors.black,
      visible: visible,
    );

    testWidgets('不可见时不订阅共享节拍，可见时才订阅', (tester) async {
      await tester.pumpWidget(_harness(bar(visible: false)));
      expect(
        PlayerFrameDriver.instance.hasListeners,
        isFalse,
        reason: '隐藏状态下波浪相位不该挂着 60fps 节拍',
      );

      await tester.pumpWidget(_harness(bar(visible: true)));
      expect(
        PlayerFrameDriver.instance.hasListeners,
        isTrue,
        reason: '唤出 chrome 后波形要恢复推进',
      );

      // 收回时波幅先收敛再解绑（250ms 动画走完）
      await tester.pumpWidget(_harness(bar(visible: false)));
      await tester.pump(const Duration(milliseconds: 320));
      expect(PlayerFrameDriver.instance.hasListeners, isFalse);
    });

    testWidgets('不可见时 2fps 自驱动不再推进播放头', (tester) async {
      await tester.pumpWidget(_harness(bar(visible: false)));
      // 泵过好几个自驱动周期：隐藏状态下时间数字必须停在原位
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('0:30'), findsOneWidget);

      await tester.pumpWidget(_harness(bar(visible: true)));
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.text('0:30'),
        findsNothing,
        reason: '可见后 2fps 自驱动照常推进',
      );
    });
  });

  // 进度条下方那一行的明暗纪律（音质胶囊统一回顶栏后，只有车机窄面板还把它放在
  // 这里）。Opacity 是整块合成：跟着时间数字一起压到 0.5，徽章与深色封面相叠就发灰
  // 发暗，看着像被禁用 —— 那是「暗化」。淡应该由徽章自己的配色出（宿主传 faded 形态，
  // 容器降 alpha、文字满色），不该由这一行的整块 opacity 出。
  group('时间行的淡化只作用在时间数字上', () {
    testWidgets('中央插槽不被 AnimatedOpacity 包住，且真的点得动', (tester) async {
      int tapped = 0;
      await tester.pumpWidget(
        _harness(
          _bar(
            labelRowBadge: GestureDetector(
              onTap: () => tapped++,
              child: const Text('HQ'),
            ),
          ),
        ),
      );

      expect(
        find.ancestor(
          of: find.text('HQ'),
          matching: find.byType(AnimatedOpacity),
        ),
        findsNothing,
        reason: '徽章不参与整行压暗，否则与封面相叠变灰变暗，看着像被禁用',
      );
      // 命中而不是数 IgnorePointer：Text 自身就带两层框架级 IgnorePointer，
      // 数个数分不清「本行的那层」与框架那层，点一次才是判据。
      await tester.tap(find.text('HQ'));
      await tester.pump();
      expect(tapped, 1, reason: '有插槽时必须去掉本行的 IgnorePointer，否则徽章点不动');
    });

    testWidgets('两个时间数字各自仍有一层淡化', (tester) async {
      await tester.pumpWidget(
        _harness(_bar(labelRowBadge: const Text('HQ'))),
      );

      for (final label in ['0:30', '-1:10']) {
        expect(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedOpacity),
          ),
          findsOneWidget,
          reason: '时间只是标注，静止态照旧压暗、拖动时提亮',
        );
      }
    });
  });
}
