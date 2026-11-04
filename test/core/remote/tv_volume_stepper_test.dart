// TvVolumeStepper 的行为契约测试（AGENTS §12.4：TV 音量方向键调节）。
//
// 这个类**不带** kTvBuild 门控（理由见 lib/core/remote/tv_volume_stepper.dart 的
// 类注释），普通构建树同样编译得到，所以步进/夹取/debounce 能被普通 flutter test
// 钉住；控件侧的 DpadFocusable 接线在普通构建里会被树摇剔除，不在本文件覆盖范围
// （那条约定由 test/widgets/player_volume_bar_tv_test.dart 钉）。
//
// 全部用 testWidgets + tester.pump(Duration) 推进 fake time：debounce 是普通
// Timer，需要 fake async 时钟才能确定性触发。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_volume_stepper.dart';

/// 四个回调的调用记录。
class _Log {
  int begins = 0;
  int aborts = 0;

  /// 每次 onStep 上报的音量（0..1）。
  final List<double> steps = <double>[];

  /// 每次 onCommit 落定的音量（0..1）——与 seek 版的签名差异就在这里：带值。
  final List<double> commits = <double>[];

  double? get lastStep => steps.isEmpty ? null : steps.last;
  double? get lastCommit => commits.isEmpty ? null : commits.last;
}

/// 建一个记录了全部回调的 stepper，并把 dispose 挂到 teardown。
///
/// 必须 dispose（或显式 flush/cancel）：残留的 debounce Timer 会让 testWidgets
/// 在收尾时报「A Timer is still pending even after the widget tree was disposed」，
/// 这本身就是「dispose 后无残留 Timer」那条用例的判据。
TvVolumeStepper _makeStepper(
  _Log log, {
  double step = TvVolumeStepper.defaultStep,
  Duration? commitDelay,
}) {
  final TvVolumeStepper stepper = TvVolumeStepper(
    onBegin: () => log.begins++,
    onStep: log.steps.add,
    onCommit: log.commits.add,
    onAbort: () => log.aborts++,
    step: step,
    commitDelay: commitDelay ?? TvVolumeStepper.defaultCommitDelay,
  );
  addTearDown(stepper.dispose);
  return stepper;
}

bool _press(
  TvVolumeStepper stepper,
  TraversalDirection direction, {
  double current = 0.5,
}) => stepper.handleDirection(direction, current: current);

