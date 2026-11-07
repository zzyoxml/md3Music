import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/ui_density.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_cover_morph_layer.dart';

void main() {
  group('coverMorphSettledRect', () {
    test('页面位移为 0 时原样返回', () {
      expect(
        coverMorphSettledRect(
          measured: const Rect.fromLTWH(40, 300, 360, 360),
          pageOffset: Offset.zero,
          pageToScreen: 1.0,
        ),
        const Rect.fromLTWH(40, 300, 360, 360),
      );
    });

    test('减去页面位移（1.0 缩放档）', () {
      expect(
        coverMorphSettledRect(
          measured: const Rect.fromLTWH(40, 300, 360, 360),
          pageOffset: const Offset(0, 100),
          pageToScreen: 1.0,
        ),
        const Rect.fromLTWH(40, 200, 360, 360),
      );
    });

    test('非 1.0 显示档：页面位移按缩放比换算到屏幕坐标', () {
      expect(
        coverMorphSettledRect(
          measured: const Rect.fromLTWH(40, 600, 720, 720),
          pageOffset: const Offset(0, 100),
          pageToScreen: 2.0,
        ),
        const Rect.fromLTWH(40, 400, 720, 720),
      );
    });
  });

  group('coverSettledVisualRect（暂停态落点）', () {
    const layout = Rect.fromLTWH(100, 400, 400, 400);

    test('scale=1（播放中）原样返回', () {
      expect(
        coverSettledVisualRect(
          layout: layout,
          scale: 1.0,
          anchor: Alignment.center,
        ),
        layout,
      );
    });

    test('scale=0.85 + center：绕中心缩到 85%，中心不变', () {
      final r = coverSettledVisualRect(
        layout: layout,
        scale: 0.85,
        anchor: Alignment.center,
      );
      expect(r.width, closeTo(340, 1e-9));
      expect(r.height, closeTo(340, 1e-9));
      expect(r.center.dx, closeTo(layout.center.dx, 1e-9));
      expect(r.center.dy, closeTo(layout.center.dy, 1e-9));
    });

    test('scale=0.85 + bottomLeft：左缘、下缘保持不动，只向右上收', () {
      final r = coverSettledVisualRect(
        layout: layout,
        scale: 0.85,
        anchor: Alignment.bottomLeft,
      );
      expect(r.left, closeTo(layout.left, 1e-9));
      expect(r.bottom, closeTo(layout.bottom, 1e-9));
      // 右缘、上缘向内收
      expect(r.right, lessThan(layout.right));
      expect(r.top, greaterThan(layout.top));
    });

    test('scale<=0 视为退化，返回布局矩形（不产生负尺寸）', () {
      expect(
        coverSettledVisualRect(
          layout: layout,
          scale: 0,
          anchor: Alignment.center,
        ),
        layout,
      );
    });

    test('暂停态落点比满尺寸小：形变层收尾不会在交接后多出一段缩放', () {
      final playing = coverSettledVisualRect(
        layout: layout,
        scale: 1.0,
        anchor: Alignment.bottomLeft,
      );
      final paused = coverSettledVisualRect(
        layout: layout,
        scale: 0.85,
        anchor: Alignment.bottomLeft,
      );
      expect(paused.width, lessThan(playing.width));
      expect(paused, isNot(playing));
    });
  });

  group('coverMorphTargetRect', () {
    const mini = Rect.fromLTWH(20, 1800, 44, 44);
    const settled = Rect.fromLTWH(180, 400, 720, 720);

    test('两端严格等于端点（与真实封面像素对齐，无弓高）', () {
      expect(coverMorphTargetRect(mini: mini, settled: settled, t: 0), mini);
      expect(coverMorphTargetRect(mini: mini, settled: settled, t: 1), settled);
    });

    test('中点：横向线性，纵向带向上弓高', () {
      final mid = coverMorphTargetRect(mini: mini, settled: settled, t: 0.5);
      final linearY = mini.center.dy + (settled.center.dy - mini.center.dy) * 0.5;
      expect(mid.center.dx, closeTo((mini.center.dx + settled.center.dx) / 2, 0.001));
      expect(mid.center.dy, lessThan(linearY));
      expect(mid.width, closeTo(44 + (720 - 44) * 0.5, 0.001));
    });

    test('t 越界被钳进 [0,1]', () {
      expect(coverMorphTargetRect(mini: mini, settled: settled, t: -1), mini);
      expect(coverMorphTargetRect(mini: mini, settled: settled, t: 2), settled);
    });
  });

  group('coverMorphFlightRect（封面飞行的平抛轨迹）', () {
    // 与 coverMorphTargetRect 那组同一套端点：迷你条贴左下的小方块、播放页居中方块。
    const mini = Rect.fromLTWH(20, 1800, 44, 44);
    const settled = Rect.fromLTWH(180, 400, 720, 720);
    // 端点圆心与边长的跨度，下面按平抛公式手算期望值时要用。
    const dxSpan = 540 - 42; // 横向：mini 圆心 42 → settled 圆心 540
    const dySpan = 760 - 1822; // 纵向：向上，所以是负值
    const sizeSpan = 720 - 44;

    Rect flight(double t) =>
        coverMorphFlightRect(mini: mini, settled: settled, t: t);

    test('两端严格等于端点（交接处与真实封面像素对齐）', () {
      expect(flight(0), mini);
      expect(flight(1), settled);
    });

    test('t 越界被钳进 [0,1]', () {
      expect(flight(-1), mini);
      expect(flight(2), settled);
    });

    test('横向圆心匀速（线性），纵向圆心按 t² 加速', () {
      // 平抛的两条分量：x ∝ t，y ∝ t²。
      for (final t in [0.25, 0.5, 0.75]) {
        final q = t * t;
        final c = flight(t).center;
        expect(
          c.dx,
          closeTo(42 + dxSpan * t, 0.001),
          reason: 't=$t 的横向应等于线性插值',
        );
        expect(
          c.dy,
          closeTo(1822 + dySpan * q, 0.001),
          reason: 't=$t 的纵向应等于 t² 插值',
        );
      }
    });

    test('中点纵向落后于直线（先横移、后上冲），但仍严格位于两端之间', () {
      final mid = flight(0.5);
      final linearY = 1822 + dySpan * 0.5;
      expect(
        mid.center.dy,
        greaterThan(linearY),
        reason: '起段向上少：中点必须比直线更靠下（更贴近迷你条）',
      );
      expect(mid.center.dy, lessThan(mini.center.dy));
      expect(mid.center.dy, greaterThan(settled.center.dy));
    });

    test('边长同样按 t² 先慢后快（中点 213，不是线性的 382）', () {
      expect(flight(0.25).width, closeTo(44 + sizeSpan * 0.0625, 0.001));
      expect(flight(0.5).width, closeTo(44 + sizeSpan * 0.25, 0.001));
      expect(flight(0.75).width, closeTo(44 + sizeSpan * 0.5625, 0.001));
    });

    test('早段位移以横向为主、末段以纵向为主（这就是平抛的观感）', () {
      final early = flight(0.2).center - flight(0.1).center;
      final late = flight(1.0).center - flight(0.9).center;
      expect(
        early.dy.abs(),
        lessThan(early.dx.abs()),
        reason: '起段：横移多、上移少',
      );
      expect(
        late.dy.abs(),
        greaterThan(late.dx.abs()),
        reason: '末段：上移多、横移少',
      );
    });

    test('收起原路返回：同一个 t 在升序与降序两条采样序列上矩形逐位相等', () {
      // 轨迹必须是 t 的**纯函数**（不含方向/时序状态），下拉收起才会精确重合。
      final up = [
        for (var i = 0; i <= 10; i++) flight(i / 10),
      ];
      final down = [
        for (var i = 10; i >= 0; i--) flight(i / 10),
      ];
      for (var i = 0; i <= 10; i++) {
        expect(
          up[i],
          down[10 - i],
          reason: 't=${i / 10}：展开与收起落在同一矩形才是原路返回',
        );
      }
    });

    test('非方形端点不崩（宽高各自插值）', () {
      final r = coverMorphFlightRect(
        mini: const Rect.fromLTWH(0, 1000, 40, 20),
        settled: const Rect.fromLTWH(100, 100, 200, 400),
        t: 0.5,
      );
      expect(r.width, closeTo(40 + 160 * 0.25, 0.001));
      expect(r.height, closeTo(20 + 380 * 0.25, 0.001));
    });
  });

  group('coverMorphAcceleratedProgress（平抛的竖直项）', () {
    test('端点精确、中途是 t²', () {
      expect(coverMorphAcceleratedProgress(0), 0.0);
      expect(coverMorphAcceleratedProgress(0.25), closeTo(0.0625, 1e-12));
      expect(coverMorphAcceleratedProgress(0.5), closeTo(0.25, 1e-12));
      expect(coverMorphAcceleratedProgress(0.75), closeTo(0.5625, 1e-12));
      expect(coverMorphAcceleratedProgress(1), 1.0);
    });

    test('越界钳进 [0,1]，非有限值退化成 0', () {
      expect(coverMorphAcceleratedProgress(-1), 0.0);
      expect(coverMorphAcceleratedProgress(2), 1.0);
      expect(coverMorphAcceleratedProgress(double.nan), 0.0);
    });
  });

  group('文字形变（歌曲名 + 歌手）', () {
    late PlayerCoverMorphBus bus;

    setUp(() {
      bus = PlayerCoverMorphBus.instance;
      bus.reset();
    });
    tearDown(() {
      playerExpansion.value = 0.0;
      bus.reset();
    });

    test('未登记端点时不画，MiniPlayer 文字必须保持显示（否则留洞）', () {
      bus.textEligible = true;
      expect(bus.textWillDraw, isFalse);
    });

    test('资格为假时不画（锁存值与封面相互独立）', () {
      bus
        ..miniTextRect = const Rect.fromLTWH(60, 1900, 200, 36)
        ..settledTextRect = const Rect.fromLTWH(32, 540, 336, 60);
      expect(bus.textWillDraw, isFalse);
      bus.textEligible = true;
      expect(bus.textWillDraw, isTrue);
    });

    test('矩形尺寸为 0（退化）时不画', () {
      bus
        ..textEligible = true
        ..miniTextRect = const Rect.fromLTWH(60, 1900, 200, 36)
        ..settledTextRect = Rect.zero;
      expect(bus.textWillDraw, isFalse);
    });

    test('两套文字都登记后，绘制参数齐备', () {
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
      expect(bus.miniTextRect, const Rect.fromLTWH(60, 1900, 200, 36));
      expect(bus.settledTextRect, const Rect.fromLTWH(32, 540, 336, 60));
      expect(bus.fullTitleText, '歌名');
      expect(bus.fullSubtitleText, '歌手 · 专辑');
      expect(bus.fullTitleAlign, Alignment.center);
      expect(bus.textWillDraw, isTrue);
    });

    test('publishFullText 同样按页面位移换算归位矩形', () {
      bus.publishFullText(
        measured: const Rect.fromLTWH(32, 640, 336, 60),
        logicalSize: const Size(336, 60),
        pageOffset: const Offset(0, 100),
        title: 't',
        subtitle: 's',
        titleStyle: null,
        subtitleStyle: null,
        align: Alignment.centerLeft,
        eligible: true,
      );
      expect(bus.settledTextRect, const Rect.fromLTWH(32, 540, 336, 60));
    });

    test('相同输入不触发 revision（逐帧空转保护）', () {
      void publish() => bus.publishMiniText(
            rect: const Rect.fromLTWH(60, 1900, 200, 36),
            title: '歌名',
            subtitle: '歌手',
            titleStyle: const TextStyle(fontSize: 14),
            subtitleStyle: const TextStyle(fontSize: 12),
          );
      publish();
      final after1 = bus.revision.value;
      publish();
      expect(bus.revision.value, after1);
    });

    testWidgets('PlayerTitleSlot：两端交还真实标题，只在形变途中让位', (tester) async {
      // 回归：让位条件曾漏掉 `expansion < 1.0`，导致 p=1 时真实标题被永久隐藏
      // ——播放页里再也看不到歌名/歌手/专辑，只有拖动过程与迷你条能看到。
      bus
        ..publishMiniText(
          rect: const Rect.fromLTWH(60, 1900, 200, 36),
          title: 'T',
          subtitle: 'S',
          titleStyle: null,
          subtitleStyle: null,
        )
        ..publishFullText(
          measured: const Rect.fromLTWH(32, 540, 336, 60),
          logicalSize: const Size(336, 60),
          pageOffset: Offset.zero,
          title: 'T',
          subtitle: 'S',
          titleStyle: null,
          subtitleStyle: null,
          align: Alignment.center,
          eligible: true,
        );

      // 注意：断言必须看 Opacity 的**取值**，不能看 find.text ——
      // `Opacity(0)` 的子节点仍在 widget 树上，find.text 照样命中。
      double slotOpacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(PlayerTitleSlot),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;

      Future<void> pumpAt(double p) async {
        playerExpansion.value = p;
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerTitleSlot(
              title: 'REAL',
              subtitle: 'REALSUB',
              titleStyle: null,
              subtitleStyle: null,
              align: Alignment.center,
              // 资格是回调：播放页不会因切 tab 而重建，传布尔值会拿到过期值
              eligible: () => true,
              child: const Text('REAL'),
            ),
          ),
        );
      }

      await pumpAt(0.0);
      expect(slotOpacity(), 1.0, reason: 'p=0 必须显示真实标题');
      await pumpAt(0.5);
      expect(slotOpacity(), 0.0, reason: '形变途中应让位');
      await pumpAt(1.0);
      expect(slotOpacity(), 1.0, reason: 'p=1 必须交还真实标题');
    });

    testWidgets('文字内容高于插值矩形时不报 bottom overflowed', (tester) async {
      // 回归：曾用 Positioned.fromRect 把插值矩形的高度当紧约束，而内容高度是按
      // 字号独立插值的，两者节奏不一致 → 中途内容比盒子高就 RenderFlex 溢出。
      bus
        ..publishMiniText(
          // 故意给一个远小于内容高度的矩形
          rect: const Rect.fromLTWH(60, 1900, 200, 4),
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 20),
          subtitleStyle: const TextStyle(fontSize: 20),
        )
        ..publishFullText(
          measured: const Rect.fromLTWH(32, 540, 336, 4),
          logicalSize: const Size(336, 4),
          pageOffset: Offset.zero,
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 20),
          subtitleStyle: const TextStyle(fontSize: 20),
          align: Alignment.center,
          eligible: true,
        );
      playerExpansion.value = 0.5;
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(children: [PlayerCoverMorphLayer()]),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('追加后缀式内容差：后缀全程在树上、只淡入不增删', (tester) async {
      // 回归：曾对两串做交叉淡入，而 `歌手` 与 `歌手 · 专辑` 内容真的不同 ——
      // 两串叠在一起显影，读起来是「新旧交叉」，更宽的那串还主导视觉。
      // 改为「公共前缀 + 后缀淡入」后：后缀必须**全程在树上**（增删会让 Row
      // 宽度突变，外层按插值对齐摆位 → 整块文字横向跳）。
      bus
        ..publishMiniText(
          rect: const Rect.fromLTWH(60, 1900, 200, 36),
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 14),
          subtitleStyle: const TextStyle(fontSize: 12),
        )
        ..publishFullText(
          measured: const Rect.fromLTWH(32, 540, 336, 60),
          logicalSize: const Size(336, 60),
          pageOffset: Offset.zero,
          title: '歌名',
          subtitle: '歌手 · 专辑名',
          titleStyle: const TextStyle(fontSize: 24),
          subtitleStyle: const TextStyle(fontSize: 14),
          align: Alignment.center,
          eligible: true,
        );

      Future<void> pumpAt(double p) async {
        playerExpansion.value = p;
        await tester.pumpWidget(
          const MaterialApp(
            home: Stack(children: [PlayerCoverMorphLayer()]),
          ),
        );
      }

      double tailWidthFactor() => tester
          .widget<Align>(
            find
                .ancestor(
                  of: find.text(' · 专辑名'),
                  matching: find.byType(Align),
                )
                .first,
          )
          .widthFactor!;

      for (final p in [0.1, 0.5, 0.99]) {
        await pumpAt(p);
        // 前缀与后缀都必须存在，且**不是**两串并列的新旧文本
        expect(find.text('歌手'), findsOneWidget, reason: 'p=$p 前缀');
        expect(find.text(' · 专辑名'), findsOneWidget, reason: 'p=$p 后缀应在树上');
        expect(
          find.text('歌手 · 专辑名'),
          findsNothing,
          reason: 'p=$p 不应再出现完整串的第二份（那就是叠字）',
        );
      }
      // 后缀按**宽度**揭开：低进度时宽度因子应接近 0（不占位、不把前缀挤短），
      // 高进度时接近 1（完整展开）。
      await pumpAt(0.4);
      final low = tailWidthFactor();
      await pumpAt(0.8);
      final high = tailWidthFactor();
      expect(low, lessThan(0.35), reason: '低进度时后缀不应占位');
      expect(high, greaterThan(low));
      expect(high, closeTo(1.0, 1e-9));
    });

    testWidgets('超长专辑名不打省略号：文字允许比盒子宽、由 ClipRect 裁切', (tester) async {
      // 回归：曾用两个 Flexible 平分宽度，后缀最多只能拿到盒子的一半 →
      // 长专辑名必然打省略号，且 cf=0 时不可见却占位、把前缀挤短。
      // 现在后缀用 widthFactor 揭开、整体由 ClipRect 裁切，形变层里不应再出现
      // TextOverflow.ellipsis。
      bus
        ..publishMiniText(
          rect: const Rect.fromLTWH(60, 1900, 200, 36),
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 14),
          subtitleStyle: const TextStyle(fontSize: 12),
        )
        ..publishFullText(
          measured: const Rect.fromLTWH(32, 540, 200, 60),
          logicalSize: const Size(200, 60),
          pageOffset: Offset.zero,
          title: '歌名',
          subtitle: '歌手 · 这是一个非常非常非常长的专辑名称需要滚动',
          titleStyle: const TextStyle(fontSize: 24),
          subtitleStyle: const TextStyle(fontSize: 14),
          align: Alignment.center,
          eligible: true,
        );
      playerExpansion.value = 0.5;
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(children: [PlayerCoverMorphLayer()]),
        ),
      );
      expect(tester.takeException(), isNull);
      // 只看「追加后缀」那两段：前缀与后缀都不得用省略号。
      // （硬切的标题行仍用 ellipsis —— 那是单串，与真实 widget 行为一致。）
      const tailText = ' · 这是一个非常非常非常长的专辑名称需要滚动';
      expect(find.text('歌手'), findsOneWidget);
      expect(find.text(tailText), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('歌手')).overflow,
        isNot(TextOverflow.ellipsis),
      );
      expect(
        tester.widget<Text>(find.text(tailText)).overflow,
        isNot(TextOverflow.ellipsis),
      );
    });

    testWidgets('文字块 Column 必须 stretch，由各行自己按插值对齐', (tester) async {
      // 回归：曾固定用 CrossAxisAlignment.start，而播放页真实标题块是 center
      // （竖屏）—— 标题比副标题窄，位置会差 (块宽 − 标题宽)/2，松手交接时跳。
      bus
        ..publishMiniText(
          rect: const Rect.fromLTWH(60, 1900, 200, 36),
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 14),
          subtitleStyle: const TextStyle(fontSize: 12),
        )
        ..publishFullText(
          measured: const Rect.fromLTWH(32, 540, 336, 60),
          logicalSize: const Size(336, 60),
          pageOffset: Offset.zero,
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 24),
          subtitleStyle: const TextStyle(fontSize: 14),
          align: Alignment.center,
          eligible: true,
        );
      playerExpansion.value = 0.5;
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(children: [PlayerCoverMorphLayer()]),
        ),
      );
      final column = tester.widget<Column>(
        find
            .descendant(
              of: find.byType(PlayerCoverMorphLayer),
              matching: find.byType(Column),
            )
            .first,
      );
      expect(column.crossAxisAlignment, CrossAxisAlignment.stretch);
    });

    testWidgets('文字矩形从迷你条插值到播放页标题位置', (tester) async {
      bus
        ..publishMiniText(
          rect: const Rect.fromLTWH(60, 1900, 200, 36),
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 14),
          subtitleStyle: const TextStyle(fontSize: 12),
        )
        ..publishFullText(
          measured: const Rect.fromLTWH(32, 540, 336, 60),
          logicalSize: const Size(336, 60),
          pageOffset: Offset.zero,
          title: '歌名',
          subtitle: '歌手',
          titleStyle: const TextStyle(fontSize: 24),
          subtitleStyle: const TextStyle(fontSize: 14),
          align: Alignment.center,
          eligible: true,
        );
      playerExpansion.value = 0.5;
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(children: [PlayerCoverMorphLayer()]),
        ),
      );
      // 中途应同时画出迷你条那套与播放页那套文字（内容交叉淡入的两层）
      expect(find.text('歌名'), findsWidgets);
      // 字号被 TextStyle.lerp 插值：中途既不是 14 也不是 24
      final sizes = tester
          .widgetList<Text>(find.text('歌名'))
          .map((t) => t.style?.fontSize)
          .whereType<double>()
          .toSet();
      expect(sizes.any((s) => s > 14 + 0.01 && s < 24 - 0.01), isTrue,
          reason: '字号应介于 14 与 24 之间，实际 $sizes');
    });
  });

  group('封面可见性（切到非封面 tab 时屏蔽形变）', () {
    late PlayerCoverMorphBus bus;

    setUp(() {
      bus = PlayerCoverMorphBus.instance;
      bus.reset();
      playerCoverVisible.value = true;
    });
    tearDown(() {
      playerExpansion.value = 0.0;
      playerCoverVisible.value = true;
      bus.reset();
    });

    void seed() {
      bus
        ..miniRect = const Rect.fromLTWH(16, 1900, 44, 44)
        ..settledRect = const Rect.fromLTWH(180, 400, 336, 336)
        ..eligible = true
        ..miniTextRect = const Rect.fromLTWH(60, 1900, 200, 36)
        ..settledTextRect = const Rect.fromLTWH(32, 540, 336, 60)
        ..textEligible = true;
    }

    test('封面不可见时三方判据全部为假（形变层 / 槽位 / MiniPlayer 同源）', () {
      seed();
      playerCoverVisible.value = true;
      expect(bus.willDraw(eligible: true), isTrue);
      expect(bus.layerWillDraw, isTrue);
      expect(bus.textWillDraw, isTrue);

      playerCoverVisible.value = false;
      expect(bus.willDraw(eligible: true), isFalse);
      expect(bus.layerWillDraw, isFalse,
          reason: 'MiniPlayer 据此决定要不要让位，必须一起为假');
      expect(bus.textWillDraw, isFalse, reason: '文字也必须一起屏蔽');
    });

    testWidgets('封面不可见时形变层一个字都不画', (tester) async {
      // 回归：判定曾只写在槽位里。竖屏停在歌词 / 评论 tab 时封面槽位**不构建**，
      // 判定永远不求值，`eligible` 停在过期 true —— 下拉照样飞出封面和歌名。
      // 现在判定在绘制那一刻由常驻的形变层读取全局信号。
      seed();
      bus
        ..miniTitleText = '歌名'
        ..miniSubtitleText = '歌手'
        ..fullTitleText = '歌名'
        ..fullSubtitleText = '歌手'
        ..miniTitleStyle = const TextStyle(fontSize: 14)
        ..miniSubtitleStyle = const TextStyle(fontSize: 12)
        ..fullTitleStyle = const TextStyle(fontSize: 24)
        ..fullSubtitleStyle = const TextStyle(fontSize: 14);
      playerExpansion.value = 0.5;

      playerCoverVisible.value = true;
      await tester.pumpWidget(
        const MaterialApp(home: Stack(children: [PlayerCoverMorphLayer()])),
      );
      expect(find.text('歌名'), findsOneWidget, reason: '可见时应当绘制');

      playerCoverVisible.value = false;
      await tester.pumpWidget(
        const MaterialApp(home: Stack(children: [PlayerCoverMorphLayer()])),
      );
      expect(find.text('歌名'), findsNothing, reason: '不可见时必须停画');
    });
  });

  group('曲线与端点参数', () {
    test('局部圆角除以 scale 后，屏幕实际圆角才是 6 → 16', () {
      // 起点 scale 很小（44/336），不除以它的话屏幕圆角只有 6 × 0.131 ≈ 0.8dp，
      // 与 MiniPlayer 的 6dp 对不上，交接瞬间圆角会突变成近直角。
      const scale = 44 / 336;
      expect(coverMorphLocalRadius(0, scale) * scale, closeTo(6, 1e-9));
      expect(coverMorphLocalRadius(1, scale) * scale, closeTo(16, 1e-9));
      // 局部半径本身被放大，才能抵消后续的 scale
      expect(coverMorphLocalRadius(0, scale), closeTo(6 / scale, 1e-6));
    });

    test('scale=1 时局部半径等于屏幕半径，中点为 11', () {
      expect(coverMorphLocalRadius(0, 1), closeTo(6, 1e-9));
      expect(coverMorphLocalRadius(0.5, 1), closeTo(11, 1e-9));
      expect(coverMorphLocalRadius(1, 1), closeTo(16, 1e-9));
    });

    test('scale=0（退化）不除零，退回屏幕半径本身', () {
      expect(coverMorphLocalRadius(0.5, 0), closeTo(11, 1e-9));
      expect(coverMorphLocalRadius(0.5, -1), closeTo(11, 1e-9));
    });

    test('倾角两端为 0、中点最大', () {
      // 端点用 closeTo：IEEE754 下 sin(π) ≈ 1.22e-16，kCoverMorphTilt × 之后
      // 约 3.2e-18 弧度（纳米以下），数学上为 0 但不逐位等于 0。
      expect(coverMorphTilt(0), 0);
      expect(coverMorphTilt(1), closeTo(0, 1e-12));
      expect(coverMorphTilt(0.5), closeTo(kCoverMorphTilt, 1e-9));
    });

    test('端点复位锁存：收起后再次转场不继承上一程的「不合格」', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.reset();
      // 第一程：起点合格 → 全程接管
      expect(bus.resolveCoverEligible(expansion: 0.3, live: true), isTrue);
      // 途中翻成不合格也不改判（这就是锁存的意义）
      expect(bus.resolveCoverEligible(expansion: 0.6, live: false), isTrue);
      // 到达 p=1：复位
      bus.resolveCoverEligible(expansion: 1.0, live: false);
      expect(bus.latchedCoverEligible, isNull);
      // 收起：起点不合格（视频正在播）→ 全程回退
      expect(bus.resolveCoverEligible(expansion: 0.7, live: false), isFalse);
      // 到达 p=0：此时**没有任何槽位存活**，由常驻的形变层负责复位。
      // 若漏掉这一步，上面锁存的 false 会泄漏到下一程 —— 真机表现为
      // 「第一次横屏可以，收起后再拉就不行」。
      bus.latchedCoverEligible = null;
      expect(bus.resolveCoverEligible(expansion: 0.2, live: true), isTrue);
    });

    test('封面 / 文字两路锁存相互独立：写真等只锁封面一路', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.reset();
      // 封面不合格（写真 / 车机面板等封面独有的压制），文字合格
      expect(bus.resolveCoverEligible(expansion: 0.2, live: false), isFalse);
      expect(bus.resolveTextEligible(expansion: 0.2, live: true), isTrue);
      // 途中状态被翻转也**不**改判封面那一路（锁存语义不变）
      expect(bus.resolveCoverEligible(expansion: 0.7, live: true), isFalse);
      expect(bus.resolveTextEligible(expansion: 0.7, live: false), isTrue);
      // 端点复位两路都清
      bus.latchedCoverEligible = null;
      bus.latchedTextEligible = null;
      expect(bus.latchedTextEligible, isNull);
      expect(bus.latchedCoverEligible, isNull);
    });

    test('reset() 同时清掉两路锁存', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.reset();
      bus.resolveCoverEligible(expansion: 0.4, live: true);
      bus.resolveTextEligible(expansion: 0.4, live: true);
      expect(bus.latchedCoverEligible, isTrue);
      expect(bus.latchedTextEligible, isTrue);
      bus.reset();
      expect(bus.latchedCoverEligible, isNull);
      expect(bus.latchedTextEligible, isNull);
    });

    test('layerWillDraw：与 willDraw 同源，三方判据一致', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.reset();
      // 端点缺失 → 不画（此刻不能隐藏 MiniPlayer 封面，否则会留洞）
      bus.eligible = true;
      expect(bus.layerWillDraw, isFalse);
      bus.publishMini(const Rect.fromLTWH(16, 1900, 44, 44));
      expect(bus.layerWillDraw, isFalse, reason: 'settled 仍缺失');
      bus.publishFull(
        measured: const Rect.fromLTWH(180, 400, 336, 336),
        logicalSize: const Size(336, 336),
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
      expect(bus.layerWillDraw, isTrue);
      // 资格翻转 → 立刻不画
      bus.publishFull(
        measured: const Rect.fromLTWH(180, 400, 336, 336),
        logicalSize: const Size(336, 336),
        pageOffset: Offset.zero,
        songId: 's1',
        artworkUri: null,
        fallbackFilePath: null,
        iconSize: 48,
        placeholderColor: const Color(0xFF000000),
        eligible: false,
        settledArtworkScale: 1.0,
        settledArtworkAnchor: Alignment.center,
      );
      expect(bus.layerWillDraw, isFalse);
    });

    test('t 与 playerExpansion 同值（不叠加第二条缓动）', () {
      for (final p in [0.0, 0.13, 0.5, 0.87, 1.0]) {
        expect(coverMorphT(p), p);
      }
      expect(coverMorphT(1.7), 1.0);
      expect(coverMorphT(-0.2), 0.0);
    });
  });

  group('PlayerCoverMorphBus', () {
    late PlayerCoverMorphBus bus;

    setUp(() => bus = PlayerCoverMorphBus.instance);
    tearDown(() {
      bus.reset();
    });

    test('publishFull 写入归位矩形与缩放比', () {
      bus.publishFull(
        measured: const Rect.fromLTWH(40, 300, 360, 360),
        logicalSize: const Size(360, 360),
        pageOffset: const Offset(0, 100),
        songId: 's1',
        artworkUri: 'http://x/a.jpg',
        fallbackFilePath: null,
        iconSize: 48,
        placeholderColor: const Color(0xFF123456),
        eligible: true,
        settledArtworkScale: 1.0,
        settledArtworkAnchor: Alignment.center,
      );
      expect(bus.settledRect, const Rect.fromLTWH(40, 200, 360, 360));
      expect(bus.pageToScreen, 1.0);
      expect(bus.songId, 's1');
      expect(bus.eligible, isTrue);
    });

    test('缩放比由「实测宽度 / 布局宽度」得出（非 1.0 显示档）', () {
      bus.publishFull(
        measured: const Rect.fromLTWH(0, 600, 720, 720),
        logicalSize: const Size(360, 360),
        pageOffset: const Offset(0, 100),
        songId: 's1',
        artworkUri: null,
        fallbackFilePath: null,
        iconSize: 48,
        placeholderColor: const Color(0xFF000000),
        eligible: true,
        settledArtworkScale: 1.0,
        settledArtworkAnchor: Alignment.center,
      );
      expect(bus.pageToScreen, 2.0);
      expect(bus.settledRect, const Rect.fromLTWH(0, 400, 720, 720));
    });

    test('相同输入不触发 revision（形变层不空转重建）', () {
      void publish() => bus.publishFull(
            measured: const Rect.fromLTWH(40, 300, 360, 360),
            logicalSize: const Size(360, 360),
            pageOffset: const Offset(0, 100),
            songId: 's1',
            artworkUri: 'http://x/a.jpg',
            fallbackFilePath: null,
            iconSize: 48,
            placeholderColor: const Color(0xFF123456),
            eligible: true,
            settledArtworkScale: 1.0,
            settledArtworkAnchor: Alignment.center,
          );
      publish();
      final after1 = bus.revision.value;
      publish();
      expect(bus.revision.value, after1);
    });

    test('切歌（songId 变化）与资格变化都算一次变更', () {
      void publish({required String songId, required bool eligible}) =>
          bus.publishFull(
            measured: const Rect.fromLTWH(40, 300, 360, 360),
            logicalSize: const Size(360, 360),
            pageOffset: const Offset(0, 100),
            songId: songId,
            artworkUri: null,
            fallbackFilePath: null,
            iconSize: 48,
            placeholderColor: const Color(0xFF123456),
            eligible: eligible,
            settledArtworkScale: 1.0,
            settledArtworkAnchor: Alignment.center,
          );
      publish(songId: 's1', eligible: true);
      final base = bus.revision.value;
      publish(songId: 's2', eligible: true);
      expect(bus.revision.value, base + 1);
      publish(songId: 's2', eligible: false);
      expect(bus.revision.value, base + 2);
      expect(bus.eligible, isFalse);
    });

    test('reset 回到初始态（测试隔离）', () {
      bus.publishMini(const Rect.fromLTWH(1, 2, 44, 44));
      bus.reset();
      expect(bus.miniRect, isNull);
      expect(bus.settledRect, isNull);
      expect(bus.pageOffset, Offset.zero);
      expect(bus.pageToScreen, 1.0);
      expect(bus.eligible, isFalse);
      expect(bus.songId, isNull);
    });
  });

  group('CoverGeometryProbe', () {
    testWidgets('上报屏幕矩形与布局尺寸', (tester) async {
      Rect? reported;
      Size? reportedSize;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CoverGeometryProbe(
              onRect: (rect, size) {
                reported = rect;
                reportedSize = size;
              },
              child: const SizedBox(width: 44, height: 44),
            ),
          ),
        ),
      );
      expect(reported, const Rect.fromLTWH(0, 0, 44, 44));
      expect(reportedSize, const Size(44, 44));
    });

    testWidgets('祖先带 Transform 时上报的是变换后的屏幕矩形，布局尺寸不变', (tester) async {
      Rect? reported;
      Size? reportedSize;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: const Offset(0, 300),
              child: Transform.scale(
                scale: 2.0,
                alignment: Alignment.topLeft,
                child: CoverGeometryProbe(
                  onRect: (rect, size) {
                    reported = rect;
                    reportedSize = size;
                  },
                  child: const SizedBox(width: 44, height: 44),
                ),
              ),
            ),
          ),
        ),
      );
      expect(reportedSize, const Size(44, 44));
      expect(reported, const Rect.fromLTWH(0, 300, 88, 88));
    });

    testWidgets('0.9 显示缩放下探针上报设计像素矩形（锚点空间）', (tester) async {
      // 回归：探针曾变换到 RenderView 根（窗口像素），而形变层与它同处
      // DisplayScaleScope 的设计像素空间——s≠1 时两端点整体偏 s 倍，
      // mini↔full 封面过渡错位。改测锚点空间后任意档位逐像素对齐。
      Rect? reported;
      Size? logical;
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayScaleScope(
            scale: 0.9,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 200,
                child: CoverGeometryProbe(
                  onRect: (rect, size) {
                    reported = rect;
                    logical = size;
                  },
                  child: const SizedBox(width: 200, height: 200),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // 第二帧：锚点已就绪
      await tester.pump();
      expect(reported, const Rect.fromLTWH(0, 0, 200, 200));
      expect(logical, const Size(200, 200));
    });
  });

  group('playerPageOffset', () {
    tearDown(() => PlayerCoverMorphBus.instance.reset());

    test('拖拽映射：dy = origin * (1 - progress)', () {
      expect(
        playerPageOffset(progress: 0.25, dragOrigin: 800, screenHeight: 2400),
        const Offset(0, 600),
      );
      expect(
        playerPageOffset(progress: 1.0, dragOrigin: 800, screenHeight: 2400),
        Offset.zero,
      );
    });

    test('点击映射：dy = 0.15 * (1 - progress) * 屏高', () {
      expect(
        playerPageOffset(
          progress: 0.0,
          dragOrigin: null,
          screenHeight: 1000,
        ),
        const Offset(0, 150),
      );
      expect(
        playerPageOffset(
          progress: 0.5,
          dragOrigin: null,
          screenHeight: 1000,
        ),
        const Offset(0, 75),
      );
    });

    test('每次调用都把位移写进登记簿（供播放页换算归位矩形）', () {
      playerPageOffset(progress: 0.5, dragOrigin: 800, screenHeight: 2400);
      expect(PlayerCoverMorphBus.instance.pageOffset, const Offset(0, 400));
    });
  });

  group('PlayerCoverMorphLayer', () {
    // 迷你条封面：贴左下角的小方块
    const mini = Rect.fromLTWH(16, 1900, 44, 44);
    // 播放页封面：居中的大方块
    const settled = Rect.fromLTWH(180, 400, 720, 720);

    late PlayerCoverMorphBus bus;

    setUp(() {
      bus = PlayerCoverMorphBus.instance;
      bus.reset();
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
    });

    // playerExpansion 与登记簿都是全局单例，必须复位，否则污染其它 group
    tearDown(() {
      playerExpansion.value = 0.0;
      bus.reset();
    });

    Future<void> pumpLayer(WidgetTester tester) => tester.pumpWidget(
          const MaterialApp(
            home: Stack(children: [PlayerCoverMorphLayer()]),
          ),
        );

    /// 只在形变层自己的子树里找，避免命中 MaterialApp 内部的同名控件
    Finder layerClip() => find.descendant(
          of: find.byType(PlayerCoverMorphLayer),
          matching: find.byType(ClipRRect),
        );

    testWidgets('挂载之后 playerExpansion 变化才重新画出形变层（真机转场路径）', (tester) async {
      // 先以 p=0 挂载（真机上 App 启动时的状态），**再**把进度推到中途。
      // 真机 bug：此前所有用例都是「先设值再 pump」，从未覆盖「挂载后驱动」，
      // 于是形变层监听失效这条缺陷一个都没抓到。
      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      expect(layerClip(), findsNothing);

      playerExpansion.value = 0.5;
      await tester.pump();
      expect(layerClip(), findsOneWidget);

      // 继续推进应当保持绘制（逐帧重建），不是只在第一次生效
      playerExpansion.value = 0.8;
      await tester.pump();
      expect(layerClip(), findsOneWidget);
    });

    testWidgets('p=0 → p=1 之间推进，形变层随进度改变圆角', (tester) async {
      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      // 屏幕上真正生效的圆角 = 局部半径 × scale（子树被 Transform 缩放）
      double screenRadiusAt(double p) {
        final local = (tester.widget<ClipRRect>(layerClip()).borderRadius
                as BorderRadius)
            .topLeft
            .x;
        // 圆角与边长同拍，两者都走平抛的加速项 q = p²
        final targetWidth = 44 + (720 - 44) * p * p;
        return local * (targetWidth / 720);
      }

      playerExpansion.value = 0.25;
      await tester.pump();
      // q = 0.0625 → 6 + (16-6) * 0.0625
      expect(screenRadiusAt(0.25), closeTo(6.625, 1e-6));

      playerExpansion.value = 0.75;
      await tester.pump();
      // q = 0.5625 → 6 + (16-6) * 0.5625
      expect(screenRadiusAt(0.75), closeTo(11.625, 1e-6));
    });

    testWidgets('playerExpansion 为 0（迷你态）不画任何东西', (tester) async {
      playerExpansion.value = 0.0;
      await pumpLayer(tester);
      expect(layerClip(), findsNothing);
    });

    testWidgets('playerExpansion 为 1（全屏态）交还播放页自己的封面', (tester) async {
      playerExpansion.value = 1.0;
      await pumpLayer(tester);
      expect(layerClip(), findsNothing);
    });

    testWidgets('中途的屏幕圆角是 8.5（局部半径已按 scale 放大）', (tester) async {
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      final local = (tester.widget<ClipRRect>(layerClip()).borderRadius
              as BorderRadius)
          .topLeft
          .x;
      // p=0.5：平抛的加速项 q=0.25 → 目标边长 = 44 + 676×0.25 = 213，scale = 213/720
      final scale = (44 + (720 - 44) * 0.25) / 720;
      // 圆角同样按 q：6 + (16-6)×0.25 = 8.5
      expect(local * scale, closeTo(8.5, 1e-6));
    });

    testWidgets('中途的盒子尺寸仍是 settled 尺寸（不被外层约束挤压）', (tester) async {
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      final box = tester.renderObject<RenderBox>(layerClip());
      // 端点矩形是 720×720 的大方块：若用 Align 传紧约束，800×600 的测试视口
      // 会把它压成 720×600，渲染盒不再是正方形、整套矩阵假设失真。
      // OverflowBox 显式给无界约束后才拿得到严格相等的尺寸。
      expect(box.size, const Size(720, 720));
    });

    testWidgets('中途的方块中心：横向匀速、纵向落后于直线（平抛）', (tester) async {
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      final box = tester.renderObject<RenderBox>(layerClip());
      // 旋转不改变中心，故用 localToGlobal 取中心是精确的
      // （不能用 getRect：它的 size 是经逆变换推导的量，旋转下不是视觉包围盒）。
      final center = box.localToGlobal(box.size.center(Offset.zero));
      final linearCenter = Offset.lerp(mini.center, settled.center, 0.5)!;
      // 横向仍逐点等于线性插值（平抛的水平分量匀速）
      expect(center.dx, closeTo(linearCenter.dx, 0.5));
      // 纵向走 q=t²=0.25：中点比直线**更靠下**（起段向上少），但仍严格位于两端之间
      expect(center.dy, greaterThan(linearCenter.dy));
      expect(center.dy, lessThan(mini.center.dy));
      expect(center.dy, greaterThan(settled.center.dy));
    });

    testWidgets('中途的方块整体仍在两端的纵向之间（自下而上飞）', (tester) async {
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      final box = tester.renderObject<RenderBox>(layerClip());
      final tl = box.localToGlobal(Offset.zero);
      // 平抛下盒宽已缩到 213，左上角**横向**可以略越过 settled 的左缘（盒子比
      // 终点小、中心在途中），所以只锁纵向：仍在两端之间、没飞出屏幕。
      expect(tl.dy, greaterThan(0));
      expect(tl.dy, greaterThan(settled.top));
      expect(tl.dy, lessThan(mini.top));
    });

    testWidgets('中途的边长按平抛加速项插值 44 → 720（先慢后快）', (tester) async {
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      final box = tester.renderObject<RenderBox>(layerClip());
      final tl = box.localToGlobal(Offset.zero);
      final tr = box.localToGlobal(Offset(box.size.width, 0));
      // 旋转不改变向量长度，故边长与倾角无关，可直接断言
      // q = 0.5² = 0.25 → 44 + 676×0.25 = 213（线性口径是 382）
      expect((tr - tl).distance, closeTo(44 + (720 - 44) * 0.25, 0.5));
    });

    testWidgets('eligible=false（频谱圆盘 / 3D / 动态封面 / 车机）时完全不介入', (tester) async {
      bus.eligible = false;
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      expect(layerClip(), findsNothing);
    });

    testWidgets('端点矩形缺失时不画（避免从 (0,0) 起飞）', (tester) async {
      bus.settledRect = null;
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      expect(layerClip(), findsNothing);
    });

    testWidgets('mini 矩形缺失时不画', (tester) async {
      bus.miniRect = null;
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      expect(layerClip(), findsNothing);
    });

    testWidgets('不拦截触摸（拖拽穿透到下层 MiniPlayer）', (tester) async {
      playerExpansion.value = 0.5;
      await pumpLayer(tester);
      expect(
        find.descendant(
          of: find.byType(PlayerCoverMorphLayer),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
    });
  });

  group('MiniPlayer 封面交接', () {
    testWidgets('形变层一接管就立即隐藏，不再淡出', (tester) async {
      final bus = PlayerCoverMorphBus.instance;
      bus.reset();
      // 形变层没接管（端点缺失）→ MiniPlayer 封面必须保持显示，否则留洞
      expect(bus.layerWillDraw, isFalse);

      bus
        ..publishMini(const Rect.fromLTWH(16, 1900, 44, 44))
        ..publishFull(
          measured: const Rect.fromLTWH(180, 400, 336, 336),
          logicalSize: const Size(336, 336),
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
      expect(bus.layerWillDraw, isTrue, reason: '形变层接管后应立即让位');
    });

    testWidgets('形变层不套 Opacity：封面全程不透明，不会跟着播放页淡入而发虚', (tester) async {
      // 播放页自身有淡入映射（buildTransitions 的 opacity），形变层若再叠一层
      // 淡入，两者相乘会让飞行中的专辑看起来被虚化。这里锁死「形变层子树里
      // 没有任何 Opacity」。
      final bus = PlayerCoverMorphBus.instance;
      bus
        ..miniRect = const Rect.fromLTWH(16, 1900, 44, 44)
        ..publishFull(
          measured: const Rect.fromLTWH(180, 400, 720, 720),
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
      playerExpansion.value = 0.5;
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(children: [PlayerCoverMorphLayer()]),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(PlayerCoverMorphLayer),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    test('publishMini 记录矩形；相同矩形不触发 revision（逐帧不空转）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.reset();
      addTearDown(bus.reset);
      bus.publishMini(const Rect.fromLTWH(16, 1900, 44, 44));
      expect(bus.miniRect, const Rect.fromLTWH(16, 1900, 44, 44));
      final afterFirst = bus.revision.value;
      bus.publishMini(const Rect.fromLTWH(16, 1900, 44, 44));
      expect(bus.revision.value, afterFirst);
      bus.publishMini(const Rect.fromLTWH(20, 1900, 44, 44));
      expect(bus.revision.value, afterFirst + 1);
    });
  });
}
