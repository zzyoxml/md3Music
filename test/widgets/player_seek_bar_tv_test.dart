// PlayerSeekBar 的 TV 接线与触屏回归（AGENTS §12.4 / 计划 Task 3.2）。
//
// 两件事分开钉：
// 1. **TV 接线不参与手机包**：`kTvBuild` 在普通构建是 `const false`，
//    `if (kTvBuild) return DpadFocusable(...)` 整段被 AOT 树摇剔除，
//    普通 `flutter test` 里那棵树上根本不该出现 DpadFocusable
//    （与 test/core/remote/tv_scroll_region_test.dart 末尾那条断言同一约定）。
// 2. **触屏行为零变化**：把 _enterAdjust 抽出来只是等价重构，
//    拖动/双击平移的全部时序必须和改动前一致。
//
// 包裹方式参照 test/widgets/player_seek_bar_test.dart 的 `_wrap`
// 与 test/widgets/player_seek_bar_dock_features_test.dart 的 `_tapAt`
// （两者都是各自文件里的私有函数，这里按本文件的需要写最小版本）。

import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/widgets/player_seek_bar.dart';

const Duration _duration = Duration(minutes: 2);

/// 固定 300 宽的挂载（同 player_seek_bar_test.dart 的 `_wrap`），
/// 方便把拖动距离换算成比例。
Widget _harness({
  required Duration position,
  required Duration duration,
  ValueChanged<Duration>? onSeekEnd,
  VoidCallback? onSeekStart,
  ValueChanged<int>? onDoubleTapSkip,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: PlayerSeekBar(
            position: position,
            duration: duration,
            md3Style: true,
            activeColor: Colors.blue,
            inactiveColor: Colors.grey,
            labelColor: Colors.black,
            onSeekStart: onSeekStart,
            onSeekEnd: onSeekEnd,
            onDoubleTapSkip: onDoubleTapSkip,
          ),
        ),
      ),
    ),
  );
}

/// 一次完整点按：起手/松手之间的泵数由测试控制，保证双击窗口判定可复现
/// （同 player_seek_bar_dock_features_test.dart 的 `_tapAt`）。
Future<void> _tapAt(WidgetTester tester, Offset point) async {
  final gesture = await tester.startGesture(point);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TV 接线不进入手机包', () {
    testWidgets('普通构建（kTvBuild=false）树里没有 DpadFocusable', (tester) async {
      await tester.pumpWidget(
        _harness(position: const Duration(seconds: 30), duration: _duration),
      );

      expect(find.byType(PlayerSeekBar), findsOneWidget);
      // kTvBuild 为 const false：DpadFocusable 分支被树摇剔除，
      // 钉住「进度条的 TV 接线不参与手机包构建」这条约定。
      expect(find.byType(DpadFocusable), findsNothing);
    });

    testWidgets('普通构建下进度条仍是纯手势控件（触屏路径没被包进焦点停点）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(position: const Duration(seconds: 30), duration: _duration),
      );
      expect(
        find.ancestor(
          of: find.byType(GestureDetector),
          matching: find.byType(DpadFocusable),
        ),
        findsNothing,
      );
    });
  });

  group('等价重构后的触屏回归', () {
    testWidgets('横拖：onSeekStart / onSeekEnd 各恰好一次，落点是拖动位置', (
      tester,
    ) async {
      int startCalls = 0;
      final List<Duration> seeks = <Duration>[];
      await tester.pumpWidget(
        _harness(
          position: Duration.zero,
          duration: _duration,
          onSeekStart: () => startCalls++,
          onSeekEnd: seeks.add,
        ),
      );

      final bar = find.byType(PlayerSeekBar);
      final topLeft = tester.getTopLeft(bar);
      final center = tester.getCenter(bar);
      // 从左端起手拖到水平中点（120s 的中点 = 60s）
      final gesture = await tester.startGesture(
        Offset(topLeft.dx + 1, center.dy),
      );
      await tester.pump();
      await gesture.moveTo(center);
      await tester.pump(const Duration(milliseconds: 200));

      expect(startCalls, 1, reason: '真拖动起手只发一次 onSeekStart');
      expect(seeks, isEmpty, reason: '拖动过程中不下发 seek（连续 seek 会打满音频层）');

      await gesture.up();
      await tester.pumpAndSettle();

      expect(seeks.length, 1, reason: '松手才 seek 一次');
      expect((seeks.single.inSeconds - 60).abs() <= 1, isTrue);
      expect(startCalls, 1, reason: '落定不得重复触发 onSeekStart');
    });

    testWidgets('时长未知时拖动完全不生效', (tester) async {
      int startCalls = 0;
      Duration? seeked;
      await tester.pumpWidget(
        _harness(
          position: Duration.zero,
          duration: Duration.zero,
          onSeekStart: () => startCalls++,
          onSeekEnd: (v) => seeked = v,
        ),
      );

      final center = tester.getCenter(find.byType(PlayerSeekBar));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(startCalls, 0);
      expect(seeked, isNull);
    });

    testWidgets('启用双击平移：单击延后到判定窗口之后才 seek', (tester) async {
      int startCalls = 0;
      Duration? seeked;
      await tester.pumpWidget(
        _harness(
          position: const Duration(seconds: 30),
          duration: _duration,
          onDoubleTapSkip: (_) {},
          onSeekStart: () => startCalls++,
          onSeekEnd: (v) => seeked = v,
        ),
      );

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      await _tapAt(tester, Offset(rect.center.dx, rect.center.dy));
      await tester.pump();
      expect(seeked, isNull, reason: '第一次点按只预览，必须等双击判定落定');
      expect(startCalls, 0);

      await tester.pump(const Duration(milliseconds: 400));
      expect(startCalls, 1);
      expect(seeked, isNotNull);
    });

    testWidgets('启用双击平移：双击走 ±15s 平移并取消落点 seek', (tester) async {
      final List<int> deltas = <int>[];
      Duration? seeked;
      await tester.pumpWidget(
        _harness(
          position: const Duration(seconds: 30),
          duration: _duration,
          onDoubleTapSkip: deltas.add,
          onSeekEnd: (v) => seeked = v,
        ),
      );

      final rect = tester.getRect(find.byType(PlayerSeekBar));
      await _tapAt(tester, Offset(rect.right - 20, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 100));
      await _tapAt(tester, Offset(rect.right - 20, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 500));

      expect(deltas, [PlayerSeekBar.skipSeconds]);
      expect(seeked, isNull, reason: '双击被吸收为平移，不得再跳落点');
    });
  });
}
