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
/// 用命中测试而不是截图验证裁剪窗口。**限制命中的不是 `Clip.hardEdge`**，
/// 而是 `SizedBox(height: 面板高)` 给 Stack 的盒子边界 —— `RenderClipRect`
/// 只在 `clipper != null` 时才裁剪命中，而 Stack 直接 `pushClipRect`、根本不
/// 插 clipper widget。结论（窗口外点不到播放页）对，依据别写错，否则将来有人
/// 换掉裁剪实现，测试照样过、注释却误导。
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

  late List<Offset> hits;

  setUp(() => hits = <Offset>[]);
  tearDown(PlayerCoverMorphBus.instance.reset);

  Widget host(double progress, {bool backgroundImage = false}) =>
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => _FakeTheme(backgroundImage),
        child: MaterialApp(
          home: Stack(
            children: [
              PlayerPanelFrame(
                progress: progress,
                origin: origin,
                miniHeight: miniHeight,
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
                origin: 900, // > 屏高 600
                miniHeight: miniHeight,
                child: _FakePage(hits: hits),
              ),
            ],
          ),
        ),
      ),
    );
    // 窗口 = [300, 600]，页面被钳到同一 top
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
    expect(
      PlayerCoverMorphBus.instance.pageOffset,
      const Offset(0, 200),
    );
  });

  testWidgets('p=1 时 pageOffset 归零（登记簿不残留拖拽位移）', (tester) async {
    await tester.pumpWidget(host(1));
    expect(PlayerCoverMorphBus.instance.pageOffset, Offset.zero);
  });

  group('过渡态底色层', () {
    /// 过渡态底色层。只在 `p < 1` 时存在；`p=1` 页面已盖满整屏，不铺。
    Finder baseLayer() => find.byType(PlayerPanelBaseLayer);

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
      // 底色层是**整屏盒子**，`Positioned(top: -g.top, height: h)`，与下面那行
      // 页面同锚定；多出来的那段正好被外层 Stack 的 Clip.hardEdge 裁掉。
      // 壁纸档这点是刚需：若改成按窗口铺（Positioned.fill），窗口里显示的是
      // 壁纸的**另一段**，与身后的迷你条错位 —— 穿帮。
      for (final bg in [false, true]) {
        await tester.pumpWidget(host(0.3, backgroundImage: bg));
        final box = tester.getRect(baseLayer());
        expect(box.top, closeTo(0, 0.01), reason: '壁纸档=$bg 必须顶端对齐屏幕');
        expect(
          box.height,
          closeTo(screenH, 0.01),
          reason: '壁纸档=$bg 必须铺满整屏',
        );
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
      expect(boxes.single.color, cs.surfaceContainerHigh);
      expect(
        boxes.single.color,
        resolveMiniPlayerBackground(cs, useBackgroundImage: false),
        reason: '与迷你条本体逐像素同值，p=0 时起点没有色差',
      );
      expect(boxes.single.color.a, 1.0, reason: '半透明底色 = 还是会透');
    });

    testWidgets('底色层不在 Opacity 里面 —— 面板必须始终不透', (tester) async {
      // 这是上一版的真 bug：底色垫在 Opacity 内，于是整个面板（含底色）被一起
      // 乘上透明度，背后的主页面照样透过来，垫底等于白垫。
      // 判据：底色层的祖先里不能有 Opacity，而页面内容的祖先里必须有。
      for (final bg in [false, true]) {
        await tester.pumpWidget(host(0.3, backgroundImage: bg));
        expect(
          find.ancestor(of: baseLayer(), matching: find.byType(Opacity)),
          findsNothing,
          reason: '壁纸档=$bg：底色一旦被 Opacity 裹住就跟着变透明',
        );
      }
      expect(
        find.ancestor(
          of: find.byType(_FakePage),
          matching: find.byType(Opacity),
        ),
        findsOneWidget,
        reason: '淡入应只作用于页面内容',
      );
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
        cs.surfaceContainerHigh,
      );
      expect(
        resolveMiniPlayerBackground(cs, useBackgroundImage: true),
        cs.surface.withValues(alpha: 0.2),
        reason: '壁纸档迷你条本体是半透明的，壁纸才能透出来',
      );
    });
  });
}
