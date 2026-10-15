import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_cover_morph_layer.dart';
import 'package:md3music/widgets/player_artwork_image.dart';

/// 封面形变（mini→full）转场成本的**心电图**回归测试。
///
/// 范式对齐 `test/widgets/playlist_cover_flight_perf_test.dart`：用 debug 计数器
/// 钉住「谁在逐帧付费」。本文件盯三处：
/// - `playerCoverMorphDebugLayerBuilds`：形变层逐帧重建。守门用例，防
///   `player_cover_morph_layer.dart` 顶部记录的「驱动失效、build 只跑一次，
///   整段转场封面凭空消失」的历史坑复发（Listenable.merge / setState 都实测无效，
///   只认 AnimatedBuilder(animation: playerExpansion)）。
/// - `playerCoverMorphDebugArtworkBuilds`：飞行封面子树（PlayerArtworkImage）
///   重配次数。hoist（`_MorphCoverFlight` 的签名 memo）落地后从「每帧 1 次」收敛到
///   「签名变化才 1 次」。
///   **red-first 实测对照**：10 帧飞行 改前 `artworkBuilds = 10` → 改后 `1`；
///   第二程 3 帧 改前 delta = 3 → 改后 `1`。`playerCoverMorphDebugLayerBuilds`
///   两侧都必须等于帧数（它就是守门用例，见下）。
/// - 第 3 组（中途换参）是 hoist 的**安全网**：改前靠整层逐帧重建换图、改后靠 memo
///   签名失效换图，两侧都必须为绿；若哪天签名漏了某个登记簿字段，它会立刻变红。
/// - `playerCoverMorphDebugProbeMeasures`：几何探针实测次数。本轮只记录量级、
///   刻意不收紧（第 5 组不阻断）。门控设计见
///   `docs/plans/2026-10-09-cover-morph-perf-round2.md`。
/// - `CoverMorphFrameTrace`：把一帧拆成 UI 线程（`buildDuration`）与 Raster 线程
///   （`rasterDuration`）的归因探针。最后一组测的是**仪表本身**（avg 分母、max、
///   over8、尾窗、两段不串味）——我们会拿它的数字决定下一轮改哪条线程，
///   单位算错比不测更糟。
void main() {
  // 与 player_cover_morph_test.dart 的 'PlayerCoverMorphLayer' group 同一套几何：
  // 迷你条封面贴左下角 44×44，播放页封面居中 720×720。
  const mini = Rect.fromLTWH(16, 1900, 44, 44);
  const settled = Rect.fromLTWH(180, 400, 720, 720);

  // 0.05 → 0.95，全程在 (0,1) 开区间内推进 10 帧。
  const steps = <double>[
    0.05,
    0.15,
    0.25,
    0.35,
    0.45,
    0.55,
    0.65,
    0.75,
    0.85,
    0.95,
  ];

  late PlayerCoverMorphBus bus;

  setUp(() {
    bus = PlayerCoverMorphBus.instance;
    bus.reset();
    // reset() 不清 coverSuppressed / playerCoverVisible，显式归位，
    // 防其它用例/文件把「写真压制」「封面不可见」的残留状态带进来。
    bus.coverSuppressed = false;
    playerCoverVisible.value = true;
    bus
      ..miniRect = mini
      ..publishFull(
        measured: settled,
        logicalSize: const Size(720, 720),
        pageOffset: Offset.zero,
        songId: 's1',
        artworkUri: null,
        fallbackFilePath: null,
        iconSize: 48,
        placeholderColor: const Color(0xFF000000),
        eligible: true,
        settledArtworkScale: 1.0,
        settledArtworkAnchor: Alignment.center,
      );
    coverMorphDebugResetCounters();
  });

  // playerExpansion 与登记簿都是全局单例，必须复位，否则污染其它用例
  tearDown(() {
    playerExpansion.value = 0.0;
    bus.reset();
    coverMorphDebugResetCounters();
  });

  Future<void> pumpLayer(WidgetTester tester) => tester.pumpWidget(
        const MaterialApp(
          home: Stack(children: [PlayerCoverMorphLayer()]),
        ),
      );

  // 只在形变层自己的子树里找，避免命中 MaterialApp 内部的同名控件
  Finder layerClip() => find.descendant(
        of: find.byType(PlayerCoverMorphLayer),
        matching: find.byType(ClipRRect),
      );

  Finder layerArtwork() => find.descendant(
        of: find.byType(PlayerCoverMorphLayer),
        matching: find.byType(PlayerArtworkImage),
      );

  /// 屏幕上真正生效的圆角 = 局部半径 × scale（子树被 Transform 缩放）。
  /// 与 player_cover_morph_test.dart 的 screenRadiusAt 同一算法。
  double screenRadiusAt(WidgetTester tester, double p) {
    final local = (tester.widget<ClipRRect>(layerClip()).borderRadius
            as BorderRadius)
        .topLeft
        .x;
    final targetWidth = 44 + (720 - 44) * p;
    return local * (targetWidth / 720);
  }

  group('守门（必须绿）', () {
    testWidgets('转场每一帧形变层都真的在重建：layerBuilds 逐帧 +1，圆角逐帧变化', (
      tester,
    ) async {
      // 先以 p=0 挂载（真机 App 启动态），端点早退不计数。
      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      expect(
        playerCoverMorphDebugLayerBuilds,
        0,
        reason: 'p=0 端点由 MiniPlayer 独显，形变层早退，不应计数',
      );

      final radii = <double>[];
      var expected = 0;
      for (final p in steps) {
        playerExpansion.value = p;
        await tester.pump();
        expected++;
        expect(
          playerCoverMorphDebugLayerBuilds,
          expected,
          reason: '第 $expected 帧推进应恰好新增 1 次层重建（多=重复驱动，少=监听失效）',
        );
        radii.add(screenRadiusAt(tester, p));
      }

      // 推进了 10 帧（>=2），且逐帧 +1 已在循环内钉死。
      expect(playerCoverMorphDebugLayerBuilds, steps.length);
      expect(playerCoverMorphDebugLayerBuilds, greaterThanOrEqualTo(2));

      // 圆角逐帧变化：屏幕半径 = 6 + (16-6) × t，t 直接等于 expansion。
      for (var i = 0; i < radii.length; i++) {
        expect(
          radii[i],
          closeTo(6 + 10 * steps[i], 1e-6),
          reason: 'p=${steps[i]} 的屏幕圆角',
        );
        if (i > 0) {
          expect(
            radii[i],
            greaterThan(radii[i - 1]),
            reason: '圆角必须逐帧推进，出现平台帧即驱动失效',
          );
        }
      }
    });

    testWidgets('探针基线：静态挂载 30 帧只记录实测次数，不阻断', (tester) async {
      // 本 harness 只挂形变层，CoverGeometryProbe 在 MiniPlayer / 播放页槽位里，
      // 不在层子树内 → 实测计数恒为 0。留此用例是为了 hoist 落地后
      // 仍能在同一坐标系里对照探针量级（本轮刻意不收紧探针成本）。
      // 基线记录（red-first 轮）：30 帧 pump 后 playerCoverMorphDebugProbeMeasures = 0。
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      for (var i = 0; i < 30; i++) {
        await tester.pump();
      }
      expect(playerCoverMorphDebugProbeMeasures, greaterThan(-1));
    });
  });

  group('hoist 目标（飞行封面子树只构建 1 次；改前基线 = 每帧 1 次）', () {
    testWidgets('整段飞行封面子树只构建 1 次', (
      tester,
    ) async {
      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      for (final p in steps) {
        playerExpansion.value = p;
        await tester.pump();
      }
      // 守门前提先钉住：形变层确实逐帧重建了 10 帧。
      expect(playerCoverMorphDebugLayerBuilds, steps.length);
      // 飞行全程封面参数（矩形/样式/资源）没有任何变化，hoist 后
      // PlayerArtworkImage 应只构建 1 次；改前基线 = 10（每帧重配，预期红）。
      expect(
        playerCoverMorphDebugArtworkBuilds,
        1,
        reason: '签名全程未变，飞行封面子树应 memo 复用；改前基线为每帧 1 次',
      );
    });
  });

  group('签名失效（安全网：中途换参必须重构建恰好 1 次，改前改后都该绿）', () {
    /// 飞行中途改一个绘制参数 → **下一帧（转场中进度照常推进）**必须：
    /// 1) artworkBuilds 恰好 +1（多=浪费，少=签名漏项）；
    /// 2) PlayerArtworkImage 的 widget 实例已更换；
    /// 3) 飞行层 ClipRRect 仍在（不许出现「谁都不画」的空洞）。
    ///
    /// 推进 `playerExpansion` 是必要的：形变层只被它驱动，真机上转场每帧进度都在
    /// 变，若这里 pump 时不改变它，连「今天的实现」都不会重建（首版测试就踩了这个
    /// 假红）。这三条是 hoist 的**安全网**：改前改后都该为绿——改前靠整层逐帧重建
    /// 换图，改后靠 memo 签名失效换图。真正的目标用例是上面那组「只构建 1 次」。
    Future<void> expectSignatureInvalidation(
      WidgetTester tester, {
      required String label,
      String? artworkUri,
      String? fallbackFilePath,
      double? iconSize,
      Color? placeholderColor,
    }) async {
      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      playerExpansion.value = 0.5;
      await tester.pump();

      final buildsBefore = playerCoverMorphDebugArtworkBuilds;
      final instanceBefore = tester.widget<PlayerArtworkImage>(layerArtwork());

      bus.publishFull(
        measured: settled,
        logicalSize: const Size(720, 720),
        pageOffset: Offset.zero,
        songId: 's1',
        // null 走播种默认值；本 helper 每次只覆盖 label 指定的那一个参数。
        artworkUri: artworkUri,
        fallbackFilePath: fallbackFilePath,
        iconSize: iconSize ?? 48,
        placeholderColor: placeholderColor ?? const Color(0xFF000000),
        eligible: true,
        settledArtworkScale: 1.0,
        settledArtworkAnchor: Alignment.center,
      );
      // 转场还在跑：下一帧进度必然在变，形变层才会被驱动去读新的登记值。
      playerExpansion.value = 0.6;
      await tester.pump();

      expect(
        playerCoverMorphDebugArtworkBuilds - buildsBefore,
        1,
        reason: '$label 中途变更必须让飞行封面恰好重构建一次（多=浪费，少=签名漏项）',
      );
      expect(
        identical(
          tester.widget<PlayerArtworkImage>(layerArtwork()),
          instanceBefore,
        ),
        isFalse,
        reason: '$label 变更后 PlayerArtworkImage 的 widget 实例必须已更换',
      );
      expect(
        layerClip(),
        findsOneWidget,
        reason: '$label 切换不得留下封面空洞（形变层必须仍在画）',
      );
    }

    testWidgets('artworkUri 中途变更', (tester) async {
      await expectSignatureInvalidation(
        tester,
        label: 'artworkUri',
        artworkUri: 'https://example.com/cover-2.jpg',
      );
    });

    testWidgets('iconSize 中途变更', (tester) async {
      await expectSignatureInvalidation(
        tester,
        label: 'iconSize',
        iconSize: 52,
      );
    });

    testWidgets('placeholderColor 中途变更', (tester) async {
      await expectSignatureInvalidation(
        tester,
        label: 'placeholderColor',
        placeholderColor: const Color(0xFF112233),
      );
    });

    testWidgets('fallbackFilePath 中途变更', (tester) async {
      await expectSignatureInvalidation(
        tester,
        label: 'fallbackFilePath',
        fallbackFilePath: '/tmp/cover_fallback.jpg',
      );
    });
  });

  group('端点复位（缓存不得跨转场泄漏）', () {
    testWidgets('p 推到 1.0 再拉回 0.5，第二次转场封面重新构建', (tester) async {
      playerExpansion.value = 0.0;
      await pumpLayer(tester);

      // 第一程：推进一帧即止（单帧基线）。
      playerExpansion.value = 0.5;
      await tester.pump();
      expect(playerCoverMorphDebugArtworkBuilds, 1);

      // 推到 1.0 端点：飞行子树整体 dispose（hoist 后其 memo 缓存须随之释放）。
      playerExpansion.value = 1.0;
      await tester.pump();
      expect(
        layerClip(),
        findsNothing,
        reason: '端点 p=1 交还播放页，飞行子树不得残留',
      );

      // 第二程：3 帧、签名全程不变。
      // - hoist 正确落地 → 恰好再构建 1 次（缓存不跨转场泄漏 ⇒ 不是 0；
      //   memo 复用 ⇒ 不是 3）；
      // - 改前基线 = 3（每帧重配，预期红）；若 hoist 把缓存做成全局且不复位，
      //   第二程会是 0，同样被本断言拦下。
      final beforeSecond = playerCoverMorphDebugArtworkBuilds;
      for (final p in [0.3, 0.6, 0.9]) {
        playerExpansion.value = p;
        await tester.pump();
      }
      expect(
        playerCoverMorphDebugArtworkBuilds - beforeSecond,
        1,
        reason: '第二次转场必须重新构建（不跨转场泄漏缓存），且同程内 memo 复用',
      );
    });
  });

  group('线程归因探针（CoverMorphFrameTrace）', () {
    // 这组测的是**仪表本身**：avg 的分母、max、over8、尾窗、两段不串味。
    // 我们会拿它打印的数字决定下一轮改 UI 线程还是 Raster 线程，
    // 所以单位算错比不测更糟——它会把人领到反方向。
    final trace = CoverMorphFrameTrace.instance;

    /// 合成一帧：`buildUs` / `rasterUs` 分别是 UI 与 Raster 线程耗时（微秒）。
    FrameTiming frame({required int buildUs, required int rasterUs}) =>
        FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: buildUs,
          rasterStart: buildUs,
          rasterFinish: buildUs + rasterUs,
          rasterFinishWallTime: 0,
        );

    setUp(() => trace.debugResetTrace());
    tearDown(() => trace.debugResetTrace());

    testWidgets('聚合正确：avg 用实际入账帧数、max 与 over8 各自统计', (
      tester,
    ) async {
      for (var i = 0; i < 3; i++) {
        trace.noteFlightFrame(progress: 0.5, drag: false);
      }
      trace.debugFeedTimings([
        frame(buildUs: 2000, rasterUs: 4000),
        frame(buildUs: 4000, rasterUs: 1000),
        frame(buildUs: 1000, rasterUs: 8001), // 唯一一个超 8ms 预算
      ]);
      trace.debugFlushNow();

      final line = trace.debugSummaries.single;
      expect(line, contains('frames=3'));
      expect(line, contains('timed=3'));
      // build 合计 7000us ÷ 3 = 2333us；max 4000us
      expect(line, contains('build=avg2.3/max4.0ms'));
      // raster 合计 13001us ÷ 3 = 4333us；max 8001us → 显示 8.0
      expect(line, contains('raster=avg4.3/max8.0ms'));
      expect(line, contains('over8=1'));
      expect(line, matches(RegExp(r'fps=\d+\.\d')));
    });

    testWidgets('收口后的尾批：迟到的 timing 仍入账后才打印', (tester) async {
      // 引擎在帧结束后才上报；若端点立刻打印，最后 1~2 帧会稳定丢失，
      // 把 max 报得偏乐观。所以收口只标 closing，由下一批 timing 触发冲刷。
      // 这条钉住该语义：closing 后到达的第一批必须先入账、再打印。
      trace.noteFlightFrame(progress: 0.5, drag: false);
      trace.closeFlight();
      expect(trace.debugSummaries, isEmpty, reason: '收口不当场打印，要等尾窗');

      trace.debugFeedTimings([frame(buildUs: 1000, rasterUs: 9000)]);
      trace.debugFlushNow();

      final line = trace.debugSummaries.single;
      expect(line, contains('timed=1'));
      expect(line, contains('raster=avg9.0/max9.0ms'));
      expect(line, contains('over8=1'));
    });

    testWidgets('新转场起爆时先冲刷上一段，两段样本不混行', (tester) async {
      trace.noteFlightFrame(progress: 0.5, drag: false);
      trace.debugFeedTimings([frame(buildUs: 5000, rasterUs: 1000)]);
      trace.closeFlight();

      // 上一段还在尾窗里等，下一段就起爆了：必须先冲刷 A。
      trace.noteFlightFrame(progress: 0.5, drag: false);
      trace.debugFeedTimings([frame(buildUs: 1000, rasterUs: 1000)]);
      trace.debugFlushNow();

      expect(trace.debugSummaries, hasLength(2));
      expect(trace.debugSummaries[0], contains('build=avg5.0'));
      expect(trace.debugSummaries[1], contains('build=avg1.0'));
      expect(trace.debugSummaries[1], contains('timed=1'));
    });

    testWidgets('最坏三帧：按总跨度排序，并把跨度拆成 UI/GPU', (tester) async {
      // 段级 avg 会骗人：真机上有若干段 build avg 只有 5ms，却出现 41~83ms 的单帧。
      // 所以必须把最坏那几帧单独拆成 UI 与 GPU 两段，才知道下一刀往哪边落。
      trace.noteFlightFrame(progress: 0.5, drag: false);
      trace.debugFeedTimings([
        frame(buildUs: 1000, rasterUs: 2000), // 跨 3.0
        frame(buildUs: 5000, rasterUs: 7000), // 跨 12.0
        frame(buildUs: 100, rasterUs: 100), // 跨 0.2 → 挤不进前三
        frame(buildUs: 8000, rasterUs: 20000), // 跨 28.0 → 最坏
        frame(buildUs: 4000, rasterUs: 1000), // 跨 5.0
      ]);
      trace.debugFlushNow();

      final line = trace.debugSummaries.single;
      expect(
        line,
        contains('worst=28.0/8.0/20.0,12.0/5.0/7.0,5.0/4.0/1.0'),
        reason: '格式 跨度/UI/GPU，按跨度降序，只留三个',
      );
      expect(line, isNot(contains('0.2/0.1/0.1')));
    });

    testWidgets('不在转场中的帧不污染归因', (tester) async {
      trace.noteFlightFrame(progress: 0.5, drag: false);
      trace.debugFeedTimings([frame(buildUs: 3000, rasterUs: 3000)]);
      trace.closeFlight();
      trace.debugFlushNow();
      final flushed = trace.debugSummaries.length;

      // 桶已关闭：此后到来的帧（例如静止期的常规刷新）不该再进任何一行。
      trace.debugFeedTimings([frame(buildUs: 99999, rasterUs: 99999)]);
      expect(trace.debugSummaries, hasLength(flushed));
    });
  });

  group('取证仪表（UI 热点 / 帧间隔）', () {
    // 这一组盯的是**仪表本身有没有接上**：挂点若漏挂或写成空转，日志会显示
    // 热点全是 0，我们就会误判「成本不在形变层」——那比没有仪表更危险。
    final trace = CoverMorphFrameTrace.instance;

    setUp(() => trace.debugResetTrace());
    tearDown(() => trace.debugResetTrace());

    test('帧间隔分位：median 才是刷新率判据，mean 会被长帧拉偏', () {
      // 8 帧 8.3ms 档 + 一根 100ms 长帧：中位必须仍是 8300us。
      final samples = <int>[
        8300,
        8300,
        8300,
        8300,
        8300,
        8300,
        8300,
        8300,
        100000,
      ];
      final gap = CoverMorphFrameTrace.debugPercentilesOf(samples);
      expect(gap.median, 8300, reason: 'median 不受长帧影响 → ≈8.3ms 即 120Hz');
      expect(gap.max, 100000);
      expect(gap.p95, greaterThanOrEqualTo(8300));

      // 空列表与单元素都不能除零或越界。
      expect(CoverMorphFrameTrace.debugPercentilesOf(const <int>[]).median, 0);
      expect(CoverMorphFrameTrace.debugPercentilesOf(const <int>[7000]).median,
          7000);
    });

    testWidgets('形变层逐帧重建时 layer 热点次数必须等于帧数（防挂点空转）', (
      tester,
    ) async {
      const steps = <double>[0.1, 0.2, 0.3, 0.4, 0.5];
      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      for (final p in steps) {
        playerExpansion.value = p;
        await tester.pump();
      }
      expect(playerCoverMorphDebugLayerBuilds, steps.length);

      trace.debugFlushNow();
      final line = trace.debugSummaries.single;
      // `layer` 与 `cover` 都在每帧的形变层里；次数为 0 就说明计时壳没接上。
      expect(line, contains('layer=avg'));
      expect(line, contains('(n=${steps.length})'),
          reason: '热点次数必须等于帧数，否则日志会骗人说「成本不在形变层」');
      expect(line, contains('cover=avg'));
      expect(line, contains('pageBuilds=0'),
          reason: '只挂形变层的 harness 里整页不该 build');
      expect(line, contains('gapMed='));
      expect(line, contains('resid='));
    });

    testWidgets('热点 avg 用各自次数做分母，探针两次/帧不被摊薄', (tester) async {
      // 喂**确定的** µs 值而不是让 coverMorphHot 去实测真实耗时：本用例要验的是
      // avg 的分母是每个热点自己的次数（不是帧数、也不是别的热点的次数）。
      // 真实耗时是机敏感的——全量 -j 4 并行时一次空闭包能测到 0.1ms，
      // 拿它写死断言就是一条偶发红（我自己踩过一次）。
      trace.noteFlightFrame(progress: 0.5, drag: false);
      trace.noteHot('probe', 3000);
      trace.noteHot('probe', 5000); // (3000+5000)/2 = 4.0，max 5.0
      trace.noteHot('layer', 1000); // 只看自己那一次：avg 1.0
      trace.debugFlushNow();

      final line = trace.debugSummaries.single;
      expect(line, contains('probe=avg4.0/max5.0ms(n=2)'));
      expect(line, contains('layer=avg1.0/max1.0ms(n=1)'));
    });

    test('coverMorphHot 透传返回值并在关闭探针时仍然执行', () {
      // 计时壳最容易踩的坑是「包一层就把返回值吞了」。
      expect(coverMorphHot('layer', () => 42), 42);
      expect(coverMorphHot('panel', () => 'ok'), 'ok');
    });
  });

  group('仪表 v3（段身份 + 阶段归因）', () {
    // B3 的判据被 11 段基线否证过一次，根因是日志里的段说不出「我是哪种转场」。
    // 所以从现在起每行必须自带 kind/dir，且阶段热点必须真的挂上——
    // 挂点漏了日志就会显示 n=0，我们又去怀疑「成本不在页面里」。
    final trace = CoverMorphFrameTrace.instance;

    setUp(() => trace.debugResetTrace());
    tearDown(() => trace.debugResetTrace());

    test('段身份：拖拽帧决定 kind，进度走向决定 dir，且逐段复位', () {
      // ① 拖拽 + 推进 → drag / expand
      trace.noteFlightFrame(progress: 0.1, drag: true);
      trace.noteFlightFrame(progress: 0.6, drag: false);
      trace.debugFlushNow();
      expect(trace.debugSummaries.single, contains('kind=drag'));
      expect(trace.debugSummaries.single, contains('dir=expand'));

      // ② 全程没有拖拽帧 + 进度回落 → tap / collapse
      trace.noteFlightFrame(progress: 0.9, drag: false);
      trace.noteFlightFrame(progress: 0.2, drag: false);
      trace.debugFlushNow();
      final second = trace.debugSummaries.last;
      expect(second, contains('kind=tap'));
      expect(second, contains('dir=collapse'));
      // 上一段的 drag 不得泄漏到这一段（桶复位是身份可信的前提）
      expect(second, isNot(contains('kind=drag')));
    });

    testWidgets('形变层飞行时三棵阶段热点必须逐帧计数（防挂点空转）', (
      tester,
    ) async {
      // 文字侧要两端矩形都发布，否则 textWillDraw 为假、文字块根本不产出。
      bus.publishMiniText(
        rect: const Rect.fromLTWH(60, 1900, 200, 36),
        title: '歌名',
        subtitle: '歌手',
        titleStyle: const TextStyle(fontSize: 14),
        subtitleStyle: const TextStyle(fontSize: 12),
      );
      bus.publishFullText(
        measured: const Rect.fromLTWH(32, 540, 336, 60),
        logicalSize: const Size(336, 60),
        pageOffset: Offset.zero,
        title: '歌名',
        subtitle: '歌手 · 专辑',
        titleStyle: const TextStyle(fontSize: 24),
        subtitleStyle: const TextStyle(fontSize: 14),
        align: Alignment.center,
        eligible: true,
      );

      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      const flight = <double>[0.2, 0.5, 0.8];
      for (final p in flight) {
        playerExpansion.value = p;
        await tester.pump();
      }
      trace.debugFlushNow();
      final line = trace.debugSummaries.single;

      // 封面与文字两棵都在飞行子树里：每帧都得重画（矩阵/圆角/字号逐帧变）。
      expect(hotN(line, 'coverPaint'), flight.length,
          reason: '飞行封面没挂上阶段热点，封面那笔 paint 会永远落在 resid 里');
      expect(hotN(line, 'textPaint'), flight.length);
      // 文字块每帧换字号 → 必然重排；封面那棵只改矩阵，重排次数本就少，
      // 所以只要求它被记到过（n=0 才是挂点失效的信号）。
      expect(hotN(line, 'textLayout'), flight.length);
      expect(hotN(line, 'coverLayout'), greaterThanOrEqualTo(1));
      // 本 harness 只有形变层、没有面板 → 整页那两棵必须一次都没有。
      expect(hotN(line, 'pageLayout'), 0);
      expect(hotN(line, 'pagePaint'), 0);
    });

    testWidgets('阶段热点分得清「重排」与「只重画」，且不改几何', (
      tester,
    ) async {
      // 探针的语义就是本轮要拿来二分的：换尺寸=重排，换颜色=只重画。
      Widget tree({required double size, required Color color}) => Align(
            alignment: Alignment.topLeft,
            child: CoverMorphPhaseProbe(
              layoutKey: 'pageLayout',
              paintKey: 'pagePaint',
              child: SizedBox(
                width: size,
                height: size,
                child: ColoredBox(color: color),
              ),
            ),
          );

      /// 先开桶再 pump：热点是在这一帧的 layout/paint 阶段写的，桶没开就全丢。
      Future<String> segment(Widget tree) async {
        trace.noteFlightFrame(progress: 0.5, drag: false);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: tree)),
        );
        trace.debugFlushNow();
        return trace.debugSummaries.last;
      }

      final first = await segment(tree(size: 100, color: Colors.red));
      expect(hotN(first, 'pageLayout'), 1, reason: '首帧各一次：少挂或空转会停在 0');
      expect(hotN(first, 'pagePaint'), 1);

      final second = await segment(tree(size: 100, color: Colors.blue));
      expect(hotN(second, 'pagePaint'), 1, reason: '换颜色要重画');
      expect(hotN(second, 'pageLayout'), 0,
          reason: '约束没变就不该重排，否则「layout 大」这个信号没有区分力');

      final third = await segment(tree(size: 140, color: Colors.blue));
      expect(hotN(third, 'pageLayout'), 1, reason: '换尺寸必然重排');

      expect(tester.getSize(find.byType(CoverMorphPhaseProbe)),
          const Size(140, 140),
          reason: 'RenderProxyBox 必须原样透传约束——它不该改变几何');
    });
  });

  group('治 textLayout（进度档位 + 无界排版）', () {
    // 真机 v3 定案：`textLayout avg 3~5.6ms、n = 帧数`，形变层每帧都在重排文字。
    // 这一组钉两件事：① 样式只在跨档位时才换值（相邻帧能复用就不标脏、不重排）；
    // ② 段落的排版键里不含逐帧变化的块宽（省略号那行改成无界 + 裁切）。
    test('coverMorphTextSteppedProgress：吸附到 1/8 档，端点精确，非有限值按 0', () {
      expect(coverMorphTextSteppedProgress(0.0), 0.0);
      expect(coverMorphTextSteppedProgress(1.0), 1.0);
      expect(coverMorphTextSteppedProgress(0.11), 0.125);
      expect(coverMorphTextSteppedProgress(0.05), 0.0);
      expect(coverMorphTextSteppedProgress(0.5), 0.5);
      // 越界与脏输入都不能把样式推出两端之外。
      expect(coverMorphTextSteppedProgress(2.0), 1.0);
      expect(coverMorphTextSteppedProgress(double.nan), 0.0);
    });

    test('回归（行间距突变）：每个字段只能走自己量程的一档', () {
      // 第一版给每个字段单独定**绝对**步长：fontSize 2dp、字距与行高 1dp。
      // 但 `TextStyle.height` 是倍数（行高 = fontSize × height），按 1.0 吸附时
      // 插值一旦跨过 1.5 就从 1.0 跳到 2.0 —— 行盒当场翻倍，真机表现为
      // 「拖动过程中行间距会突变」。这一条把「跳变量受量程约束」钉成数字。
      const mini = TextStyle(
        fontSize: 16,
        height: 1.43,
        letterSpacing: 0.3,
        fontWeight: FontWeight.w500,
      );
      const full = TextStyle(
        fontSize: 22,
        height: 1.5,
        letterSpacing: 0.6,
        fontWeight: FontWeight.w500,
      );

      double maxJump(double Function(TextStyle) read, double span) {
        TextStyle? prev;
        var worst = 0.0;
        for (var i = 0; i <= 40; i++) {
          final s = coverMorphLerpTextStyle(mini, full, i / 40)!;
          final p = prev;
          if (p != null) {
            final delta = (read(s) - read(p)).abs();
            if (delta > worst) worst = delta;
          }
          prev = s;
        }
        // 单档跳变不得超过「量程 ÷ 档数」（多给一点浮点余量）。
        expect(worst, lessThanOrEqualTo(span / kCoverMorphTextSteps + 1e-9),
            reason: '超过就说明某个字段在按绝对步长跳，不是在按量程分档');
        return worst;
      }

      expect(maxJump((s) => s.fontSize!, 6.0), greaterThan(0.0));
      expect(maxJump((s) => s.height!, 0.07), greaterThan(0.0));
      expect(maxJump((s) => s.letterSpacing!, 0.3), greaterThan(0.0));
    });

    test('端点必须逐位等于原样式（含不在档位上的字号），开区间内才分档', () {
      const mini = TextStyle(fontSize: 15, fontWeight: FontWeight.w500);
      const full = TextStyle(fontSize: 25, fontWeight: FontWeight.w500);
      // 15 / 25 都不在 1/8 档的整数位上（25−15=10，除不尽 8）：若端点也被档位化，
      // 交接那一帧会比真实文字差半档。
      expect(coverMorphLerpTextStyle(mini, full, 0.0), mini);
      expect(coverMorphLerpTextStyle(mini, full, 1.0), full);

      // 开区间推进 12 帧：同档位的相邻帧必须给出**相等**的样式值。
      final styles = [
        for (var i = 1; i <= 12; i++)
          coverMorphLerpTextStyle(mini, full, i / 13)!,
      ];
      final distinct = styles.toSet();
      expect(distinct.length, lessThan(styles.length),
          reason: '值相等是 RenderParagraph 不标脏的唯一依据；全不相等＝档位化没生效');
      expect(distinct.length, lessThanOrEqualTo(7));
    });

    testWidgets('飞行途中标题样式逐帧复用，且没有逐帧紧约束排版', (
      tester,
    ) async {
      // 中文标题两串通常同串（`歌名` vs `歌名`.toUpperCase()）→ 走的是非 append
      // 那一支，原先那里是 `Align + ellipsis`，段落每帧拿到新的块宽就重排。
      bus.publishMiniText(
        rect: const Rect.fromLTWH(60, 1900, 240, 36),
        title: '歌名',
        subtitle: '歌手',
        titleStyle: const TextStyle(fontSize: 14),
        subtitleStyle: const TextStyle(fontSize: 14),
      );
      bus.publishFullText(
        measured: const Rect.fromLTWH(32, 540, 336, 60),
        logicalSize: const Size(336, 60),
        pageOffset: Offset.zero,
        title: '歌名',
        subtitle: '歌手',
        titleStyle: const TextStyle(fontSize: 24),
        subtitleStyle: const TextStyle(fontSize: 24),
        align: Alignment.center,
        eligible: true,
      );

      playerExpansion.value = 0.0;
      await pumpLayer(tester);

      final titleFinder = find.descendant(
        of: find.byType(PlayerCoverMorphLayer),
        matching: find.byType(Text),
      );
      final styles = <TextStyle?>[];
      for (var i = 1; i <= 12; i++) {
        playerExpansion.value = i / 13;
        await tester.pump();
        styles.add(tester.widgetList<Text>(titleFinder).first.style);
      }

      expect(styles.whereType<TextStyle>().toSet().length,
          lessThan(styles.length),
          reason: '相邻帧必须能复用同一套样式值，否则文字每帧重新排版');

      // 排版宽度无界：两行都由 OverflowBox 兜宽，块宽进不了段落的排版键。
      expect(
        find.descendant(
          of: find.byType(PlayerCoverMorphLayer),
          matching: find.byType(OverflowBox),
        ),
        findsAtLeastNWidgets(2),
      );
      for (final text in tester.widgetList<Text>(titleFinder)) {
        expect(text.overflow, isNot(TextOverflow.ellipsis),
            reason: '飞行途中打省略号、松手又消失，是这里明确要避免的穿帮');
        expect(text.softWrap, isFalse);
      }
    });
  });
}

/// 从一行摘要里取出某个热点的次数；没出现返回 -1。
///
/// 摘要里的热点格式是 `key=avg0.0/max0.0ms(n=3)`，**只断言 n**：avg/max 是机敏感的，
/// 在 `-j 4` 并行下空闭包都能测出 0.1ms，写死数值就是偶发红（本文件踩过一次）。
int hotN(String line, String key) {
  final match = RegExp('$key=.*?\\(n=(\\d+)\\)').firstMatch(line);
  return match == null ? -1 : int.parse(match.group(1)!);
}
