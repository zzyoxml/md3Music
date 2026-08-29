// MD3E 三按钮联合动画控件测试
//
// 覆盖：
// - 三个图标（prev / play / next）基本渲染
// - isPlaying 切换图标（play_arrow ↔ pause）
// - 点击触发回调
// - null 回调仍能渲染
// - 动画期间按钮被禁用（防止动画中重复触发）
// - 动画完成后才调用业务回调
// - 切歌动画完成后按钮身份正确（不再错位）：
//   settledToNext 后 _prevLeft 触发 onPrevious、_playLeft 触发 onPlayPause、_nextLeft 触发 onNext
//   settledToPrev 后 _prevLeft 触发 onPrevious、_playLeft 触发 onPlayPause、_nextLeft 触发 onNext
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/md3e_transport_row.dart';

void main() {
  group('MD3ETransportRow 基础渲染', () {
    testWidgets('渲染三个按钮：skip_previous、play_arrow、skip_next', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onPrevious: () {},
                onPlayPause: () {},
                onNext: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
    });

    testWidgets('isPlaying=true 时显示 pause 图标，隐藏 play_arrow', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: true,
                onPlayPause: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('null 回调时按钮仍能渲染不崩溃', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(isPlaying: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
    });
  });

  group('MD3ETransportRow 交互', () {
    testWidgets('点击 play 立即调用 onPlayPause 回调', (tester) async {
      bool playCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onPlayPause: () => playCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.play_arrow));
      // play 是弹性回弹动画，需要 pumpAndSettle 让动画结束
      await tester.pumpAndSettle();
      expect(playCalled, isTrue);
    });

    testWidgets('点击 next 立即调用 onNext 回调（动画结束后）', (tester) async {
      bool nextCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onNext: () => nextCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pumpAndSettle();
      expect(nextCalled, isTrue);
    });

    testWidgets('点击 previous 立即调用 onPrevious 回调（动画结束后）', (tester) async {
      bool prevCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onPrevious: () => prevCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pumpAndSettle();
      expect(prevCalled, isTrue);
    });
  });

  group('MD3ETransportRow 动画锁定', () {
    testWidgets('toNext 动画进行中尝试再次点击应被忽略', (tester) async {
      int nextCallCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onNext: () => nextCallCount++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 第一次点击 next：用 startGesture 精确控制指针，模拟按下后立即松开
      final TestGesture gesture1 = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.skip_next)),
      );
      await gesture1.up();
      // 此时动画已启动（_isAnimating == true），但仅推进 1 帧（< 1ms），
      // _controller.value 远未到 0.5，回调尚未触发
      await tester.pump();
      expect(nextCallCount, 0,
          reason: 'phase2 末段（_controller.value >= 0.5）才触发回调');

      // 第二次点击 next（动画进行中）应被锁定
      await tester.tap(find.byIcon(Icons.skip_next), warnIfMissed: false);
      await tester.pump();

      // 推进 50ms 验证第二次点击被锁定
      await tester.pump(const Duration(milliseconds: 50));
      // _controller.value ≈ 50/350 ≈ 0.14，< 0.5，回调仍未触发
      // 第二次点击被锁定，nextCallCount 仍为 0
      expect(nextCallCount, 0,
          reason: '动画进行中（_controller.value < 0.5），第二次点击被锁定');
      // 手动 pump 到 phase2 末段（_controller.value >= 0.5）
      // 总动画时长 350ms，phase2 末段约 175ms，再推进 150ms 达到 200ms
      await tester.pump(const Duration(milliseconds: 150));
      // _controller.value ≈ 200/350 ≈ 0.57，回调触发，nextCallCount = 1
      expect(nextCallCount, 1, reason: 'phase2 末段触发一次 onNext 回调');
      // pump 到动画结束
      await tester.pumpAndSettle();
      expect(nextCallCount, 1, reason: '总共只调用一次 onNext');
    });

    testWidgets('next 动画完成后 onNext 回调被调用', (tester) async {
      bool nextCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onNext: () => nextCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pumpAndSettle();
      expect(nextCalled, isTrue);
    });

    testWidgets('toPrev 动画完成后 onPrevious 回调被调用', (tester) async {
      bool prevCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onPrevious: () => prevCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pumpAndSettle();
      expect(prevCalled, isTrue);
    });
  });

  group('MD3ETransportRow 切歌后按钮身份', () {
    // Stack 几何（默认 sideButtonSize=56, playButtonSize=72, spacing=8）：
    //   totalWidth = 56 + 8 + 72 + 8 + 56 = 200
    //   _prevLeft = 0   (中心 x=28)
    //   _playLeft = 64  (中心 x=100)
    //   _nextLeft = 144 (中心 x=172)
    //   Stack 中心 = 100
    //   _prevLeft 中心 x 偏移 = -72
    //   _playLeft 中心 x 偏移 = 0
    //   _nextLeft 中心 x 偏移 = +72
    Offset _slotOffset(int dx, Offset stackCenter) => stackCenter + Offset(dx.toDouble(), 0);

    testWidgets('toNext 完成后：_prevLeft 触发 onPrevious，_playLeft 触发 onPlayPause，_nextLeft 触发 onNext', (tester) async {
      int prev = 0, play = 0, next = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onPrevious: () => prev++,
                onPlayPause: () => play++,
                onNext: () => next++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 触发 toNext
      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pumpAndSettle();
      expect(next, 1, reason: '首次 onNext');

      final stackCenter = tester.getCenter(find.byType(MD3ETransportRow));

      // 点击 _prevLeft 位置（已被原 play 接管，应触发 onPrevious）
      await tester.tapAt(_slotOffset(-72, stackCenter));
      await tester.pumpAndSettle();
      expect(prev, 1, reason: 'settledToNext 后 _prevLeft 应触发 onPrevious');
      expect(play, 0);
      expect(next, 1);

      // 点击 _playLeft 位置（已被原 next 接管，应触发 onPlayPause）
      await tester.tapAt(_slotOffset(0, stackCenter));
      await tester.pumpAndSettle();
      expect(play, 1, reason: 'settledToNext 后 _playLeft 应触发 onPlayPause');
      expect(prev, 1);
      expect(next, 1);

      // 点击 _nextLeft 位置（新 next，应触发 onNext）
      await tester.tapAt(_slotOffset(72, stackCenter));
      await tester.pumpAndSettle();
      expect(next, 2, reason: 'settledToNext 后 _nextLeft 应触发 onNext');
    });

    testWidgets('toPrev 完成后：_prevLeft 触发 onPrevious，_playLeft 触发 onPlayPause，_nextLeft 触发 onNext', (tester) async {
      int prev = 0, play = 0, next = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onPrevious: () => prev++,
                onPlayPause: () => play++,
                onNext: () => next++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 触发 toPrev
      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pumpAndSettle();
      expect(prev, 1, reason: '首次 onPrevious');

      final stackCenter = tester.getCenter(find.byType(MD3ETransportRow));

      // 点击 _prevLeft 位置（新 prev，应触发 onPrevious）
      await tester.tapAt(_slotOffset(-72, stackCenter));
      await tester.pumpAndSettle();
      expect(prev, 2, reason: 'settledToPrev 后 _prevLeft 应触发 onPrevious');
      expect(play, 0);
      expect(next, 0);

      // 点击 _playLeft 位置（已被原 prev 接管，应触发 onPlayPause）
      await tester.tapAt(_slotOffset(0, stackCenter));
      await tester.pumpAndSettle();
      expect(play, 1, reason: 'settledToPrev 后 _playLeft 应触发 onPlayPause');

      // 点击 _nextLeft 位置（已被原 play 接管，应触发 onNext）
      await tester.tapAt(_slotOffset(72, stackCenter));
      await tester.pumpAndSettle();
      expect(next, 1, reason: 'settledToPrev 后 _nextLeft 应触发 onNext');
    });
  });

  group('MD3ETransportRow 切歌后按压反馈', () {
    // 查找指定 left 值的 Positioned 内的 Material
    Material _materialAtLeft(WidgetTester tester, double left) {
      return tester.widget<Material>(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is Positioned && w.left == left,
          ),
          matching: find.byType(Material),
        ),
      );
    }

    testWidgets('settledToNext 后按下新 next slot（_nextLeft）有按压反馈（颜色变化）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onNext: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 切到 settledToNext 状态
      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pumpAndSettle();

      final stackCenter = tester.getCenter(find.byType(MD3ETransportRow));
      final colorBefore = _materialAtLeft(tester, 144).color;

      // 按下 _nextLeft 位置
      final gesture = await tester.startGesture(
        stackCenter + const Offset(72, 0),
      );
      // pump 多帧：先让 onTapDown 触发 setState，再让 _pressController forward
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final colorDuring = _materialAtLeft(tester, 144).color;

      expect(colorDuring, isNot(equals(colorBefore)),
          reason: '按下时 _buildNewNextPositioned 的 Material color 应变化（按压反馈）');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('settledToPrev 后按下新 prev slot（_prevLeft）有按压反馈（颜色变化）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MD3ETransportRow(
                isPlaying: false,
                onPrevious: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 切到 settledToPrev 状态
      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pumpAndSettle();

      final stackCenter = tester.getCenter(find.byType(MD3ETransportRow));
      final colorBefore = _materialAtLeft(tester, 0).color;

      // 按下 _prevLeft 位置
      final gesture = await tester.startGesture(
        stackCenter + const Offset(-72, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final colorDuring = _materialAtLeft(tester, 0).color;

      expect(colorDuring, isNot(equals(colorBefore)),
          reason: '按下时 _buildNewPrevPositioned 的 Material color 应变化（按压反馈）');

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
