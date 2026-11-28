import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/modules/player/sleep_timer_dial.dart';

void main() {
  group('表盘数学', () {
    test('钳制区间是 1–1440 分钟，且不取整', () {
      expect(kSleepTimerMinMinutes, 1);
      expect(kSleepTimerMaxMinutes, 1440);
      expect(clampSleepTimerMinutes(0), 1);
      expect(clampSleepTimerMinutes(-100), 1);
      expect(clampSleepTimerMinutes(9999), 1440);
      expect(clampSleepTimerMinutes(90.4), 90.4);
    });

    test('dialAngleOf：12 点为 0，顺时针递增', () {
      expect(dialAngleOf(const Offset(0, -10)), closeTo(0, 1e-9));
      expect(dialAngleOf(const Offset(10, 0)), closeTo(math.pi / 2, 1e-9));
      expect(dialAngleOf(const Offset(0, 10)), closeTo(math.pi, 1e-9));
      expect(dialAngleOf(const Offset(-10, 0)), closeTo(3 * math.pi / 2, 1e-9));
    });

    test('advanceSleepTimerMinutes：顺时针跨 12 点进位到下一圈', () {
      final delta = (10 / 60) * 2 * math.pi;
      expect(advanceSleepTimerMinutes(55, delta), closeTo(65, 1e-9));
      expect(advanceSleepTimerMinutes(55, delta) ~/ 60, 1);
    });

    test('advanceSleepTimerMinutes：逆时针退回 0 钳到 1 分钟', () {
      final delta = -(40 / 60) * 2 * math.pi;
      expect(advanceSleepTimerMinutes(20, delta), 1);
    });

    test('advanceSleepTimerMinutes：24 小时封顶且继续顺时针不再前进', () {
      final delta = (30 / 60) * 2 * math.pi;
      expect(advanceSleepTimerMinutes(1430, delta), 1440);
      expect(advanceSleepTimerMinutes(1440, delta), 1440);
    });

    test('advanceSleepTimerMinutes：转满一整圈正好 +60 分钟', () {
      expect(advanceSleepTimerMinutes(30, 2 * math.pi), closeTo(90, 1e-9));
    });

    test('无级：亚分钟级的转动量不会被量化掉', () {
      // 回归点：早期实现在这里 round() 到整分钟，指针就以 6° 为步长跳格，
      // 手感是「卡」而不是「跟手」。
      final quarterMinute = (0.25 / 60) * 2 * math.pi;
      expect(advanceSleepTimerMinutes(30, quarterMinute), closeTo(30.25, 1e-9));
      expect(
        advanceSleepTimerMinutes(30, -quarterMinute),
        closeTo(29.75, 1e-9),
      );
    });
  });

  group('表盘 Widget', () {
    // 跨整点时 `AppHaptics.tick` 会走原生通道，并挂一个 300ms 的超时回落定时器。
    // 测试里把 vibrate 一律回 true（原生已处理），否则测试结束会撞上
    // "A Timer is still pending even after the widget tree was disposed"。
    const hapticsChannel = MethodChannel('md3music/haptics');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        hapticsChannel,
        (call) async => call.method == 'vibrate' ? true : null,
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hapticsChannel, null);
    });

    /// 表盘放在 300×300 的方框里（与 maxSize 一致，便于按角度算像素坐标）。
    Widget host({
      required int minutes,
      required ValueChanged<int> onChanged,
      required VoidCallback onStart,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: _DialHost(
              initialMinutes: minutes,
              onChanged: onChanged,
              onStart: onStart,
            ),
          ),
        ),
      );
    }

    /// [minutes] 刻度处、半径 112（= 300 / 2 × 0.7467）的坐标。
    Offset markFor(Rect rect, int minutes) {
      final c = rect.center;
      final a = -math.pi / 2 + (minutes / 60) * 2 * math.pi;
      return c + Offset(112 * math.cos(a), 112 * math.sin(a));
    }

    /// 从 [from] 刻度拖到 [to] 刻度（可跨 12 点）。
    ///
    /// 必须先在**同角度**上沿半径方向移动一段越过 touch slop：Flutter 只在越过
    /// slop 后才认定起拖，并把那一刻的位置交给 `onPanStart`（首移动本身被吞
    /// 掉），所以分两段走才能让完整角差在一次 `onPanUpdate` 里兑现。
    Future<void> dragMark(
      WidgetTester tester,
      Rect rect,
      int from,
      int to,
    ) async {
      final start = markFor(rect, from);
      final outward = (start - rect.center) / 112 * 40; // 40px > kTouchSlop
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(outward);
      await gesture.moveBy(markFor(rect, to) - start - outward);
      await gesture.up();
      // pump 走过 AppHaptics 的 300ms 窗口，并让最后一帧绘出来
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
    }

    testWidgets('中央显示小时与分钟', (tester) async {
      await tester.pumpWidget(
        host(minutes: 135, onChanged: (_) {}, onStart: () {}),
      );
      await tester.pump();

      expect(find.text('2 小时'), findsOneWidget);
      expect(find.text('15 分钟'), findsOneWidget);
    });

    testWidgets('24 小时封顶时显示 24 小时 0 分钟', (tester) async {
      await tester.pumpWidget(
        host(minutes: 1440, onChanged: (_) {}, onStart: () {}),
      );
      await tester.pump();

      expect(find.text('24 小时'), findsOneWidget);
      expect(find.text('0 分钟'), findsOneWidget);
    });

    testWidgets('拖动指针跨过 12 点：小时 +1（套圈）', (tester) async {
      var minutes = 55;
      await tester.pumpWidget(
        host(
          minutes: minutes,
          onChanged: (v) => minutes = v,
          onStart: () {},
        ),
      );
      await tester.pump();

      final rect = tester.getRect(find.byType(SleepTimerDial));
      await dragMark(tester, rect, 55, 65);

      expect(minutes, 65, reason: '跨过 12 点应从 0h55m 走到 1h05m');
      expect(find.text('1 小时'), findsOneWidget);
      expect(find.text('5 分钟'), findsOneWidget);
    });

    testWidgets('按下表盘不吸附：值不会跳到手指位置', (tester) async {
      var minutes = 55;
      await tester.pumpWidget(
        host(
          minutes: minutes,
          onChanged: (v) => minutes = v,
          onStart: () {},
        ),
      );
      await tester.pump();

      final rect = tester.getRect(find.byType(SleepTimerDial));
      // 按在 20 分钟刻度上直接抬起：值必须还是 55（纯相对拖动，不做 press-to-set）
      final gesture = await tester.startGesture(markFor(rect, 20));
      await gesture.up();
      await tester.pump();

      expect(minutes, 55, reason: '按下不应把指针吸到手指所在角度');
    });

    testWidgets('逆时针拖回 0 之前会被钳到 1 分钟', (tester) async {
      var minutes = 20;
      await tester.pumpWidget(
        host(
          minutes: minutes,
          onChanged: (v) => minutes = v,
          onStart: () {},
        ),
      );
      await tester.pump();

      final rect = tester.getRect(find.byType(SleepTimerDial));
      await dragMark(tester, rect, 20, 0);

      expect(minutes, 1);
    });

    testWidgets('点击中央形状触发开始', (tester) async {
      var started = false;
      await tester.pumpWidget(
        host(minutes: 45, onChanged: (_) {}, onStart: () => started = true),
      );
      await tester.pump();

      await tester.tapAt(tester.getRect(find.byType(SleepTimerDial)).center);
      await tester.pump();

      expect(started, isTrue);
    });
  });
}

/// 表盘宿主：**必须自己持有并回写分钟数**。
///
/// 真实用法里（Task 6 的 `sleep_timer_sheet.dart`）由 `StatefulBuilder` 负责，
/// 若宿主像「只用局部变量接住回调」那样不重建，`widget.minutes` 会一直是初值，
/// 中央文字也就永远停在初始值。
class _DialHost extends StatefulWidget {
  const _DialHost({
    required this.initialMinutes,
    required this.onChanged,
    required this.onStart,
  });

  final int initialMinutes;
  final ValueChanged<int> onChanged;
  final VoidCallback onStart;

  @override
  State<_DialHost> createState() => _DialHostState();
}

class _DialHostState extends State<_DialHost> {
  late int _minutes = widget.initialMinutes;

  @override
  Widget build(BuildContext context) {
    return SleepTimerDial(
      minutes: _minutes,
      onChanged: (v) {
        setState(() => _minutes = v);
        widget.onChanged(v);
      },
      onStart: widget.onStart,
    );
  }
}
