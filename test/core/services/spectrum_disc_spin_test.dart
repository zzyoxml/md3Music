import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/core/services/spectrum_disc_spin.dart';

/// 频谱圆盘**共享旋转相位**的回归测试。
///
/// 这条链路要锁的是四件事：
/// 1. 相位只由**消费者存在**时推进，最后一个消费者走掉即冻结（暂停的唱片必须
///    静止，恢复播放要接着上一圈的角度转，不能归零也不能瞬移）；
/// 2. 多消费者共用同一相位（跟手展开时拖拽覆盖层 + 路由播放页两个实例），
///    这是形变层落位帧能与真身逐角度重合的前提；
/// 3. `attach` / `detach` 幂等 —— `didChangeDependencies` 会反复同步绑定；
/// 4. 后台回来的一次大 dt 被 [SpectrumDiscSpin.maxStep] 钳制，不让唱片一次性
///    转过一大截。
void main() {
  // PlayerFrameDriver 在构造时挂 WidgetsBindingObserver，先初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  final spin = SpectrumDiscSpin.instance;

  setUp(spin.reset);
  tearDown(() {
    spin.reset();
  });

  /// 一圈 2π 对应 [SpectrumDiscSpin.turn]，这里换算"某时长应转过的弧度"。
  double radiansFor(Duration dt) =>
      2 * math.pi * dt.inMicroseconds / SpectrumDiscSpin.turn.inMicroseconds;

  /// 按真实节拍（16ms 一次）推进累计 [total]，绕开 [SpectrumDiscSpin.maxStep]
  /// 对**单次** dt 的钳制（那一条治的是后台回来的一次大 dt，见专门用例）。
  void advanceFor(Duration total) {
    var left = total.inMicroseconds;
    const stepUs = 16000;
    while (left > 0) {
      final chunk = left >= stepUs ? stepUs : left;
      spin.debugAdvance(Duration(microseconds: chunk));
      left -= chunk;
    }
  }

  test('没有消费者时相位不推进，isSpinning 为假', () {
    expect(spin.isSpinning, isFalse);
    expect(spin.consumerCount, 0);
    expect(spin.angle.value, 0.0);
  });

  test('attach 后开始推进：按 dt 累加且恒在 [0, 2π)', () {
    final owner = Object();
    spin.attach(owner);
    expect(spin.isSpinning, isTrue);
    expect(spin.consumerCount, 1);

    advanceFor(const Duration(milliseconds: 100));
    expect(spin.angle.value, closeTo(radiansFor(const Duration(milliseconds: 100)), 1e-12));

    // 转过一整圈后回绕（不是一直线性涨到 2π 以上）
    advanceFor(SpectrumDiscSpin.turn);
    expect(spin.angle.value, greaterThanOrEqualTo(0.0));
    expect(spin.angle.value, lessThan(2 * math.pi));
  });

  test('多消费者共用同一相位：走掉一个仍转，最后一个走掉即冻结', () {
    final a = Object();
    final b = Object();
    spin.attach(a);
    spin.attach(b);
    expect(spin.consumerCount, 2);

    spin.detach(a);
    expect(spin.isSpinning, isTrue, reason: '还有消费者在播放，相位必须继续推进');

    final frozen = spin.angle.value;
    spin.detach(b);
    expect(spin.isSpinning, isFalse);
    expect(spin.angle.value, frozen, reason: '最后一个消费者走掉后相位冻结在当前角');
  });

  test('暂停恢复接着上一圈的角度转，不归零', () {
    final owner = Object();
    spin.attach(owner);
    advanceFor(const Duration(seconds: 2)); // 2s → 90°
    spin.detach(owner); // 暂停
    final paused = spin.angle.value;
    expect(paused, closeTo(math.pi / 2, 1e-9));

    spin.attach(owner); // 恢复播放
    advanceFor(const Duration(seconds: 2));
    expect(spin.angle.value, closeTo(math.pi, 1e-9));
  });

  test('attach / detach 幂等（didChangeDependencies 会反复同步绑定）', () {
    final owner = Object();
    spin.attach(owner);
    spin.attach(owner);
    expect(spin.consumerCount, 1);
    final boundAngle = spin.angle.value;
    spin.detach(owner);
    spin.detach(owner);
    expect(spin.consumerCount, 0);
    expect(spin.isSpinning, isFalse);
    expect(spin.angle.value, boundAngle);
  });

  test('后台回来的大 dt 被钳制到 maxStep，不让唱片一次转过多', () {
    final owner = Object();
    spin.attach(owner);
    spin.debugAdvance(const Duration(seconds: 30));
    expect(
      spin.angle.value,
      closeTo(radiansFor(SpectrumDiscSpin.maxStep), 1e-12),
      reason: 'dt 必须钳到 maxStep，否则回前台第一帧唱片会瞬移一大段',
    );
  });

  test('节拍随消费者挂/摘：不留空转订阅', () {
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
    final owner = Object();
    spin.attach(owner);
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);
    spin.detach(owner);
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });

  test('debugSetAngle 归一到相位区间；reset 清空全部状态', () {
    spin.debugSetAngle(3 * math.pi);
    expect(spin.angle.value, closeTo(math.pi, 1e-12));

    final owner = Object();
    spin.attach(owner);
    advanceFor(const Duration(milliseconds: 500));
    spin.reset();
    expect(spin.angle.value, 0.0);
    expect(spin.consumerCount, 0);
    expect(spin.isSpinning, isFalse);
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);
  });

  test('实测 dt 推进（主路径 _advance 与 debugAdvance 同一实现）', () {
    final owner = Object();
    spin.attach(owner);
    // 5 帧 16ms ≈ 5 × 1.2° = 6°，真实节拍与 debug 推进必须同源
    for (var i = 0; i < 5; i++) {
      spin.debugAdvance(PlayerFrameDriver.step);
    }
    expect(
      spin.angle.value,
      closeTo(radiansFor(PlayerFrameDriver.step * 5), 1e-12),
    );
  });
}
