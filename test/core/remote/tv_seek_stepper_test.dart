// TvSeekStepper 的行为契约测试（AGENTS §12.4：TV 进度条方向键调节）。
//
// 这个类**不带** kTvBuild 门控（见 lib/core/remote/tv_seek_stepper.dart 的类
// 注释），普通构建树同样编译得到，所以步进/夹取/debounce 能被普通 flutter test
// 钉住；控件侧的 DpadFocusable 接线在普通构建里会被树摇剔除（另见
// test/core/remote/tv_scroll_region_test.dart 那条约定），不在本文件覆盖范围。
//
// 全部用 testWidgets + tester.pump(Duration) 推进 fake time：debounce 是普通
// Timer，需要 fake async 时钟才能确定性触发。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_seek_stepper.dart';

/// 四个回调的调用记录。
class _Log {
  int begins = 0;
  int commits = 0;
  int aborts = 0;

  /// 每次 onStep 上报的目标比例（0~1）。
  final List<double> steps = <double>[];

  double? get lastStep => steps.isEmpty ? null : steps.last;
}

const int _durationMs = 60000;

/// 建一个记录了全部回调的 stepper，并把 dispose 挂到 teardown。
///
/// 必须 dispose（或显式 flush/cancel）：残留的 debounce Timer 会让 testWidgets
/// 在收尾时报「A Timer is still pending even after the widget tree was disposed」，
/// 这本身就是 ⑧ 那条用例的判据。
TvSeekStepper _makeStepper(_Log log, {int stepSeconds = 5, Duration? commitDelay}) {
  final TvSeekStepper stepper = TvSeekStepper(
    onBegin: () => log.begins++,
    onStep: log.steps.add,
    onCommit: () => log.commits++,
    onAbort: () => log.aborts++,
    stepSeconds: stepSeconds,
    commitDelay: commitDelay ?? TvSeekStepper.defaultCommitDelay,
  );
  addTearDown(stepper.dispose);
  return stepper;
}

bool _press(
  TvSeekStepper stepper,
  TraversalDirection direction, {
  int currentMs = 0,
  int durationMs = _durationMs,
}) => stepper.handleDirection(
  direction,
  currentMs: currentMs,
  durationMs: durationMs,
);

