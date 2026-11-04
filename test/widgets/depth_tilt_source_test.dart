// DepthTiltController / pointerTiltTo 的行为契约测试。
//
// 关键回归点：
// 1. pointerTiltTo 纯函数：中心 0、四角 ±1、越界 clamp、退化 size 返回 zero。
// 2. 合帧泵：handleHover 只写目标值，16ms 泵一拍只发「最新值」；收敛后停摆
//    （鼠标静止 = 零帧请求，符合 AGENTS.md 帧率规则）。
// 3. handleExit 归零：走泵平滑回中，不是瞬跳，也不留悬挂 Timer。
// 4. **Windows 分支绝不创建传感器流**：sensors_plus 无 Windows 实现，一旦
//    误建流会 MissingPluginException → 宿主误报「无重力传感器」。用注入的
//    fake SensorsPlatform 记录调用次数来钉死这条约束。
// 5. Android 分支与既有 _defaultTiltStream 等价：uiInterval 采样、
//    /9.81*2.5、clamp(-1,1)、错误上报 onTiltError。
//
// 平台门控：`group` 不支持 variant，所以每个平台相关用例**逐个**加
// `variant: TargetPlatformVariant.only(...)`。口径走 defaultTargetPlatform
// （isWindowsDesktop），与宿主平台（Windows 上跑 flutter test）无关。
import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/depth_tilt_source.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 记录调用、可注入事件/错误的假传感器平台。
class _FakeSensors extends SensorsPlatform {
  /// 每次 accelerometerEventStream 调用记录的采样周期（用于断言 uiInterval）。
  final List<Duration?> samplingCalls = [];

  /// 事件源（broadcast：先 listen 后 add 的时序由调用方控制）。
  final StreamController<AccelerometerEvent> events =
      StreamController<AccelerometerEvent>.broadcast();

  /// 非 null 时 accelerometerEventStream 直接返回错误流（模拟无传感器设备）。
  Object? error;

  @override
  Stream<AccelerometerEvent> accelerometerEventStream({
    Duration samplingPeriod = SensorInterval.normalInterval,
  }) {
    samplingCalls.add(samplingPeriod);
    if (error != null) return Stream<AccelerometerEvent>.error(error!);
    return events.stream;
  }
}

