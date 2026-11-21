import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/discover/discover_skeleton.dart';
import 'package:md3music/widgets/app_animation.dart';

void main() {
  testWidgets('ShimmerLoading 全行程（含水平/倾斜）无 stops/轴越界断言',
      (tester) async {
    // 逐帧推进共享 60fps 节拍：旧实现在 t<0.3 / t>0.7 时 stops 越出 [0,1]
    // 触发 Flutter 断言；倾斜扫光用平移渐变轴，同样要扫满一轮不出错。
    for (final diagonal in [false, true]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: ShimmerLoading(height: 52, diagonal: diagonal),
            ),
          ),
        ),
      ));
      // 1500ms 一轮：每 16ms 步进推进节拍，跑满一整圈。
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull,
          reason: diagonal ? '倾斜扫光扫满一轮不应有异常' : '水平扫光不应有异常');
    }
  });

  testWidgets('歌曲行骨架渲染 4 行、无按钮 / 焦点语义', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DiscoverSongRowsSkeleton()),
      ),
    ));
    await tester.pump();
    final shimmers = find.byType(ShimmerLoading);
    // 4 行 ×（封面 + 标题 + 副标题 + 尾部圆钮位）= 16 块。
    expect(shimmers, findsNWidgets(16));
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('专辑格骨架渲染 4 格、无交互控件', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DiscoverAlbumGridSkeleton()),
      ),
    ));
    await tester.pump();
    // 4 格 ×（封面 + 两行标题）= 12 块。
    expect(find.byType(ShimmerLoading), findsNWidgets(12));
    expect(find.byType(InkWell), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 注意：ShimmerLoading 挂的是 PlayerFrameDriver 的周期 Timer，永远在产帧，
  // 这些用例一律用显式时长 pump，不能用 pumpAndSettle（必然超时）。
  testWidgets('骨架 → 内容：加载期出标题 + 骨架，翻回后淡入替换', (tester) async {
    Widget wrap(bool loading) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DiscoverSectionFadeSwap(
                title: '每日推荐',
                loading: loading,
                skeleton: const DiscoverSongRowsSkeleton(rows: 2),
                content: const Text('真实内容'),
              ),
            ),
          ),
        );

    await tester.pumpWidget(wrap(true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('每日推荐'), findsOneWidget, reason: '标题不依赖网络，冷启动就定稿');
    expect(find.text('真实内容'), findsNothing);
    // 2 行 × 4 块 = 8 块骨架。
    expect(find.byType(ShimmerLoading), findsNWidgets(8));

    await tester.pumpWidget(wrap(false));
    await tester.pump();
    // 交叉淡入进行中：新旧两棵树同时在树上，且都钉在顶边不跳位。
    final skeletonTree =
        find.byKey(const ValueKey('discover-skeleton-每日推荐'));
    final contentTree = find.byKey(const ValueKey('discover-content-每日推荐'));
    expect(contentTree, findsOneWidget);
    expect(skeletonTree, findsOneWidget);
    expect(find.text('真实内容'), findsOneWidget);
    // 2 行 × 4 块 = 8 块骨架仍在（未淡完）。
    expect(find.byType(ShimmerLoading), findsNWidgets(8));
    expect(tester.getTopLeft(skeletonTree), tester.getTopLeft(contentTree),
        reason: 'layoutBuilder 钉顶：淡入过程只有透明度在动，区块不上下跳');

    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump(const Duration(milliseconds: 16));
    // 动画结束后骨架整棵退场，只剩真实内容。
    expect(find.byType(ShimmerLoading), findsNothing);
    expect(find.text('真实内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
