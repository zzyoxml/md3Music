import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:md3music/core/widgets/app_background.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_panel_frame.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 覆写背景图判定为假的 provider：真值在 ThemeProvider 里是私有字段
/// 且 setter 要碰 SharedPreferences，覆写 getter 最省事，也不碰生产代码。
///
/// 生产侧渲染壁纸分支读的是 [ThemeProvider.isBackgroundImageEffective]
/// （开关 + 图片真实存在），故两个 getter 都要覆写：只覆写裸开关的话，
/// effective 仍走真实实现（无图 → false），壁纸档拿不到 AppBackground。
class _FakeTheme extends ThemeProvider {
  _FakeTheme(this.on);
  final bool on;
  @override
  bool get useBackgroundImage => on;
  @override
  bool get isBackgroundImageEffective => on;
}

/// 播放页替身：整屏尺寸 + 记录命中次数。
///
/// 用命中测试而不是截图验证裁剪窗口。**限制命中的不是 `ClipRRect`**，
/// 而是 `SizedBox(width/height: 窗口尺寸)` 给 Stack 的盒子边界 —— 窗口外
/// 本来就打不到。圆角额外由 `RenderClipRRect.hitTest` 再裁一次（见
/// `圆角外点击不命中` 那条），两层叠加才是最终的可点区域。
class _FakePage extends StatefulWidget {
  const _FakePage({required this.hits});

  final List<Offset> hits;

  @override
  State<_FakePage> createState() => _FakePageState();
}

class _FakePageState extends State<_FakePage> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => widget.hits.add(d.localPosition),
      child: const SizedBox.expand(),
    );
  }
}