void main() {
  group('TvVolumeStepper', () {
    testWidgets('连按两次右 = +10%（会话内累加，基准不被 current 反复重置）', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      // 调节期间宿主传入的 current 一直是 0.5（写盘前外部读到的还是旧值）：
      // 若每步都从 current 起算，两次按键只会偏移一步的量。
      expect(_press(stepper, TraversalDirection.right, current: 0.5), isTrue);
      expect(_press(stepper, TraversalDirection.right, current: 0.5), isTrue);

      expect(log.begins, 1, reason: '只有第一次有效步进才算开会话');
      expect(log.steps.length, 2);
      expect(log.lastStep, closeTo(0.6, 1e-9), reason: '0.5 + 5% + 5%');
      stepper.flush();
      expect(log.commits.single, closeTo(0.6, 1e-9));
    });

    testWidgets('边界夹取：0 处按左、1 处按右都不越界，且仍消费按键', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      expect(_press(stepper, TraversalDirection.left, current: 0.0), isTrue);
      expect(log.lastStep, 0.0, reason: '左端不能再夹出负值');
      // 边界仍算「已消费」：否则在 0% 处按左会把焦点甩到别的控件上，
      // 移出这一行靠的是上/下键。
      expect(_press(stepper, TraversalDirection.left), isTrue);

      stepper.flush();
      log.steps.clear();

      expect(_press(stepper, TraversalDirection.right, current: 1.0), isTrue);
      expect(log.lastStep, 1.0, reason: '右端不得越过 100%');
      expect(_press(stepper, TraversalDirection.right), isTrue);
      stepper.flush();

      expect(log.steps.every((double v) => v >= 0.0 && v <= 1.0), isTrue);
    });

    testWidgets('上/下键返回 false 且不进会话（焦点必须出得去）', (tester) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      expect(_press(stepper, TraversalDirection.up), isFalse);
      expect(_press(stepper, TraversalDirection.down), isFalse);
      expect(log.begins, 0, reason: '上下键不该开调节会话');
      expect(log.steps, isEmpty);
      expect(stepper.isAdjusting, isFalse);
    });

    testWidgets('current 越界输入先 clamp 再步进', (tester) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      // 外部给了 1.4（USB 独占档按百分比换算时理论可越界）：基准要收进 [0,1]
      expect(_press(stepper, TraversalDirection.right, current: 1.4), isTrue);
      expect(log.lastStep, 1.0, reason: '1.0 + 5% 仍夹在 1.0');
      expect(_press(stepper, TraversalDirection.left), isTrue);
      expect(log.lastStep, closeTo(0.95, 1e-9), reason: '会话内从 1.0 累减');

      // 会话进行中：基准仍是会话内的 target，越界的 current 完全不参与
      expect(_press(stepper, TraversalDirection.left, current: -0.3), isTrue);
      expect(log.lastStep, closeTo(0.9, 1e-9), reason: '从会话内的 0.95 累减，不重定基');
      stepper.cancel();

      // 新会话：下越界的 current 先夹进 [0,1] 再步进
      expect(_press(stepper, TraversalDirection.left, current: -0.3), isTrue);
      expect(log.lastStep, 0.0, reason: '基准 -0.3 夹成 0，再 -5% 仍夹在 0');
      stepper.cancel();
    });

    testWidgets('debounce：连按只落定一次，且 onCommit 收到最后一个 target', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      _press(stepper, TraversalDirection.right, current: 0.0);
      expect(log.commits, isEmpty, reason: '连按期间不该反复写盘');

      // 静默一半时间后再按一次：debounce 顺延，不应提前落定
      await tester.pump(TvVolumeStepper.defaultCommitDelay ~/ 2);
      expect(log.commits, isEmpty);
      _press(stepper, TraversalDirection.right);
      await tester.pump(TvVolumeStepper.defaultCommitDelay ~/ 2);
      expect(log.commits, isEmpty, reason: '第二次按键把静默窗口重新计满');

      await tester.pump(TvVolumeStepper.defaultCommitDelay);
      expect(log.commits.length, 1, reason: '连按合并成一次写盘');
      expect(log.lastCommit, closeTo(0.1, 1e-9));
      expect(log.lastCommit, log.lastStep, reason: '落定的必须是最后显示的值');
      expect(stepper.isAdjusting, isFalse);
    });

    testWidgets('flush() 立即落定并取消 Timer（之后不再二次 commit）', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      _press(stepper, TraversalDirection.right, current: 0.2);
      stepper.flush();
      expect(log.commits.single, closeTo(0.25, 1e-9));
      expect(log.aborts, 0, reason: '落定走 onCommit，不是放弃');

      await tester.pump(TvVolumeStepper.defaultCommitDelay);
      expect(log.commits.length, 1, reason: '挂起的 debounce 必须已被 flush 取消');

      // 无挂起会话时 flush 零副作用
      stepper.flush();
      expect(log.commits.length, 1);
    });

    testWidgets('cancel() 调 onAbort 且不调 onCommit', (tester) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      _press(stepper, TraversalDirection.left, current: 0.3);
      stepper.cancel();
      expect(log.aborts, 1);
      expect(log.commits, isEmpty, reason: '被设为只读/切档时不该把中间值写盘');
      expect(stepper.isAdjusting, isFalse);

      // 无挂起会话时 cancel 零副作用
      stepper.cancel();
      expect(log.aborts, 1);
    });

    testWidgets('dispose() 后没有残留 Timer（否则 testWidgets 收尾会报错）', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = TvVolumeStepper(
        onBegin: () => log.begins++,
        onStep: log.steps.add,
        onCommit: log.commits.add,
        onAbort: () => log.aborts++,
      );

      _press(stepper, TraversalDirection.right, current: 0.0);
      stepper.dispose();
      // 泵过静默窗口：Timer 已取消，既不该 commit 也不该被框架判成 pending timer
      await tester.pump(TvVolumeStepper.defaultCommitDelay * 2);
      expect(log.commits, isEmpty, reason: '控件都没了，不该再补一次写盘');
      expect(stepper.isAdjusting, isFalse);
      // addTearDown 之外的重复 dispose 也必须安全
      stepper.dispose();
    });

    testWidgets('isAdjusting 生命周期：step 后 true、flush/cancel 后 false', (
      tester,
    ) async {
      final _Log log = _Log();
      final TvVolumeStepper stepper = _makeStepper(log);

      expect(stepper.isAdjusting, isFalse);
      _press(stepper, TraversalDirection.right, current: 0.0);
      expect(stepper.isAdjusting, isTrue);
      stepper.flush();
      expect(stepper.isAdjusting, isFalse);

      _press(stepper, TraversalDirection.right, current: 0.0);
      expect(stepper.isAdjusting, isTrue);
      stepper.cancel();
      expect(stepper.isAdjusting, isFalse);
    });

    testWidgets('步长可配：默认 5%（全程 20 次），自定义 2% 走满 50 次', (
      tester,
    ) async {
      final _Log defaults = _Log();
      expect(TvVolumeStepper.defaultStep, 0.05);
      final TvVolumeStepper byDefault = _makeStepper(defaults);
      expect(_press(byDefault, TraversalDirection.right, current: 0.0), isTrue);
      expect(defaults.lastStep, closeTo(0.05, 1e-9));
      byDefault.cancel();

      final _Log fine = _Log();
      final TvVolumeStepper by2 = _makeStepper(fine, step: 0.02);
      for (int i = 0; i < 50; i++) {
        _press(by2, TraversalDirection.right, current: 0.0);
      }
      expect(fine.lastStep, closeTo(1.0, 1e-9), reason: '2% × 50 = 满量程');
      by2.cancel();
    });
  });
}
