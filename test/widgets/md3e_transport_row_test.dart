// MD3E 三按钮联合动画控件测试
//
// 覆盖：
// - 三个图标（prev / play / next）基本渲染
// - isPlaying 切换图标（play_arrow ↔ pause）
// - 点击触发回调
// - null 回调仍能渲染
// - 动画期间按钮被禁用（防止动画中重复触发）
// - 动画完成后才调用业务回调
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
      // 此时动画已启动（_isAnimating == true），但仅推进 1 帧（< 1ms）
      await tester.pump();

      // 第二次点击 next（动画进行中）
      // 使用 tap 代替 startGesture 来模拟真实用户操作
      await tester.tap(find.byIcon(Icons.skip_next), warnIfMissed: false);
      await tester.pump();

      // 推进 100ms 验证第二次点击被忽略
      await tester.pump(const Duration(milliseconds: 100));
      // 此刻只有第一次的回调完成，第二次被锁定
      expect(nextCallCount, 0,
          reason: '动画进行中（< 450ms），onNext 回调应被锁定');
      // 手动 pump 到动画结束
      await tester.pumpAndSettle();
      expect(nextCallCount, 1, reason: '第一次动画完成后调用一次 onNext');
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
  });
}