void main() {
  group('TvSeekStepper', () {
    testWidgets('连按两次右 = +10s（会话内累加，基准不被 currentMs 反复重置）', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      // 拖动期间控件上报的展示位置一直是 10s：若每步都从 currentMs 起算，
      // 两次按键只会偏移一步的量。
      expect(_press(stepper, TraversalDirection.right, currentMs: 10000), isTrue);
      expect(_press(stepper, TraversalDirection.right, currentMs: 10000), isTrue);

      expect(log.begins, 1, reason: '只有第一次有效步进才算开会话');
      expect(log.steps.length, 2);
      expect(log.lastStep, closeTo(20000 / _durationMs, 1e-9), reason: '10s+5s+5s');
      stepper.flush();
      expect(log.commits, 1);
    });

    testWidgets('边界夹取：0 处按左、duration 处按右都不越界，且仍消费按键', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      expect(_press(stepper, TraversalDirection.left, currentMs: 0), isTrue);
      expect(log.lastStep, 0.0, reason: '左端不能再往前夹出负值');
      // 边界仍算「已消费」：否则在 0 处按左会把焦点甩到别的控件上
      expect(_press(stepper, TraversalDirection.left), isTrue);

      stepper.flush();
      log.steps.clear();

      expect(
        _press(stepper, TraversalDirection.right, currentMs: _durationMs),
        isTrue,
      );
      expect(log.lastStep, 1.0, reason: '右端不得越过 duration');
      expect(_press(stepper, TraversalDirection.right), isTrue);
      stepper.flush();

      expect(log.steps.every((double f) => f >= 0.0 && f <= 1.0), isTrue);
    });

    testWidgets('上/下键返回 false（焦点必须出得去）', (tester) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      expect(_press(stepper, TraversalDirection.up), isFalse);
      expect(_press(stepper, TraversalDirection.down), isFalse);
      expect(log.begins, 0, reason: '上下键不该开调节会话');
      expect(stepper.isAdjusting, isFalse);
    });

    testWidgets('时长未知（durationMs <= 0）返回 false 且不进会话', (tester) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      expect(_press(stepper, TraversalDirection.right, durationMs: 0), isFalse);
      expect(_press(stepper, TraversalDirection.left, durationMs: -1000), isFalse);
      expect(log.begins, 0, reason: '别把人困在一条看不出进度的轨道上');
      expect(log.steps, isEmpty);
      expect(stepper.isAdjusting, isFalse);
    });

    testWidgets('debounce：连按只提交一次，落点是最后一个目标', (tester) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      _press(stepper, TraversalDirection.right, currentMs: 0);
      expect(log.commits, 0, reason: '步进期间绝不下发 seek');

      // 静默一半时间后再按一次：debounce 顺延，不应提前落定
      await tester.pump(TvSeekStepper.defaultCommitDelay ~/ 2);
      expect(log.commits, 0);
      _press(stepper, TraversalDirection.right);
      await tester.pump(TvSeekStepper.defaultCommitDelay ~/ 2);
      expect(log.commits, 0, reason: '第二次按键把静默窗口重新计满');

      await tester.pump(TvSeekStepper.defaultCommitDelay);
      expect(log.commits, 1, reason: '连按合并成一次 seek');
      expect(log.lastStep, closeTo(10000 / _durationMs, 1e-9));
    });

    testWidgets('flush() 立即落定并取消 Timer（之后不再二次 commit）', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      _press(stepper, TraversalDirection.right, currentMs: 0);
      stepper.flush();
      expect(log.commits, 1);
      expect(log.aborts, 0, reason: '落定走 onCommit，不是放弃');

      await tester.pump(TvSeekStepper.defaultCommitDelay);
      expect(log.commits, 1, reason: '挂起的 debounce 必须已被 flush 取消');

      // 无挂起会话时 flush 零副作用
      stepper.flush();
      expect(log.commits, 1);
    });

    testWidgets('cancel() 调 onAbort 且不调 onCommit', (tester) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      _press(stepper, TraversalDirection.left, currentMs: 30000);
      stepper.cancel();
      expect(log.aborts, 1);
      expect(log.commits, 0, reason: '切歌/淡出/只读时不能把旧比例 seek 出去');
      expect(stepper.isAdjusting, isFalse);

      // 无挂起会话时 cancel 零副作用
      stepper.cancel();
      expect(log.aborts, 1);
    });

    testWidgets('dispose() 后没有残留 Timer（否则 testWidgets 收尾会报错）', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = TvSeekStepper(
        onBegin: () => log.begins++,
        onStep: log.steps.add,
        onCommit: () => log.commits++,
        onAbort: () => log.aborts++,
      );

      _press(stepper, TraversalDirection.right, currentMs: 0);
      stepper.dispose();
      // 泵过静默窗口：Timer 已取消，既不该 commit 也不该被框架判成 pending timer
      await tester.pump(TvSeekStepper.defaultCommitDelay * 2);
      expect(log.commits, 0, reason: '控件都没了，不该再补一次 seek');
      expect(stepper.isAdjusting, isFalse);
      // addTearDown 之外的重复 dispose 也必须安全
      stepper.dispose();
    });

    testWidgets('isAdjusting 生命周期：step 后 true、flush/cancel 后 false', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvSeekStepper stepper = _makeStepper(log);

      expect(stepper.isAdjusting, isFalse);
      _press(stepper, TraversalDirection.right, currentMs: 0);
      expect(stepper.isAdjusting, isTrue);
      stepper.flush();
      expect(stepper.isAdjusting, isFalse);

      _press(stepper, TraversalDirection.right, currentMs: 0);
      expect(stepper.isAdjusting, isTrue);
      stepper.cancel();
      expect(stepper.isAdjusting, isFalse);
    });

    testWidgets('默认参数：5 秒一步 / 600ms 静默；自定义步长生效', (tester) async {
      final _Log log = _Log();
      expect(TvSeekStepper.defaultStepSeconds, 5);
      expect(TvSeekStepper.defaultCommitDelay, const Duration(milliseconds: 600));

      final TvSeekStepper stepper = _makeStepper(log, stepSeconds: 15);
      _press(stepper, TraversalDirection.right, currentMs: 0);
      expect(log.lastStep, closeTo(15000 / _durationMs, 1e-9));
      stepper.cancel();
    });
  });
}
