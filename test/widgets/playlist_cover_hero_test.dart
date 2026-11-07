import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

class _SourcePage extends StatelessWidget {
  const _SourcePage();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PlaylistCoverHero(
              tag: playlistCoverHeroTag('1'),
              radius: AppRadius.smAll,
              child: const SizedBox(
                width: 52,
                height: 52,
                child: ColoredBox(color: Colors.red),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _DetailPage()),
              ),
              child: const Text('open'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailPage extends StatelessWidget {
  const _DetailPage();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          PlaylistCoverHero(
            tag: playlistCoverHeroTag('1'),
            radius: AppRadius.mdAll,
            child: const SizedBox(
              width: 140,
              height: 140,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('back'),
          ),
        ],
      ),
    );
  }
}

void main() {
  group('playlistCoverHeroTag', () {
    test('用统一前缀包装歌单 id', () {
      expect(playlistCoverHeroTag('123'), 'md3/playlist-cover/123');
    });
  });

  // 专辑与歌单的 id 都是裸数字串且**不互斥**（收藏页专辑行已在用
  // playlistCoverHeroTag(gid)）。两个命名空间一旦重合，pane 路径的
  // freshestSource 会挑到不相干的行、根路径会撞 Hero 重复 tag 断言。
  group('albumCoverHeroTag', () {
    test('用专辑前缀包装专辑 id', () {
      expect(albumCoverHeroTag('456'), 'md3/album-cover/456');
    });

    test('同一数字 id 在两个命名空间下不冲突', () {
      expect(albumCoverHeroTag('123'), isNot(playlistCoverHeroTag('123')));
    });

    test('两个前缀常量互不相同', () {
      expect(kAlbumCoverHeroTagPrefix, isNot(kPlaylistCoverHeroTagPrefix));
    });
  });

  // 听书专辑 id 也是裸数字串（实测样例 202415911，见 kugou_models.dart 的
  // KugouLongAudioAlbum.fromJson 注释），与歌单/专辑 id 同形态 → 第三个命名空间。
  group('audiobookCoverHeroTag', () {
    test('用听书前缀包装听书专辑 id', () {
      expect(
        audiobookCoverHeroTag('202415911'),
        'md3/audiobook-cover/202415911',
      );
    });

    test('同一数字 id 在三个命名空间下互不冲突', () {
      expect(audiobookCoverHeroTag('777'), isNot(playlistCoverHeroTag('777')));
      expect(audiobookCoverHeroTag('777'), isNot(albumCoverHeroTag('777')));
    });

    test('三个前缀常量两两不同', () {
      expect(kAudiobookCoverHeroTagPrefix, isNot(kPlaylistCoverHeroTagPrefix));
      expect(kAudiobookCoverHeroTagPrefix, isNot(kAlbumCoverHeroTagPrefix));
    });
  });

  // 框架 Hero 的硬约束是同一路由子树内 tag 唯一。听书主页 4 个推荐分区挂在同一棵
  // ListView 子树里、同一专辑会跨分区重复出现，编辑精选也可能返回重复 gid。
  group('firstIndexById', () {
    test('只记每个 id 的首次出现位置', () {
      expect(
        firstIndexById(const ['a', 'b', 'a', 'c', 'b']),
        const {'a': 0, 'b': 1, 'c': 3},
      );
    });

    test('空 id 不进表（多张空 id 卡不会互撞 tag）', () {
      expect(firstIndexById(const ['', 'x', '']), const {'x': 1});
    });

    test('空列表返回空表', () {
      expect(firstIndexById(const <String>[]), isEmpty);
    });
  });

  // 框架 Hero 路径的飞行进度取法：圆角必须与「驱动飞行矩形的那个值」同源，
  // 否则飞行途中角半径与尺寸/位移脱节 → 用户反馈的「圆角突变」。
  // 端点值同时锁死：起飞=来源端圆角、落位=目标端圆角，与静止封面逐像素重合。
  group('coverFlightProgress', () {
    testWidgets('push：直接取 animation.value（框架已套曲线，不许再套一次）',
        (tester) async {
      final controller = AnimationController(
        vsync: tester,
        value: 0.5,
        duration: const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);
      expect(
        coverFlightProgress(HeroFlightDirection.push, controller),
        0.5,
      );
    });

    testWidgets('push：越界值被钳制到 [0,1]', (tester) async {
      final controller =
          AnimationController(vsync: tester, value: 1.4, duration: null);
      addTearDown(controller.dispose);
      expect(coverFlightProgress(HeroFlightDirection.push, controller), 1.0);
    });

    // pop 航班的矩形由 ReverseAnimation 驱动（heroes.dart:720），圆角若不跟着
    // 反向，起飞瞬间就会跳到另一端——这正是「返回时圆角先跳一下」的成因。
    testWidgets('pop：随矩形反向（1 - value），起飞 0 落位 1', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        value: 1.0,
        duration: const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);
      expect(coverFlightProgress(HeroFlightDirection.pop, controller), 0.0);
      controller.value = 0.3;
      expect(
        coverFlightProgress(HeroFlightDirection.pop, controller),
        closeTo(0.7, 1e-9),
      );
    });

    testWidgets('两个方向在同一 animation 值上互补（同一程飞行反向对称）',
        (tester) async {
      final controller =
          AnimationController(vsync: tester, value: 0.37, duration: null);
      addTearDown(controller.dispose);
      expect(
        coverFlightProgress(HeroFlightDirection.push, controller) +
            coverFlightProgress(HeroFlightDirection.pop, controller),
        closeTo(1.0, 1e-9),
      );
    });

    // 回归哨兵：旧实现在这里多套了一次 fastOutSlowIn，中段被推到 ≈0.98。
    testWidgets('进度不再被二次缓动（锁死与矩形同源）', (tester) async {
      final controller =
          AnimationController(vsync: tester, value: 0.5, duration: null);
      addTearDown(controller.dispose);
      final p = coverFlightProgress(HeroFlightDirection.push, controller);
      expect(p, isNot(closeTo(Curves.fastOutSlowIn.transform(0.5), 1e-3)));
      // 圆角端点：t=0 取来源、t=1 取目标，与两端静止封面一致。
      expect(
        lerpCoverRadius(AppRadius.smAll, AppRadius.mdAll, p).topLeft.x,
        closeTo(10.0, 1e-9),
      );
    });

    // ── 端到端（真航班）：圆角进度必须逐帧等于「驱动飞行矩形的那个进度」──
    // 参照值只按**框架语义**算（读 heroes.dart / animations.dart 得到，不引用被测实现）：
    //   飞行矩形 = heroRectTween.evaluate(proxy)（heroes.dart:586），
    //   push：proxy = manifest.animation = CurvedAnimation(parent: toRoute.animation,
    //         curve: Hero.curve = fastOutSlowIn)                    → t = c(v)
    //   pop ：proxy = ReverseAnimation(manifest.animation)，退场时 CurvedAnimation
    //         走 reverseCurve = c.flipped，parent 是被弹路由的动画
    //         值 = 1 - c(1-v)，反向后再 1 - 它                       → t = c(1-v)
    // 统一成：t = c(status == reverse ? 1 - v : v)，v 从详情页那条路由动画**实测**。
    // 本帧应有的半径 = lerp(来源端, 目标端, t)；来源端 8（_SourcePage 52dp），
    // 目标端 12（_DetailPage 140dp）。
    // 旧实现两处都违背：push 把框架已套过曲线的进度**再套一次**（角跑在尺寸前面）；
    // pop **不随矩形反向**（起飞帧就跳到另一端、落位再跳回来）。
    Future<void> expectRadiusMatchesRectProgress(
      WidgetTester tester, {
      required double fromRadius,
      required double toRadius,
    }) async {
      final detailPage = find.byType(_DetailPage);
      var sampled = 0;
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        // 飞行封面（shuttle）里那份蓝色块：两端原件都被 Hero 的占位 Offstage
        // 藏掉（find 默认 skipOffstage），所以它是唯一命中。
        final flying = find.descendant(
          of: find.byType(Overlay),
          matching: find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == Colors.blue,
          ),
        );
        if (flying.evaluate().isEmpty || detailPage.evaluate().isEmpty) {
          continue;
        }
        final animation = ModalRoute.of(tester.element(detailPage))?.animation;
        if (animation == null) continue;
        final v = animation.value;
        final progress = Curves.fastOutSlowIn.transform(
          animation.status == AnimationStatus.reverse ? 1.0 - v : v,
        );
        final clips = find.ancestor(
          of: flying,
          matching: find.byType(ClipRRect),
        );
        expect(clips, findsOneWidget, reason: '飞行封面的裁剪层应当唯一');
        final expected = fromRadius + (toRadius - fromRadius) * progress;
        final actual =
            (tester.widget<ClipRRect>(clips).borderRadius as BorderRadius)
                .topLeft
                .x;
        expect(
          (actual - expected).abs(),
          lessThan(0.02),
          reason: '第 $i 帧 v=$v（矩形进度 $progress）：圆角 $actual 应为 '
              '$expected —— 与飞行矩形不同源，观感就是圆角突变',
        );
        sampled++;
      }
      expect(sampled, greaterThan(3), reason: '飞行期间一帧样本都没采到');
    }

    testWidgets('push 全程：圆角与飞行矩形同一个进度（不二次缓动）',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _SourcePage()));
      await tester.tap(find.text('open'));
      await expectRadiusMatchesRectProgress(
        tester,
        fromRadius: 8,
        toRadius: 12,
      );
      await tester.pumpAndSettle();
      expect(find.text('back'), findsOneWidget);
    });

    // pop 航班的来源端是**详情页**（圆角 12）、目标端是列表卡（8）：起飞帧圆角
    // 必须等于它此刻还贴着的 12，旧实现会直接给出 8。
    testWidgets('pop 全程：圆角随矩形反向，起飞帧不跳角', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _SourcePage()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('back'));
      await expectRadiusMatchesRectProgress(
        tester,
        fromRadius: 12,
        toRadius: 8,
      );
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    });
  });

  group('lerpCoverRadius', () {
    const from = AppRadius.smAll; // 8
    const to = AppRadius.mdAll; // 12

    test('t=0 返回起点圆角', () {
      expect(lerpCoverRadius(from, to, 0.0), from);
    });
    test('t=1 返回终点圆角', () {
      expect(lerpCoverRadius(from, to, 1.0), to);
    });
    test('中点逐角插值', () {
      expect(lerpCoverRadius(from, to, 0.5).bottomLeft.x, 10.0);
    });
    test('越界进度被钳制', () {
      expect(lerpCoverRadius(from, to, 1.5), to);
      expect(lerpCoverRadius(from, to, -0.5), from);
    });
    test('支持非均匀圆角（仅上圆角的卡片封面区）', () {
      const topOnly = BorderRadius.vertical(top: Radius.circular(16));
      final mid = lerpCoverRadius(topOnly, AppRadius.mdAll, 0.5);
      expect(mid.topLeft.x, 14.0);
      expect(mid.bottomLeft.x, 6.0);
    });
  });

  group('PlaylistCoverHero', () {
    testWidgets('系统减弱动态效果时不包 Hero，封面照常渲染', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: PlaylistCoverHero(
              tag: playlistCoverHeroTag('1'),
              radius: AppRadius.smAll,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      );
      expect(find.byType(Hero), findsNothing);
      // Material 内部也持有透明 ColoredBox，按颜色精确匹配本组件的 child。
      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.red,
        ),
        findsOneWidget,
      );
    });

    testWidgets('正常模式下包 Hero，静止时内容可见', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistCoverHero(
              tag: playlistCoverHeroTag('1'),
              radius: AppRadius.smAll,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      );
      expect(find.byType(Hero), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.red,
        ),
        findsOneWidget,
      );
    });

    testWidgets('push→pop 全程执行圆角插值 shuttle，不抛异常', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _SourcePage()));
      // 进入：10ms 起飞首帧 + 150ms 飞行中段（shuttle 逐帧执行圆角插值）
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('back'), findsOneWidget);
      await tester.pumpAndSettle();
      // 返回：同样穿过飞行中段
      await tester.tap(find.text('back'));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('同一子树重复 tag 在转场收集阶段抛 FlutterError（唯一性哨兵）',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PlaylistCoverHero(
                tag: playlistCoverHeroTag('dup'),
                radius: AppRadius.smAll,
                child: const SizedBox(width: 10, height: 10),
              ),
              PlaylistCoverHero(
                tag: playlistCoverHeroTag('dup'),
                radius: AppRadius.smAll,
                child: const SizedBox(width: 10, height: 10),
              ),
              Builder(
                builder: (buttonContext) => TextButton(
                  onPressed: () => Navigator.of(buttonContext).push(
                    MaterialPageRoute<void>(builder: (_) => const Scaffold()),
                  ),
                  child: const Text('go'),
                ),
              ),
            ],
          ),
        ),
      ));
      // 飞行收集发生在 push 后的 post-frame 回调里，pump 一帧让它触发。
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(tester.takeException(), isA<FlutterError>());
    });

    // 上一条证明「同 tag 会抛」，这条证明分了命名空间之后不会：专辑 id 与歌单 id
    // 都是裸数字串且可能同值，同一棵子树里两族封面用同一个数字 id 共存时，
    // push 的转场收集阶段必须零异常——否则专辑侧接入就等于给歌单埋雷。
    testWidgets('歌单/专辑同数字 id 分命名空间共存不抛（命名空间互斥哨兵）',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PlaylistCoverHero(
                tag: playlistCoverHeroTag('777'),
                radius: AppRadius.smAll,
                child: const SizedBox(width: 10, height: 10),
              ),
              PlaylistCoverHero(
                tag: albumCoverHeroTag('777'),
                radius: AppRadius.smAll,
                child: const SizedBox(width: 10, height: 10),
              ),
              Builder(
                builder: (buttonContext) => TextButton(
                  onPressed: () => Navigator.of(buttonContext).push(
                    MaterialPageRoute<void>(builder: (_) => const Scaffold()),
                  ),
                  child: const Text('go'),
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });
  });

  group('PlaylistCoverFlightBus 来源挑选', () {
    test('取最近绘制且排除目标端自己路由的来源', () {
      final bus = PlaylistCoverFlightBus.instance;
      bus.debugReset();
      addTearDown(bus.debugReset);
      final master = bus.registerSource(
          't', 'rootRoute', BorderRadius.zero, const ColoredBox(color: Colors.red));
      final panePage = bus.registerSource(
          't', 'paneRoute', BorderRadius.zero, const ColoredBox(color: Colors.blue));
      bus.debugPublish(panePage, rect: const Rect.fromLTWH(0, 0, 10, 10));
      bus.debugPublish(master, rect: const Rect.fromLTWH(5, 5, 20, 20));
      // 不排除：stamp 最大者（master，后上报）胜出。
      expect(
        bus.debugFreshestSourceRect('t'),
        const Rect.fromLTWH(5, 5, 20, 20),
      );
      // 目标端在 paneRoute 上：排除后仍取 master 的矩形。
      expect(
        bus.debugFreshestSourceRect('t', excludeRoute: 'paneRoute'),
        const Rect.fromLTWH(5, 5, 20, 20),
      );
      // 目标端在根路由上：排除后取 panePage 的矩形。
      expect(
        bus.debugFreshestSourceRect('t', excludeRoute: 'rootRoute'),
        const Rect.fromLTWH(0, 0, 10, 10),
      );
    });

    test('给了可见范围时优先屏幕内的来源（离屏同名副本不参与）', () {
      final bus = PlaylistCoverFlightBus.instance;
      bus.debugReset();
      addTearDown(bus.debugReset);
      // 可见页上真正被点击的那一行（先绘制）。
      final visible = bus.registerSource(
        't', 'visibleRoute', BorderRadius.zero, const ColoredBox(color: Colors.green),
      );
      // TabBarView 相邻页里的同一歌单：滑走时最后一帧停在离屏位置，stamp 更新。
      final offscreen = bus.registerSource(
        't', 'neighborRoute', BorderRadius.zero, const ColoredBox(color: Colors.red),
      );
      bus.debugPublish(
        visible,
        rect: const Rect.fromLTWH(16, 300, 52, 52),
      );
      bus.debugPublish(
        offscreen,
        rect: const Rect.fromLTWH(-364, 300, 52, 52),
      );
      const bounds = Rect.fromLTWH(0, 0, 392, 800);
      // 旧口径（纯 stamp）会选中离屏那份——正是真机「初始位置错误」的来源。
      expect(bus.freshestSource('t')?.rect, const Rect.fromLTWH(-364, 300, 52, 52));
      expect(
        bus.freshestSource('t', visibleBounds: bounds)?.rect,
        const Rect.fromLTWH(16, 300, 52, 52),
      );
      // 全在屏外时回退到整体最近，不让航班凭空消失。
      expect(
        bus.freshestSource('t', visibleBounds: const Rect.fromLTWH(0, 0, 100, 100))
            ?.rect,
        const Rect.fromLTWH(-364, 300, 52, 52),
      );
    });
  });

  group('pane 路径自绘飞行', () {
    testWidgets('push 起飞 → 收敛落位清空 → pop 原路飞回', (tester) async {
      final bus = PlaylistCoverFlightBus.instance;
      bus.debugReset();
      addTearDown(bus.debugReset);
      final detailKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(MaterialApp(
        home: DetailPaneScope(
          detailKey: detailKey,
          child: Stack(
            children: [
              Column(
                children: [
                  // 来源：根路由上的列表卡片封面（在 DetailPaneScope 内 → pane 路径）
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: PlaylistCoverHero(
                      tag: playlistCoverHeroTag('1'),
                      radius: AppRadius.smAll,
                      child: const ColoredBox(color: Colors.red),
                    ),
                  ),
                  Expanded(
                    child: Navigator(
                      key: detailKey,
                      onGenerateRoute: (settings) => MaterialPageRoute<void>(
                        settings: settings,
                        builder: (_) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ],
              ),
              // 真实飞行层（与 app.dart 顶层 Stack 同构）：断言它真的会出帧。
              const PlaylistCoverFlightLayer(),
            ],
          ),
        ),
      ));
      await tester.pump(); // 来源探针首帧上报矩形

      detailKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 140,
              height: 140,
              child: PlaylistCoverHero(
                tag: playlistCoverHeroTag('1'),
                radius: AppRadius.mdAll,
                child: const ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      ));
      await tester.pump(); // 首帧：页面 opacity≈0，探针可能尚未上报
      await tester.pump(const Duration(milliseconds: 120));
      expect(bus.flights.length, 1);
      expect(bus.flights.single.isPop, false);
      // 飞行是在 paint 阶段登记的，飞行层被标脏后要下一帧才重建 → 再走一帧。
      await tester.pump();
      // 飞行层真的画出了飞行封面（定位矩形在树上，飞行中 = 有、落位后 = 无）。
      final flyingFinder = find.descendant(
        of: find.byType(PlaylistCoverFlightLayer),
        matching: find.byType(Positioned),
      );
      expect(flyingFinder, findsOneWidget);

      // 上面那一帧 v 仍等于 `beginValue`（pump 不带时长不推进时钟），按「起飞前不画」
      // 的规则飞行层里只有 `Positioned.fill` 外壳、封面还没出帧。推进 40ms 让飞行真的
      // 画出来，下面的图层/子树断言才有对象（再往后 `pumpAndSettle` 收敛，不影响后续判定）。
      await tester.pump(const Duration(milliseconds: 40));

      // 每帧位移只该重绘封面自己那层，而不是整个全屏飞行层。
      expect(
        find.descendant(
          of: find.byType(PlaylistCoverFlightLayer),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
      // 封面子树是同一个实例交给 AnimatedBuilder 的 child：每帧只重配外层，
      // 不重新构建 CachedNetworkImage/ColoredBox 那条链。
      expect(
        find.descendant(
          of: find.byType(PlaylistCoverFlightLayer),
          matching: find.byType(ColoredBox),
        ),
        findsOneWidget,
      );

      await tester.pumpAndSettle(); // 进场收敛：飞行落位，真实封面先放行
      // 落位后封面进入「重叠尾巴」(120ms)：两层同时画同一份像素，杜绝空帧。
      expect(bus.flights.length, 1);
      await tester.pump(const Duration(milliseconds: 160));
      expect(bus.flights, isEmpty);
      expect(flyingFinder, findsNothing);

      detailKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 120));
      expect(bus.flights.length, 1);
      expect(bus.flights.single.isPop, true);
      expect(flyingFinder, findsOneWidget);
      await tester.pumpAndSettle(); // 退场收敛：路由已 dismissed，封面挂尾巴继续盖住
      expect(bus.flights.length, 1);
      await tester.pump(const Duration(milliseconds: 160));
      expect(bus.flights, isEmpty);
      expect(flyingFinder, findsNothing);
    });

    testWidgets('设置项关闭：不挂探针、不起飞、原件不被藏', (tester) async {
      final bus = PlaylistCoverFlightBus.instance;
      bus.debugReset();
      addTearDown(bus.debugReset);
      addTearDown(() => kPlaylistCoverTransitionEnabled.value = true);
      kPlaylistCoverTransitionEnabled.value = false;
      final detailKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(MaterialApp(
        home: DetailPaneScope(
          detailKey: detailKey,
          child: Stack(
            children: [
              Column(
                children: [
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: PlaylistCoverHero(
                      tag: playlistCoverHeroTag('1'),
                      radius: AppRadius.smAll,
                      child: const ColoredBox(color: Colors.red),
                    ),
                  ),
                  Expanded(
                    child: Navigator(
                      key: detailKey,
                      onGenerateRoute: (settings) => MaterialPageRoute<void>(
                        settings: settings,
                        builder: (_) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ],
              ),
              const PlaylistCoverFlightLayer(),
            ],
          ),
        ),
      ));
      await tester.pump();

      detailKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 140,
              height: 140,
              child: PlaylistCoverHero(
                tag: playlistCoverHeroTag('1'),
                radius: AppRadius.mdAll,
                child: const ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();

      // 没有航班，也没有任何被藏起来的封面原件（转场退化为页面自身的动画）。
      expect(bus.flights, isEmpty);
      expect(
        find.descendant(
          of: find.byType(PlaylistCoverFlightLayer),
          matching: find.byType(Positioned),
        ),
        findsNothing,
      );
      expect(
        tester
            .widgetList<Opacity>(
              find.descendant(
                of: find.byType(PlaylistCoverHero),
                matching: find.byType(Opacity),
              ),
            )
            .where((o) => o.opacity == 0),
        isEmpty,
      );
    });
  });
}
