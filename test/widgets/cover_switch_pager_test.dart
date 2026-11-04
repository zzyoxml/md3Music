import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/cover_switch_physics.dart';
import 'package:md3music/modules/player/widgets/cover_switch_pager.dart';

/// 测试用页尺寸：side 300 + gap 14 = pitch 314。
const double _side = 300;
const double _pitch = 314;

Widget _page(String label) => Container(
  key: ValueKey<String>(label),
  color: const Color(0xFF336699),
  alignment: Alignment.center,
  child: Text(label),
);

Widget _host({
  required GlobalKey<CoverSwitchPagerState> key,
  required List<String> labels,
  required List<CoverSwitchIntent> commits,
  bool canGoPrevious = true,
  bool canGoNext = true,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: CoverSwitchPager(
        key: key,
        side: _side,
        radius: 12,
        pages: [for (final l in labels) _page(l)],
        canGoPrevious: canGoPrevious,
        canGoNext: canGoNext,
        onCommit: commits.add,
      ),
    ),
  ),
);

void main() {
  testWidgets('静止时当前页居中，相邻页各偏一页宽；卡内图像带静止视差', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: []),
    );

    final pagerCenter = tester.getCenter(find.byType(CoverSwitchPager));

    // 卡片框（帧）：当前页居中，相邻页各偏整整一页 pitch
    final frameCurrent = tester.getRect(
      find.byKey(const ValueKey<String>('cover-frame-0')),
    );
    final frameNext = tester.getRect(
      find.byKey(const ValueKey<String>('cover-frame-1')),
    );
    expect(frameCurrent.center.dx, closeTo(pagerCenter.dx, 0.01));
    expect(frameNext.center.dx - frameCurrent.center.dx, closeTo(_pitch, 0.01));

    // 卡内图像：当前页零视差（与框重合）；下一首虽在视口外，其图像已按
    // lag × 一页朝视口中央偏 —— 这就是「静止也不回到零视差」的那一层。
    final artCurrent = tester.getCenter(find.byKey(const ValueKey<String>('B')));
    final artNext = tester.getCenter(find.byKey(const ValueKey<String>('C')));
    expect(artCurrent.dx, closeTo(pagerCenter.dx, 0.01));
    expect(
      frameNext.center.dx - artNext.dx,
      closeTo(kCoverParallaxLag * _pitch, 0.01),
    );

    expect(key.currentState!.progress, 0);
    expect(key.currentState!.isSettled, isTrue);
  });

  testWidgets('拖动时卡内图像滞后于卡片框：图像比框更靠视口中央', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: []),
    );
    final pagerCenter = tester.getCenter(find.byType(CoverSwitchPager));

    // 拖到 0.5 页（pitch/2 = 157）
    final gesture = await tester.startGesture(pagerCenter);
    await gesture.moveBy(const Offset(-157, 0));
    await tester.pump();

    final frame = tester.getRect(
      find.byKey(const ValueKey<String>('cover-frame-0')),
    );
    final art = tester.getCenter(find.byKey(const ValueKey<String>('B')));

    // 框已经滑到视口中央左侧
    expect(frame.center.dx, lessThan(pagerCenter.dx - 10));
    // 图像被拉回框的右侧（朝视口中央），差量正好是 lag × 半页。
    // 注意符号：框在中央左侧时图像往右偏，所以是 art - frame 为正。
    expect(art.dx, greaterThan(frame.center.dx));
    expect(
      art.dx - frame.center.dx,
      closeTo(kCoverParallaxLag * _pitch * 0.5, 1.5),
    );
    // 视差让图像比框更靠中央，但没被推过中央
    expect((art.dx - pagerCenter.dx).abs(), lessThan((frame.center.dx - pagerCenter.dx).abs()));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('静止时不残留产帧（无待调度帧、无瞬时回调）', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: []),
    );
    await tester.pumpAndSettle();

    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('跟手拖动：进度与手指位移 1:1', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: []),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CoverSwitchPager)),
    );
    await gesture.moveBy(const Offset(-157, 0));
    await tester.pump();

    expect(key.currentState!.progress, closeTo(157 / _pitch, 0.02));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('松手位移过半 → 提交下一首，并滑到 +1 停住', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    final commits = <CoverSwitchIntent>[];
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: commits),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CoverSwitchPager)),
    );
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(commits, [CoverSwitchIntent.next]);
    expect(key.currentState!.hasPendingCommit, isTrue);
    expect(key.currentState!.progress, closeTo(1, 1e-6));
  });

  testWidgets('真实切歌后 rebase(delta) 把进度折回 0，画面零跳变', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    final commits = <CoverSwitchIntent>[];
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: commits),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CoverSwitchPager)),
    );
    // 拖 160px（≈0.51 页）：避开「正好半页」（157px）那一像素——它是「过半」判据的
    // 边界，coverSettleTarget 用闭区间比较（>= 0.5 / <= -0.5），正好半页会被判成
    // 翻页。rebase 后相对新列表只剩 0.49 页（不过半），松手应回弹到 0。
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();

    // 拖动途中真实切歌：页列表整体前移一位（A 退成上一首、B 变当前、C 变下一首）
    final beforeB = tester.getCenter(find.byKey(const ValueKey<String>('B')));
    await tester.pumpWidget(
      _host(key: key, labels: ['B', 'C', 'A'], commits: commits),
    );
    key.currentState!.rebase(1);
    await tester.pump();

    final afterB = tester.getCenter(find.byKey(const ValueKey<String>('B')));
    expect(afterB.dx, closeTo(beforeB.dx, 0.01));
    expect(key.currentState!.progress, closeTo(160 / _pitch - 1, 0.02));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.progress, closeTo(0, 1e-6));
  });

  testWidgets('没有下一首时越界只做橡皮筋，松手回弹到 0 且不提交', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    final commits = <CoverSwitchIntent>[];
    await tester.pumpWidget(
      _host(
        key: key,
        labels: ['A', 'B', 'C'],
        commits: commits,
        canGoNext: false,
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CoverSwitchPager)),
    );
    await gesture.moveBy(const Offset(-260, 0));
    await tester.pump();
    final overscrolled = key.currentState!.progress;
    expect(overscrolled, greaterThan(0));
    expect(overscrolled, lessThan(kCoverOverscrollPages));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
    expect(key.currentState!.progress, closeTo(0, 1e-6));
  });

  testWidgets('提交后 provider 始终没换歌 → 守卫超时回弹到 0', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    final commits = <CoverSwitchIntent>[];
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: commits),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CoverSwitchPager)),
    );
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(key.currentState!.progress, closeTo(1, 1e-6));
    expect(key.currentState!.hasPendingCommit, isTrue);

    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pumpAndSettle();

    expect(key.currentState!.hasPendingCommit, isFalse);
    expect(key.currentState!.progress, closeTo(0, 1e-6));
  });

  testWidgets('方向未知的切歌：resetToIdle 立即归零，不做滑动', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: []),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CoverSwitchPager)),
    );
    await gesture.moveBy(const Offset(-157, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    key.currentState!.resetToIdle();
    await tester.pumpAndSettle();

    expect(key.currentState!.progress, 0);
    expect(key.currentState!.isSettled, isTrue);
  });

  testWidgets('playChange(+1)：先瞬移到 -1 再滑回 0，视口里始终是同一件内容', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    // 切歌前：A 是上一首、B 是当前、C 是下一首，视口中央是当前曲目 B。
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: []),
    );
    final beforeB = tester.getCenter(find.byKey(const ValueKey<String>('B')));

    // 真实切歌（B → C）：页列表整体前移一位（B 退成上一首），playChange(+1) 把进度
    // 瞬移到 -1 —— 此刻视口中央仍是刚播完的 B（画面零跳变），再补间回 0 让新封面
    // C 从右侧滑入。瞬移与页列表重建必须在同一帧生效（时序同 _onPlayerSongChanged），
    // 故先瞬移再重建页列表。
    key.currentState!.playChange(1);
    await tester.pumpWidget(
      _host(key: key, labels: ['B', 'C', 'A'], commits: []),
    );

    final afterB = tester.getCenter(find.byKey(const ValueKey<String>('B')));
    expect(afterB.dx, closeTo(beforeB.dx, 0.01));

    await tester.pumpAndSettle();
    // 收敛到 0 后当前曲目（C）居中；与 pager 自身中心比对，不写死像素。
    final centerOfPager = tester.getCenter(find.byType(CoverSwitchPager));
    final settledC = tester.getCenter(find.byKey(const ValueKey<String>('C')));
    expect(settledC.dx, closeTo(centerOfPager.dx, 0.01));
  });

  testWidgets('快速甩动：位移远不到一半也翻页（惯性判定）', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    final commits = <CoverSwitchIntent>[];
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: commits),
    );

    // 有效位移只有 60px（≈0.19 页，**远不到一半**），但以 3000px/s 甩出。
    // 没有惯性判定的实现会在这里弹回（旧版阈值量纲写错，甩动分支永不触发）；
    // 有惯性判定必须推进一整页。
    await tester.fling(
      find.byType(CoverSwitchPager),
      const Offset(-60, 0),
      3000,
    );
    await tester.pump();

    expect(commits, [CoverSwitchIntent.next]);
    await tester.pumpAndSettle();
    expect(key.currentState!.progress, closeTo(1, 0.01));
    expect(key.currentState!.hasPendingCommit, isTrue);
  });

  testWidgets('反向快速甩动：推进到上一首', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    final commits = <CoverSwitchIntent>[];
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: commits),
    );

    await tester.fling(
      find.byType(CoverSwitchPager),
      const Offset(60, 0),
      3000,
    );
    await tester.pump();

    expect(commits, [CoverSwitchIntent.previous]);
    await tester.pumpAndSettle();
    expect(key.currentState!.progress, closeTo(-1, 0.01));
  });

  testWidgets('慢拖不到一半再松手（手指已停住）：回弹到 0，不提交', (tester) async {
    final key = GlobalKey<CoverSwitchPagerState>();
    final commits = <CoverSwitchIntent>[];
    await tester.pumpWidget(
      _host(key: key, labels: ['A', 'B', 'C'], commits: commits),
    );

    // tester.drag 的指针事件时间戳相同 → 速度≈0，走「位移过半」规则。
    await tester.drag(find.byType(CoverSwitchPager), const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(commits, isEmpty);
    expect(key.currentState!.progress, closeTo(0, 0.01));
    expect(key.currentState!.isSettled, isTrue);
  });
}
