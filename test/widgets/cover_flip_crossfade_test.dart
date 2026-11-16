import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/widgets/cover_flip_crossfade.dart';
import 'package:md3music/widgets/player_artwork_image.dart';

Widget _host({
  required String? version,
  required Widget child,
  String? fallbackFilePath,
  bool enabled = true,
  double radius = 0.0,
  int direction = 1,
  Duration readyTimeout = kCoverFlipReadyTimeout,
  Future<bool> Function(String?, double, double)? probe,
}) => MaterialApp(
  home: CoverFlipCrossfade(
    version: version,
    fallbackFilePath: fallbackFilePath,
    iconSize: 48,
    enabled: enabled,
    radius: radius,
    direction: direction,
    readyTimeout: readyTimeout,
    readinessProbe: probe,
    child: child,
  ),
);

Widget _art(String id) => ColoredBox(
  color: const Color(0xFF202020),
  child: SizedBox.expand(child: Center(child: Text(id))),
);

/// 立即就绪的探测（等价旧行为：version 变化即翻）。
Future<bool> _readyNow(String? _, double _, double _) async => true;

/// 等翻转真正启动再返回。
///
/// 就绪探测在微任务里完成、ticker 首帧 elapsed 恒为 0（`_startTime ??=`），
/// 翻转比 version 变化晚 1~2 帧——轮询到 Transform 在场即视为已启动
/// （此刻 t≈0）。不等它会拿到「前一帧还没翻」的旧状态。
Future<void> _awaitFlipStart(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    if (find.byType(Transform).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('翻转未在 160ms 内启动');
}

void main() {
  testWidgets('version 不变：只有一层封面，无滤镜无变换', (tester) async {
    await tester.pumpWidget(_host(version: 'a', child: _art('a')));
    await tester.pumpAndSettle();

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(Transform), findsNothing);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('旧值为 null（首图）：不演过渡，直接显示', (tester) async {
    await tester.pumpWidget(_host(version: null, child: _art('a')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(version: 'a', child: _art('a')));
    await tester.pumpAndSettle();

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('version 变化：前半程旧封面模糊+旋转，后半程新封面翻入', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow),
    );
    // 等翻转启动，再推进 100ms（t≈0.33，前半程）：
    // 旧层（PlayerArtworkImage）还在（模糊 + 旋转），新层是 child 本身、
    // 已侧立在 90°（在树中但不可见）。
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PlayerArtworkImage), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    final transform = tester.widget<Transform>(find.byType(Transform).first);
    // 旋转矩阵非单位（角度已离开 0）
    expect(transform.transform.entry(0, 0), lessThan(1.0));

    // 再推进 200ms（累计约 316ms，t≈0.63，后半程）：交接已过，旧层退场，
    // 只剩新层（仍在翻入 + 去模糊）。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(PlayerArtworkImage), findsNothing);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.text('b'), findsOneWidget);

    // 收敛：只剩新封面一层，滤镜与变换都撤掉
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(Transform), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('收敛后零产帧（不留 Ticker）', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow),
    );
    await tester.pumpAndSettle();

    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('连切：旧层取当前显示版本，收敛后只剩最新封面', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow),
    );
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(
      _host(version: 'c', child: _art('c'), probe: _readyNow),
    );
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));

    // 过渡窗口内：旧层应为 b（此刻正在显示的那张），不是更早的 a
    final oldLayer = tester.widget<PlayerArtworkImage>(
      find.byType(PlayerArtworkImage),
    );
    expect(oldLayer.artworkUri, 'b');

    await tester.pumpAndSettle();
    expect(find.text('c'), findsOneWidget);
    expect(find.byType(PlayerArtworkImage), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('enabled=false：直接换，不演过渡', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), enabled: false),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), enabled: false),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(Transform), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });

  // ── 圆角裁剪：每层先裁圆角再旋转，外层不裁（修复「上下边缘被裁」） ──

  testWidgets('空闲态按半径裁圆角', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), radius: 12),
    );
    await tester.pumpAndSettle();

    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(clip.borderRadius, BorderRadius.circular(12));
  });

  testWidgets('翻转中：裁剪在 Transform 之内（旋转不被外层裁）', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), radius: 12, probe: _readyNow),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), radius: 12, probe: _readyNow),
    );
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));

    final transformFinder = find.byType(Transform).first;
    // Transform 上方没有 ClipRRect（外层不裁旋转）
    expect(
      find.ancestor(
        of: transformFinder,
        matching: find.byType(ClipRRect),
      ),
      findsNothing,
    );
    // Transform 下方有 ClipRRect（每层各自先裁圆角再旋转）
    expect(
      find.descendant(
        of: transformFinder,
        matching: find.byType(ClipRRect),
      ),
      findsOneWidget,
    );
  });

  // ── 就绪门控：新图没就绪不翻，等到了才翻（修复「动画消失」） ──

  testWidgets('direction=-1 与 +1 镜像（旧层旋转矩阵符号相反）', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow, direction: 1),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow, direction: 1),
    );
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final forward = tester
        .widget<Transform>(find.byType(Transform).first)
        .transform;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow, direction: -1),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow, direction: -1),
    );
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final backward = tester
        .widget<Transform>(find.byType(Transform).first)
        .transform;

    // 同一进度下旧层旋转角符号相反（entry(0,2) = sin(angle)）
    expect(forward.entry(0, 2), greaterThan(0));
    expect(backward.entry(0, 2), lessThan(0));
    // 且幅度相等（纯镜像，不含其它差异）
    expect(forward.entry(0, 2), closeTo(-backward.entry(0, 2), 1e-9));
  });

  testWidgets('新层以镜像透视翻入：前后两半场的旋转符号相反', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow),
    );

    // 前半程（t≈0.26）：旧层 a 在转，entry(0,2)=sin(angle) > 0 ⇒ 右侧大
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 80));
    final oldSin = tester
        .widget<Transform>(find.byType(Transform).first)
        .transform
        .entry(0, 2);
    expect(oldSin, greaterThan(0));

    // 后半程（t≈0.66）：旧层退场，只剩新层 b，sin < 0 ⇒ 左侧大
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(PlayerArtworkImage), findsNothing);
    final newSin = tester
        .widget<Transform>(find.byType(Transform).first)
        .transform
        .entry(0, 2);
    expect(newSin, lessThan(0));

    await tester.pumpAndSettle();
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('新层翻转过冲回弹：末段角度越过就位角再回正', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow),
    );
    await _awaitFlipStart(tester);
    // 推进到约 90% 总时程：新层处于 easeOutBack 过冲段（旧层已退场，
    // 树上只剩新层一个 Transform，其角度从 −90° 越过 0 短暂转正）。
    await tester.pump(const Duration(milliseconds: 450));
    final transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.transform.entry(0, 2), greaterThan(0));

    // 收敛后回正
    await tester.pumpAndSettle();
    expect(find.byType(Transform), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('就绪探测未完成：只显示旧封面，不翻', (tester) async {
    final gate = Completer<bool>();
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: (_, _, _) => gate.future),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: (_, _, _) => gate.future),
    );
    await tester.pump();

    // 等待中：旧封面原地不动，无滤镜无变换，新封面不在树上
    expect(find.byType(Transform), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(
      tester
          .widget<PlayerArtworkImage>(find.byType(PlayerArtworkImage))
          .artworkUri,
      'a',
    );
    expect(find.text('b'), findsNothing);

    // 放行就绪 → 翻转开始
    gate.complete(true);
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ImageFiltered), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('版本未变的重建不打断在飞的翻转', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow),
    );
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));

    // 模拟播放页其它异步 setState（歌词到达 / 设置读取）造成的同版本重建
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: _readyNow),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 翻转必须还在继续：没被取消、没被掐断
    expect(find.byType(Transform), findsWidgets);
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('b'), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('版本未变的重建不取消就绪等待', (tester) async {
    final gate = Completer<bool>();
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: (_, _, _) => gate.future),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: (_, _, _) => gate.future),
    );
    await tester.pump();
    // 等待中：新封面不在树上
    expect(find.text('b'), findsNothing);

    // 同版本重建（歌词/setState）：等待必须继续
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: (_, _, _) => gate.future),
    );
    await tester.pump();
    expect(find.text('b'), findsNothing);

    // 放行就绪 → 照样翻转
    gate.complete(true);
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('就绪等待中再切歌：旧层保持当前显示版本，过期结果丢弃', (
    tester,
  ) async {
    final gateB = Completer<bool>();
    final gateC = Completer<bool>();
    var call = 0;
    await tester.pumpWidget(
      _host(
        version: 'a',
        child: _art('a'),
        probe: (_, _, _) => call++ == 0 ? gateB.future : gateC.future,
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(
        version: 'b',
        child: _art('b'),
        probe: (_, _, _) => call++ == 0 ? gateB.future : gateC.future,
      ),
    );
    await tester.pump();
    // 等待 b 就绪：屏幕上是 a
    expect(
      tester
          .widget<PlayerArtworkImage>(find.byType(PlayerArtworkImage))
          .artworkUri,
      'a',
    );

    await tester.pumpWidget(
      _host(
        version: 'c',
        child: _art('c'),
        probe: (_, _, _) => call++ == 0 ? gateB.future : gateC.future,
      ),
    );
    await tester.pump();
    // 旧层仍是 a（此刻正在显示的那张），等待目标换成 c
    expect(
      tester
          .widget<PlayerArtworkImage>(find.byType(PlayerArtworkImage))
          .artworkUri,
      'a',
    );

    // b 的迟到就绪必须被丢弃（已经切到 c 了）
    gateB.complete(true);
    await tester.pump();
    expect(find.byType(Transform), findsNothing);

    // c 就绪 → a→c 翻转
    gateC.complete(true);
    await _awaitFlipStart(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('c'), findsOneWidget);
  });

  testWidgets('就绪超时：放弃动画直接换图', (tester) async {
    final gate = Completer<bool>(); // 永不完成
    await tester.pumpWidget(
      _host(
        version: 'a',
        child: _art('a'),
        probe: (_, _, _) => gate.future,
        readyTimeout: const Duration(milliseconds: 100),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(
        version: 'b',
        child: _art('b'),
        probe: (_, _, _) => gate.future,
        readyTimeout: const Duration(milliseconds: 100),
      ),
    );
    await tester.pump();
    // 超时前：还在等
    expect(find.text('b'), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    // 超时：旧层退场，直接换图，无动画
    expect(find.byType(Transform), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('探测返回 false（加载失败）：不演过渡，直接换图', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: (_, _, _) async => false),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', child: _art('b'), probe: (_, _, _) async => false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(Transform), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('新 version 为 null（占位元数据）：不演过渡，直接换图', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(version: 'a', child: _art('a'), probe: _readyNow),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: null, child: _art('b'), probe: _readyNow),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(Transform), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });
}