void main() {
  // 真实宿主注册的是 MethodChannelSensors；每个用例换成 fake，跑完还原，
  // 避免污染同批其他测试文件。
  late SensorsPlatform original;
  final windowsVariant = TargetPlatformVariant.only(TargetPlatform.windows);
  final androidVariant = TargetPlatformVariant.only(TargetPlatform.android);

  setUp(() => original = SensorsPlatform.instance);
  tearDown(() => SensorsPlatform.instance = original);

  const double eps = 1e-12;

  group('pointerTiltTo（纯函数）', () {
    const size = Size(200, 100); // 半宽 100、半高 50

    test('矩形中心 → (0, 0)', () {
      final v = pointerTiltTo(const Offset(100, 50), size);
      expect(v, const Offset(0, 0));
    });

    test('四角 → (±1, ±1)：左上 (-1,-1)，右下 (1,1)', () {
      expect(pointerTiltTo(Offset.zero, size), const Offset(-1, -1));
      expect(pointerTiltTo(const Offset(200, 100), size), const Offset(1, 1));
      expect(pointerTiltTo(const Offset(0, 100), size), const Offset(-1, 1));
      expect(pointerTiltTo(const Offset(200, 0), size), const Offset(1, -1));
    });

    test('边缘中点 → 单轴 ±1、另一轴 0', () {
      expect(pointerTiltTo(const Offset(200, 50), size), const Offset(1, 0));
      expect(pointerTiltTo(const Offset(100, 0), size), const Offset(0, -1));
    });

    test('越界 → clamp 到 ±1', () {
      final v = pointerTiltTo(const Offset(1000, -1000), size);
      expect(v.dx, closeTo(1.0, eps));
      expect(v.dy, closeTo(-1.0, eps));
    });

    test('退化 size（宽或高 <= 0）→ zero，不产生 NaN', () {
      expect(pointerTiltTo(const Offset(5, 5), Size.zero), Offset.zero);
      expect(pointerTiltTo(const Offset(5, 5), const Size(-1, 10)), Offset.zero);
      expect(pointerTiltTo(const Offset(5, 5), const Size(10, 0)), Offset.zero);
    });

    test('符号约定：光标在中心右侧 → dx 为正（画面像从右侧被观察）', () {
      expect(pointerTiltTo(const Offset(150, 50), size).dx, greaterThan(0));
      expect(pointerTiltTo(const Offset(50, 75), size).dy, greaterThan(0));
    });
  });

  group('DepthTiltController · Windows 鼠标源', () {
    testWidgets('绝不创建/订阅传感器流（防 MissingPluginException 误报）',
        (tester) async {
      final fake = _FakeSensors();
      addTearDown(fake.events.close);
      SensorsPlatform.instance = fake;

      final ctrl = DepthTiltController();
      addTearDown(ctrl.dispose);
      final received = <(double, double)>[];
      final sub = ctrl.stream.listen(received.add);
      addTearDown(sub.cancel);

      expect(ctrl.usesPointerSource, isTrue);
      expect(fake.samplingCalls, isEmpty, reason: 'Windows 分支不得调传感器流');
      expect(ctrl.sensorSubscribedForTest, isFalse);
      // 传感器源里塞事件也不该影响：根本没订阅。
      fake.events.add(AccelerometerEvent(9, 9, 9, DateTime.now()));
      await tester.pump(const Duration(milliseconds: 16));
      expect(received, isEmpty);
      expect(fake.samplingCalls, isEmpty);
    }, variant: windowsVariant);

    testWidgets('合帧：16ms 内多次 hover 只发「最新值」一拍', (tester) async {
      final ctrl = DepthTiltController();
      addTearDown(ctrl.dispose);
      const size = Size(200, 100);
      final received = <(double, double)>[];
      final sub = ctrl.stream.listen(received.add);
      addTearDown(sub.cancel);

      // 同一拍内连写两个目标：只有第二个会出帧。
      ctrl.handleHover(const Offset(120, 50), size); // (0.2, 0)
      expect(ctrl.hasPendingPumpForTest, isTrue);
      ctrl.handleHover(const Offset(200, 100), size); // (1, 1)

      await tester.pump(const Duration(milliseconds: 16));
      expect(received, [(1.0, 1.0)]);

      // 收敛后无在途 Timer → 鼠标静止时零帧请求。
      expect(ctrl.hasPendingPumpForTest, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(received, hasLength(1));
    }, variant: windowsVariant);

    testWidgets('连续移动：每拍出「当时最新」值，互不叠加', (tester) async {
      final ctrl = DepthTiltController();
      addTearDown(ctrl.dispose);
      const size = Size(200, 100);
      final received = <(double, double)>[];
      final sub = ctrl.stream.listen(received.add);
      addTearDown(sub.cancel);

      ctrl.handleHover(const Offset(150, 50), size); // (0.5, 0)
      await tester.pump(const Duration(milliseconds: 16));
      ctrl.handleHover(const Offset(50, 50), size); // (-0.5, 0)
      await tester.pump(const Duration(milliseconds: 16));

      expect(received.length, 2);
      expect(received[0].$1, closeTo(0.5, eps));
      expect(received[1].$1, closeTo(-0.5, eps));
      expect(ctrl.hasPendingPumpForTest, isFalse);
    }, variant: windowsVariant);

    testWidgets('handleExit：目标归零走泵出拍，收敛即停摆', (tester) async {
      final ctrl = DepthTiltController();
      addTearDown(ctrl.dispose);
      const size = Size(200, 100);
      final received = <(double, double)>[];
      final sub = ctrl.stream.listen(received.add);
      addTearDown(sub.cancel);

      ctrl.handleHover(const Offset(200, 100), size);
      await tester.pump(const Duration(milliseconds: 16));
      expect(received, [(1.0, 1.0)]);

      ctrl.handleExit();
      expect(ctrl.hasPendingPumpForTest, isTrue,
          reason: '归零也经泵出拍；本类直发目标值，平滑由 shader 侧 EMA 负责');
      await tester.pump(const Duration(milliseconds: 16));
      expect(received.last, (0.0, 0.0));
      expect(ctrl.hasPendingPumpForTest, isFalse);

      // 已在中心再 exit：零帧请求。
      ctrl.handleExit();
      await tester.pump(const Duration(seconds: 1));
      expect(received, hasLength(2));
    }, variant: windowsVariant);

    testWidgets('退化 size 的 hover 不产生任何帧', (tester) async {
      final ctrl = DepthTiltController();
      addTearDown(ctrl.dispose);
      final received = <(double, double)>[];
      final sub = ctrl.stream.listen(received.add);
      addTearDown(sub.cancel);

      ctrl.handleHover(const Offset(5, 5), Size.zero);
      await tester.pump(const Duration(seconds: 1));
      expect(received, isEmpty);
      expect(ctrl.hasPendingPumpForTest, isFalse);
    }, variant: windowsVariant);

    testWidgets('dispose 后停止一切出帧', (tester) async {
      final ctrl = DepthTiltController();
      const size = Size(200, 100);
      final received = <(double, double)>[];
      final sub = ctrl.stream.listen(received.add);

      ctrl.handleHover(const Offset(200, 100), size);
      ctrl.dispose(); // 泵应被取消
      await tester.pump(const Duration(milliseconds: 16));
      expect(received, isEmpty);
      expect(ctrl.hasPendingPumpForTest, isFalse);
      // 不 await：FakeAsync 里 await broadcast cancel 会挂死框架收尾阶段。
      unawaited(sub.cancel());
      await tester.pump();
    }, variant: windowsVariant);
  });

  group('DepthTiltController · Android 加速度计分支（与现状等价）', () {
    testWidgets('首听订阅 uiInterval，映射等价（/9.81*2.5 → clamp）',
        (tester) async {
      final fake = _FakeSensors();
      addTearDown(fake.events.close);
      SensorsPlatform.instance = fake;

      final ctrl = DepthTiltController();
      addTearDown(ctrl.dispose);
      final received = <(double, double)>[];
      final sub = ctrl.stream.listen(received.add);

      expect(ctrl.usesPointerSource, isFalse);
      // 无人监听时不订阅（平面封面阶段不占传感器）；首听才建立。
      expect(fake.samplingCalls, [SensorInterval.uiInterval]);

      fake.events.add(AccelerometerEvent(2.0, 9.81, 0.0, DateTime.now()));
      await tester.pump();
      // x: 2/9.81*2.5 ≈ 0.5097；y: 9.81/9.81*2.5 = 2.5 → clamp 1.0
      expect(received, hasLength(1));
      expect(received.first.$1, closeTo(2.0 / 9.81 * 2.5, eps));
      expect(received.first.$2, closeTo(1.0, eps));

      // 鼠标接口在 Android 分支被忽略（加速度计是唯一信源）。
      ctrl.handleHover(const Offset(200, 100), const Size(200, 100));
      ctrl.handleExit();
      await tester.pump(const Duration(seconds: 1));
      expect(received, hasLength(1));

      // 不 await：FakeAsync 里 await broadcast cancel 会挂死框架收尾阶段；
      // pump 一拍冲掉 cancel 的收尾微任务后，订阅已释放。
      unawaited(sub.cancel());
      await tester.pump();
      expect(ctrl.sensorSubscribedForTest, isFalse, reason: '末听取消后释放传感器');
    }, variant: androidVariant);

    testWidgets('传感器错误 → 下游 onError + onTiltError 上报宿主', (tester) async {
      final fake = _FakeSensors()..error = StateError('NO_SENSOR');
      SensorsPlatform.instance = fake;

      final hostErrors = <Object>[];
      final ctrl = DepthTiltController(onTiltError: hostErrors.add);
      addTearDown(ctrl.dispose);
      final streamErrors = <Object>[];
      final sub = ctrl.stream.listen(
        (_) {},
        onError: (Object e) => streamErrors.add(e),
      );

      await tester.pump();
      expect(hostErrors, hasLength(1));
      expect(hostErrors.first, isA<StateError>());
      expect(streamErrors, hasLength(1), reason: '既有语义：错误也要发到下游流');

      // 不 await：同上，FakeAsync 里 await broadcast cancel 会挂死收尾。
      unawaited(sub.cancel());
      await tester.pump();
    }, variant: androidVariant);

    testWidgets('取消监听后 dispose 不残留订阅', (tester) async {
      final fake = _FakeSensors();
      addTearDown(fake.events.close);
      SensorsPlatform.instance = fake;

      final ctrl = DepthTiltController();
      final sub = ctrl.stream.listen((_) {});
      // 不 await：同上。
      unawaited(sub.cancel());
      await tester.pump();
      ctrl.dispose();
      await tester.pump();
      expect(ctrl.sensorSubscribedForTest, isFalse);
      expect(fake.samplingCalls, [SensorInterval.uiInterval]);
    }, variant: androidVariant);
  });
}