void main() {
  const screenH = 600.0;
  const screenW = 800.0;
  const origin = 400.0;
  const miniHeight = 80.0;

  /// 常驻条口径的源矩形：通栏、方角。
  const Rect residentRect = Rect.fromLTWH(0, origin, screenW, miniHeight);

  late List<Offset> hits;

  setUp(() => hits = <Offset>[]);
  tearDown(PlayerCoverMorphBus.instance.reset);

  Widget host(
    double progress, {
    bool backgroundImage = false,
    Rect originRect = residentRect,
    double originRadius = 0.0,
    BorderRadius? screenRadii,
  }) => ChangeNotifierProvider<ThemeProvider>(
    create: (_) => _FakeTheme(backgroundImage),
    child: MaterialApp(
      home: Stack(
        children: [
          PlayerPanelFrame(
            progress: progress,
            originRect: originRect,
            originRadius: originRadius,
            screenRadii: screenRadii,
            child: _FakePage(hits: hits),
          ),
        ],
      ),
    ),
  );

  setUp(() {
    // 固定视口，避免测试视口尺寸随默认值漂移
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(screenW, screenH);
    view.devicePixelRatio = 1.0;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  testWidgets('p=0：只有迷你条那一块矩形能命中播放页', (tester) async {
    await tester.pumpWidget(host(0));

    // 窗口 = [400, 480]
    await tester.tapAt(const Offset(screenW / 2, 300));
    expect(hits, isEmpty, reason: '窗口外的点不该打到播放页');

    await tester.tapAt(const Offset(screenW / 2, 440));
    expect(hits, hasLength(1), reason: '窗口内的点必须打到播放页');
  });

  testWidgets('p=1：整页可命中', (tester) async {
    await tester.pumpWidget(host(1));
    for (final y in [10.0, 300.0, 590.0]) {
      await tester.tapAt(Offset(screenW / 2, y));
    }
    expect(hits, hasLength(3));
  });

  testWidgets('p=0.5：窗口 = [200, 540]', (tester) async {
    await tester.pumpWidget(host(0.5));

    // top = 400*0.5 = 200；height = 80 + (600-80)*0.5 = 340 → 窗口 [200, 540]
    await tester.tapAt(const Offset(screenW / 2, 100));
    expect(hits, isEmpty, reason: '窗口上方露出的主页面不该打到播放页');

    await tester.tapAt(const Offset(screenW / 2, 580));
    expect(hits, isEmpty, reason: '窗口下方（导航栏那一段）仍属主页面');

    await tester.tapAt(const Offset(screenW / 2, 400));
    expect(hits, hasLength(1));
  });

  testWidgets('origin 大于屏高（转屏途中）面板仍与页面上沿重合', (tester) async {
    // origin 是转屏前捕获的快照，h 已变成转屏后的：锚点越界时若 dy 与窗口顶边
    // 不同源，页面会被推到窗口之外 → 面板整块透明、且透明窗口仍吃掉命中。
    hits = <Offset>[];
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: Stack(
            children: [
              PlayerPanelFrame(
                progress: 0.5,
                // > 屏高 600 的起点矩形（旧屏快照）
                originRect: const Rect.fromLTWH(0, 900, screenW, miniHeight),
                child: _FakePage(hits: hits),
              ),
            ],
          ),
        ),
      ),
    );
    // 起点被钳到屏底 → 窗口 = [300, 600]，页面被钳到同一 top
    expect(tester.getRect(find.byType(_FakePage)).top, closeTo(300, 0.01));
    await tester.tapAt(const Offset(screenW / 2, 450));
    expect(hits, hasLength(1), reason: '窗口内必须能打到播放页');
  });

  testWidgets('页面仍按 dy 平移（内容映射与整屏下移时代一致）', (tester) async {
    await tester.pumpWidget(host(0.5));
    // 页面盒子仍是整屏，且 top = 0 + dy(=200)
    final box = tester.getRect(find.byType(_FakePage));
    expect(box.top, closeTo(200, 0.01));
    expect(box.height, closeTo(screenH, 0.01));
  });

  testWidgets('页面尺寸不被面板压扁（裁剪而非 reflow）', (tester) async {
    await tester.pumpWidget(host(0.2));
    final box = tester.getRect(find.byType(_FakePage));
    expect(box.height, closeTo(screenH, 0.01));
    expect(box.width, closeTo(screenW, 0.01));
  });

  testWidgets('渲染一帧就把 pageOffset 写进形变登记簿', (tester) async {
    await tester.pumpWidget(host(0.5));
    expect(PlayerCoverMorphBus.instance.pageOffset, const Offset(0, 200));
  });

  testWidgets('p=1 时 pageOffset 归零（登记簿不残留拖拽位移）', (tester) async {
    await tester.pumpWidget(host(1));
    expect(PlayerCoverMorphBus.instance.pageOffset, Offset.zero);
  });

  group('外轮廓（矩形 + 圆角）', () {
    testWidgets('p=0 时窗口 == 源矩形（含横向内缩，胶囊起点不再被拉成通栏）', (
      tester,
    ) async {
      const Rect capsule = Rect.fromLTRB(16, 500, 384, 564);
      await tester.pumpWidget(
        host(0, originRect: capsule, originRadius: 32),
      );
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(PlayerPanelFrame),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clip.borderRadius, BorderRadius.circular(32));
      // 页面本身是整屏，量窗口要看 ClipRRect 的盒子
      final window = tester.getRect(
        find.descendant(
          of: find.byType(PlayerPanelFrame),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(window.left, closeTo(capsule.left, 0.01));
      expect(window.width, closeTo(capsule.width, 0.01));
      expect(window.top, closeTo(capsule.top, 0.01));
      expect(window.height, closeTo(capsule.height, 0.01));
    });

    testWidgets('圆角是**视觉**裁剪，不额外裁命中（框架行为，写清以免误判）', (
      tester,
    ) async {
      // `RenderClipRRect.hitTest` 只在**自定义 clipper** 时才裁命中；仅给
      // borderRadius 时命中区域仍是整个矩形盒。面板的可点区域由外层
      // SizedBox（窗口矩形）决定 —— 与引入圆角之前完全一致。
      // 这里把这条行为钉住：将来若有人把实现换成 clipper，命中会跟着变窄，
      // 那时需要重新评估播放页四角是否还有可点元素。
      const Rect capsule = Rect.fromLTRB(300, 400, 500, 500);
      await tester.pumpWidget(
        host(0, originRect: capsule, originRadius: 50),
      );
      await tester.tapAt(const Offset(302, 402));
      expect(
        hits,
        hasLength(1),
        reason: '仅 borderRadius 时框架不裁命中（播放页四角本来也没有可点元素）',
      );
    });

    testWidgets('p=1 + 设备上报屏幕 r 角：终态收回方角（覆盖屏边、不露底）', (
      tester,
    ) async {
      const BorderRadius screenRadii = BorderRadius.only(
        topLeft: Radius.circular(48),
        topRight: Radius.circular(48),
        bottomLeft: Radius.circular(48),
        bottomRight: Radius.circular(48),
      );
      await tester.pumpWidget(host(1, screenRadii: screenRadii));
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(PlayerPanelFrame),
          matching: find.byType(ClipRRect),
        ),
      );
      // 尾段收回（[kPlayerPanelRadiusRetractStart]）：真机报障「完全展开后 r 角
      // 裁剪永久保留；上报值与实际物理圆角对不齐时，四角弧形缺口露出底下的
      // 主页面」。终态必须是方角满铺 —— 物理圆角交给屏幕自己裁。
      expect(clip.borderRadius, BorderRadius.zero);
      expect(clip.clipBehavior, Clip.hardEdge);
      expect(
        tester.getRect(
          find.descendant(
            of: find.byType(PlayerPanelFrame),
            matching: find.byType(ClipRRect),
          ),
        ),
        const Rect.fromLTWH(0, 0, screenW, screenH),
      );
    });

    testWidgets('圆角峰值帧（p=收敛起点）：窗口四角 = 屏幕 r 角 + 抗锯齿', (
      tester,
    ) async {
      const BorderRadius screenRadii = BorderRadius.only(
        topLeft: Radius.circular(48),
        topRight: Radius.circular(48),
        bottomLeft: Radius.circular(48),
        bottomRight: Radius.circular(48),
      );
      await tester.pumpWidget(
        host(kPlayerPanelRadiusRetractStart, screenRadii: screenRadii),
      );
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(PlayerPanelFrame),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clip.borderRadius, screenRadii);
      expect(
        clip.clipBehavior,
        Clip.antiAlias,
        reason: '有圆角时必须抗锯齿，否则弧边会出现肉眼可见的台阶',
      );
    });

    testWidgets('小窗只上报单侧 r 角：峰值帧也必须方角（左方右圆回归）', (
      tester,
    ) async {
      // 小窗（Freeform）里 Android 只给「窗口实际贴住的显示屏角」回报半径，
      // 另一侧为 0。旧行为把它当终点，中间帧就出现左侧方角 / 右侧圆角。
      const BorderRadius miniWindowRadii = BorderRadius.only(
        topRight: Radius.circular(58),
        bottomRight: Radius.circular(58),
      );
      await tester.pumpWidget(
        host(kPlayerPanelRadiusRetractStart, screenRadii: miniWindowRadii),
      );
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(PlayerPanelFrame),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(
        clip.borderRadius,
        BorderRadius.zero,
        reason: '小窗口径下四角必须统一方角',
      );
      expect(clip.clipBehavior, Clip.hardEdge);
    });

    testWidgets('p=1 + 未上报圆角：方角、与引入圆角之前逐像素一致', (tester) async {
      await tester.pumpWidget(host(1));
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(PlayerPanelFrame),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clip.borderRadius, BorderRadius.zero);
      expect(clip.clipBehavior, Clip.hardEdge);
      await tester.tapAt(const Offset(2, 2));
      expect(hits, hasLength(1), reason: '方角端点必须整屏可点');
    });
  });

  group('过渡态底色层', () {
    /// 过渡态底色层。只在 `p < 1` 时存在；`p=1` 页面已盖满整屏，不铺。
    Finder baseLayer() => find.byType(PlayerPanelBaseLayer);

    /// 底色层自己的渐显不透明度（p=0 必须为 0，见 [playerPanelBaseOpacity]）。
    double baseOpacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find.ancestor(of: baseLayer(), matching: find.byType(Opacity)).first,
        )
        .opacity;

    testWidgets('过渡态（窗口小于整屏）铺一层底色层', (tester) async {
      await tester.pumpWidget(host(0.3));
      expect(
        baseLayer(),
        findsOneWidget,
        reason: '页面内容淡入期间要叠在干净底色上，否则直接和背后主页面混叠',
      );
    });

    testWidgets('底色层铺满整屏且顶端对齐屏幕（裁剪交给外层窗口）', (
      tester,
    ) async {
      // 底色层是**整屏盒子**，按屏幕坐标定位；多出来的那段被外层圆角裁剪裁掉。
      // 壁纸档这点是刚需：若改成按窗口铺，窗口里显示的是壁纸的**另一段**，
      // 与身后的迷你条错位 —— 穿帮。
      for (final bg in [false, true]) {
        await tester.pumpWidget(host(0.3, backgroundImage: bg));
        final box = tester.getRect(baseLayer());
        expect(box.top, closeTo(0, 0.01), reason: '壁纸档=$bg 必须顶端对齐屏幕');
        expect(
          box.height,
          closeTo(screenH, 0.01),
          reason: '壁纸档=$bg 必须铺满整屏',
        );
        expect(box.width, closeTo(screenW, 0.01), reason: '横向同样按屏幕坐标铺');
      }
    });

    testWidgets('壁纸档底色层 = AppBackground + 两层 20% surface', (
      tester,
    ) async {
      await tester.pumpWidget(host(0.3, backgroundImage: true));
      final layer = baseLayer();
      expect(
        find.descendant(of: layer, matching: find.byType(AppBackground)),
        findsOneWidget,
        reason: '壁纸本体直接复用全局背景层，不复刻配方',
      );
      // AppBackground 自带一个**不透明**的 ColoredBox 打底，所以不能直接数
      // descendant（会是 3 个）；只数本层 Stack 的直接子节点 = 两层 tint。
      final stack = tester.widget<Stack>(
        find.descendant(of: layer, matching: find.byType(Stack)).first,
      );
      final tints = stack.children.whereType<ColoredBox>().toList();
      expect(
        tints,
        hasLength(2),
        reason: '底栏面 + 迷你条面：只画一层偏暗、画三层偏亮都是穿帮',
      );
      for (final t in tints) {
        expect(t.color.a, closeTo(0.2, 0.001));
      }
    });

    testWidgets('非壁纸档底色层是不透明的迷你条同款实色', (tester) async {
      await tester.pumpWidget(host(0.3));
      final layer = baseLayer();
      final boxes = tester.widgetList<ColoredBox>(
        find.descendant(of: layer, matching: find.byType(ColoredBox)),
      );
      expect(boxes, hasLength(1), reason: '非壁纸档没有壁纸栈，就是一块实色');

      final cs = Theme.of(tester.element(baseLayer())).colorScheme;
      expect(boxes.single.color, cs.surface);
      expect(
        boxes.single.color,
        resolveMiniPlayerBackground(cs, useBackgroundImage: false),
        reason: '与迷你条本体逐像素同值，p=0 时起点没有色差',
      );
      expect(boxes.single.color.a, 1.0, reason: '半透明底色 = 还是会透');
    });

    testWidgets('底色按自己的曲线渐显：p=0 透明（露出真身）、p>=4% 全不透明', (
      tester,
    ) async {
      await tester.pumpWidget(host(0.0));
      expect(
        baseOpacity(tester),
        0.0,
        reason: 'p=0 时悬浮条真身（含包边进度环）必须完整可见，不能被底色盖掉',
      );

      await tester.pumpWidget(host(0.02));
      final mid = baseOpacity(tester);
      expect(mid, greaterThan(0.0));
      expect(mid, lessThan(1.0));

      await tester.pumpWidget(host(0.2));
      expect(
        baseOpacity(tester),
        1.0,
        reason: '手指真正带起面板后，底色必须完全挡住背后主页面',
      );
    });

    testWidgets('页面淡入与底色渐显是两条独立曲线（底色不跟着页面淡入）', (
      tester,
    ) async {
      // 这是上一版的真 bug：底色垫在页面的 Opacity 里，于是整个面板（含底色）
      // 被一起乘上透明度，背后的主页面照样透过来，垫底等于白垫。
      await tester.pumpWidget(host(0.1));
      expect(
        find.ancestor(
          of: baseLayer(),
          matching: find.byType(Opacity),
        ),
        findsOneWidget,
        reason: '底色只允许被**自己的**渐显层包住（外层圆角裁剪之上不应再有 Opacity）',
      );
      expect(
        find.ancestor(of: baseLayer(), matching: find.byType(Opacity)).first,
        isNot(
          find.ancestor(
            of: find.byType(_FakePage),
            matching: find.byType(Opacity),
          ).first,
        ),
        reason: '页面那条淡入不能同时作用于底色',
      );
      // p=0.1 已过 4% 行程 → 底色满不透明，而页面此时才 ~0.5 不透明
      expect(baseOpacity(tester), 1.0);
    });

    testWidgets('p=1 时不铺底色（页面已完全盖住，多铺一层纯浪费）', (
      tester,
    ) async {
      await tester.pumpWidget(host(1, backgroundImage: true));
      expect(baseLayer(), findsNothing);
    });

    test('迷你条本体底色取值锁死（面板底色层以它为非壁纸档基准）', () {
      final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));
      expect(
        resolveMiniPlayerBackground(cs, useBackgroundImage: false),
        cs.surface,
      );
      expect(
        resolveMiniPlayerBackground(cs, useBackgroundImage: true),
        cs.surface.withValues(alpha: 0.2),
        reason: '壁纸档迷你条本体是半透明的，壁纸才能透出来',
      );
    });
  });

  // ── 真机报障回归：「拖动展开时有一段先变白再变正常」───────────────────────
  //
  // 根因是**调用点**把本帧窗口上沿 `rect.top`（= 锚点×(1−p)）当成
  // [playerPanelOpacity] 契约里的「锚点 origin」：`o` 随 p 收缩，一旦窗口上沿
  // 小于 20% 屏高就落进「行程不足 span」分支返回 `p×o/o = p`，透明度于是
  // 中段到 1.0、后 1/4 程又掉回 ~0.8、末帧硬弹回 1.0 —— 非单调。页面是深色，
  // 底下一层 4% 行程起就全不透明的**浅色**底色（surface / 壁纸洗白）
  // 随之透出 = 「先变白」。
  //
  // 为什么纯函数测试抓不到：`player_panel_geometry_test.dart` 那组一直按契约传
  // **锚点**，函数本身没错；错在调用点传了什么。所以必须**在树里读那个 Opacity**。
  group('页面淡入不透明度（调用点契约：传锚点，不是窗口上沿）', () {
    /// 页面内容自己那条淡入的不透明度。直接包住 `child`（_FakePage）的那一层
    /// 就是最近的 Opacity —— 底色层的 Opacity 不是 _FakePage 的祖先，不会混进来。
    double pageOpacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byType(_FakePage),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;

    testWidgets('沿全程单调不减，并在行程满 20% 屏高后保持 1.0', (tester) async {
      // span = 0.2 × 600 = 120，锚点 400 → 理论上 p ≥ 120/400 = 0.3 就应满不透明。
      const double saturateAt = 0.2 * screenH / origin;
      double previous = -1.0;
      for (int i = 0; i <= 100; i++) {
        final double p = i / 100.0;
        await tester.pumpWidget(host(p));
        final double a = pageOpacity(tester);
        expect(
          a,
          greaterThanOrEqualTo(previous),
          reason:
              'p=$p 的页面不透明度从上一帧的 $previous 回退到 $a —— '
              '非单调即「拖到后段先变白」（调用点把窗口上沿当锚点传了）',
        );
        if (p >= saturateAt) {
          expect(
            a,
            1.0,
            reason: 'p=$p 已过饱和行程（$saturateAt），必须保持完全不透明',
          );
        }
        previous = a;
      }
      expect(previous, 1.0, reason: '末帧必须完全不透明');
    });

    testWidgets('起点透明；中段（窗口上沿已小于 span）不得跌破 1.0', (
      tester,
    ) async {
      await tester.pumpWidget(host(0.0));
      expect(pageOpacity(tester), 0.0);
      // 旧实现在这里：p=0.5 → 1.0，p=0.75 → 0.79（跌破），p=1 → 1.0。
      for (final double p in <double>[0.5, 0.65, 0.75, 0.85, 0.9]) {
        await tester.pumpWidget(host(p));
        expect(
          pageOpacity(tester),
          1.0,
          reason: 'p=$p 窗口上沿=${origin * (1 - p)} 已小于 span，'
              '正确实现应保持满不透明（旧实现此处回退 = 变白）',
        );
      }
    });

    testWidgets('顶栏迷你条（锚点小于 span）整段行程走完即不透明（TV 回归不脱钩）', (
      tester,
    ) async {
      // 锚点 56 < span 120：行程不足 20% 屏高 → 按整段行程线性走完（与
      // player_panel_geometry_test 里那条 TV 钉子同一口径），末帧必须为 1.0。
      const Rect topBar = Rect.fromLTWH(0, 56, screenW, 40);
      await tester.pumpWidget(host(0.5, originRect: topBar));
      expect(pageOpacity(tester), closeTo(0.5, 1e-9));
      await tester.pumpWidget(host(1.0, originRect: topBar));
      expect(pageOpacity(tester), 1.0);
    });
  });
}
