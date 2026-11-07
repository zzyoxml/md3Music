import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_cover_morph_layer.dart';

/// 迷你端（常驻条 / 悬浮胶囊）起点矩形的「不经 paint 重测」回归。
///
/// 治的是真机反馈：**从普通 miniplayer 切到悬浮 miniplayer 之后，专辑封面连续
/// 动画的展开起点与收起终点整体偏到屏幕左侧外，必须重启 App 才恢复。**
///
/// 真机日志（profile 包，标签 `[MiniRectDiag]`）实锤的链条：
/// 1. 页面被路由转场整块平移的那一帧，探针 paint 时量到的是**平移中**的矩形，
///    于是写进登记簿：`from(L=4.0 …) -> to(L=-78.5 …)`；
/// 2. 之后**再也没有一次修正**：转场落定不会让静止的胶囊重新 paint，而封面一
///    交接就给真实封面套上 `Opacity(0)`，`RenderOpacity.paint` 在 `_alpha == 0`
///    时直接 return、子树根本不 paint（proxy_box.dart），探针在飞行期间压根不跑；
/// 3. 于是每一次飞行读到的都是那个偏左的旧值（`FLIGHT … mini=L=-78.5`），
///    展开起点与收起终点**同时**错位——它是同一个字段；
/// 4. 只有重启才恢复：重启必然全量重绘，探针重新 paint 一次就写对了。
///
/// 因此下面三件事都要钉住：
/// - **paint 自身救不了**（第 2 步的断言）：这条断言正是 bug 的复现，改动前后
///   都成立，用来保证「重测」这一手段是必要的，而不是可有可无的加固；
/// - **重测能救**：布局落定后重测一次，登记簿立刻回到真实位置；
/// - **看不见的探针不许写**：`Offstage(offstage: true)` 里的探针参与布局但不
///   paint，重测若把它量出来，等于拿「不在屏幕上的那根条」当飞行起点，比原
///    bug 更糟。
void main() {
  tearDown(() {
    PlayerCoverMorphBus.instance.reset();
  });

  group('迷你端重测注册表', () {
    testWidgets('Opacity(0) 让位后 paint 停止：旧值不会被自动修正，但重测会', (
      WidgetTester tester,
    ) async {
      final bus = PlayerCoverMorphBus.instance;
      final GlobalKey<_ProbeHarnessState> key =
          GlobalKey<_ProbeHarnessState>();
      await tester.pumpWidget(_ProbeHarness(key: key));
      await tester.pumpAndSettle();

      // 静止原位：探针 paint 过，登记簿拿到的是**没平移**的矩形。
      expect(bus.miniRect, isNotNull);
      final Rect resting = bus.miniRect!;

      // ① 转场平移中（仍可见 → 会 paint）：登记簿被写成偏左的值。
      key.currentState!.setShift(-95.4);
      await tester.pump();
      expect(
        bus.miniRect!.left,
        closeTo(resting.left - 95.4, 0.5),
        reason: '平移中探针会 paint，写进偏左的矩形（bug 的成因）',
      );

      // ② 交接：真实封面被 Opacity(0) 让位，随后页面落定。
      //    这条断言是「paint 救不了」的证据 —— 落定之后登记簿**仍是**偏左值，
      //    因为 alpha=0 的子树不 paint，探针再跑不到第二次。
      key.currentState!.hideCover();
      key.currentState!.setShift(0.0);
      await tester.pumpAndSettle();
      expect(
        bus.miniRect!.left,
        closeTo(resting.left - 95.4, 0.5),
        reason: '让位后探针不 paint：偏左的旧值不会自我修正（真机现象）',
      );

      // ③ 修复手段：飞行首帧重测一次 → 立刻回到结算位置。
      bus.remeasureMiniSources();
      expect(
        bus.miniRect!.left,
        closeTo(resting.left, 0.5),
        reason: '重测拿到落定后的真实矩形，起点不再偏左',
      );
      expect(
        bus.miniRect!.top,
        closeTo(resting.top, 0.5),
        reason: '只修水平方向不够，纵向也必须与静止原位一致',
      );
    });

    testWidgets('探针销毁后不再被重测调用（注册表不只增不减）', (
      WidgetTester tester,
    ) async {
      final bus = PlayerCoverMorphBus.instance;
      await tester.pumpWidget(_ProbeHarness(key: GlobalKey<_ProbeHarnessState>()));
      await tester.pumpAndSettle();
      final Rect painted = bus.miniRect!;
      expect(painted.width, 44);

      // 换成一棵不含探针的子树：探针 detach，登记必须被摘掉。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      bus.miniRect = null;
      // 若摘除失效，这里会调到已销毁的 RenderObject（size 未定义 / attached
      // false），要么抛异常要么把陈旧矩形写回来。两条都不接受。
      bus.remeasureMiniSources();
      expect(bus.miniRect, isNull);
      // 再挂回来时必须重新登记（attach 里补登记这条路径）。
      await tester.pumpWidget(_ProbeHarness(key: GlobalKey<_ProbeHarnessState>()));
      await tester.pumpAndSettle();
      bus.miniRect = null;
      bus.remeasureMiniSources();
      expect(bus.miniRect, painted);
    });

    testWidgets('Offstage 的探针不参与重测（看不见的那根条不许当起点）', (
      WidgetTester tester,
    ) async {
      final bus = PlayerCoverMorphBus.instance;
      // 两个探针：一个在屏幕上，一个被 Offstage 摘掉（形态交棒让位、以及被
      // 不透明路由压在下面的那根条，走的都是 Offstage）。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: _probe(bus),
                ),
                const Positioned(
                  left: -400,
                  bottom: 0,
                  child: Offstage(offstage: true, child: _OffstageProbePlaceholder()),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Rect onscreen = bus.miniRect!;
      expect(onscreen.left, greaterThanOrEqualTo(0));

      bus.remeasureMiniSources();
      expect(
        bus.miniRect,
        onscreen,
        reason: '重测后仍是屏幕上那根条的矩形，Offstage 那份没来抢写',
      );
    });
    testWidgets('形变层起飞首帧自动重测；收起那一程不重测', (
      WidgetTester tester,
    ) async {
      final bus = PlayerCoverMorphBus.instance;
      final GlobalKey<_ShiftableProbeState> key =
          GlobalKey<_ShiftableProbeState>();
      // 生产调用点在形变层里：这一组把「条的探针」与形变层挂在**同一个
      // MaterialApp** 下，用真实的 playerExpansion 推进来验判据，
      // 而不是手调 remeasureMiniSources（那只能验注册表，验不到调用时机）。
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              _ShiftableProbe(key: key),
              const PlayerCoverMorphLayer(),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(bus.miniRect!.left, closeTo(0.0, 0.5), reason: '静止原位');

      // 造出 bug 现场：转场把整块页面平移 → 探针 paint 到偏左的值；
      // 随后封面让位（Opacity 0）→ 探针再也不 paint → 旧值钉死。
      key.currentState!.setShift(-95.4);
      await tester.pump();
      expect(bus.miniRect!.left, closeTo(-95.4, 0.5), reason: '平移中被 paint 写入');
      key.currentState!.hideCover();
      key.currentState!.setShift(0.0);
      await tester.pumpAndSettle();
      expect(
        bus.miniRect!.left,
        closeTo(-95.4, 0.5),
        reason: '前置条件：让位后无人重测，登记簿停在偏左旧值（真机现象）',
      );

      // ① 展开起飞（0 → 0.05）：形变层首帧重测，起点回到结算位置。
      playerExpansion.value = 0.05;
      await tester.pump();
      expect(
        bus.miniRect!.left,
        closeTo(0.0, 0.5),
        reason: '从收起端起飞必须自动重测，否则起点照旧偏左',
      );

      // ② 收起那一程（1 → 0.95）：条正被壳层带着飞，**不能**重测 ——
      //    否则把飞行中的位置写进登记簿，比原 bug 更糟。
      playerExpansion.value = 1.0; // 到展开端点：清端点标志，lastExpansion=1
      await tester.pump();
      key.currentState!.setShift(-300.0); // 条被带飞（仍不可见 → 不 paint）
      await tester.pump();
      playerExpansion.value = 0.95;
      await tester.pump();
      expect(
        bus.miniRect!.left,
        closeTo(0.0, 0.5),
        reason: '收起那一程不重测：登记簿保持结算位置，不写飞行中的值',
      );

      playerExpansion.value = 0.0;
      await tester.pumpAndSettle();
    });
  });
}

/// 探针占位（Offstage 分支用）：内容无所谓，只要它带一个 isMiniSource 探针。
class _OffstageProbePlaceholder extends StatelessWidget {  const _OffstageProbePlaceholder();

  @override
  Widget build(BuildContext context) => _probe(PlayerCoverMorphBus.instance);
}

Widget _probe(PlayerCoverMorphBus bus) => CoverGeometryProbe(
  // 与生产侧一致：迷你端探针才登记重测入口。
  isMiniSource: true,
  onRect: (rect, _) => bus.publishMini(rect),
  child: const SizedBox(
    width: 44,
    height: 44,
    child: ColoredBox(color: Color(0xFF808080)),
  ),
);

/// 可控的探针宿主：`setShift` 模拟路由转场把整块页面平移，
/// `hideCover` 模拟封面交棒给飞行层（真实封面被 Opacity(0) 让位）。
class _ProbeHarness extends StatefulWidget {
  const _ProbeHarness({required super.key});

  @override
  State<_ProbeHarness> createState() => _ProbeHarnessState();
}

class _ProbeHarnessState extends State<_ProbeHarness> {
  double _dx = 0.0;
  double _opacity = 1.0;

  void setShift(double dx) => setState(() => _dx = dx);
  void hideCover() => setState(() => _opacity = 0.0);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _ShiftableProbeBody(dx: _dx, opacity: _opacity),
      ),
    );
  }
}

/// 同 [_ProbeHarness]，但**不自带 MaterialApp**：给「探针 + 形变层同树」那组用，
/// 两个 MaterialApp 嵌套会让 finder 与字体加载都变味。
class _ShiftableProbe extends StatefulWidget {
  const _ShiftableProbe({super.key});

  @override
  State<_ShiftableProbe> createState() => _ShiftableProbeState();
}

class _ShiftableProbeState extends State<_ShiftableProbe> {
  double _dx = 0.0;
  double _opacity = 1.0;

  void setShift(double dx) => setState(() => _dx = dx);
  void hideCover() => setState(() => _opacity = 0.0);

  @override
  Widget build(BuildContext context) =>
      _ShiftableProbeBody(dx: _dx, opacity: _opacity);
}

class _ShiftableProbeBody extends StatelessWidget {
  const _ShiftableProbeBody({required this.dx, required this.opacity});

  final double dx;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: _probe(PlayerCoverMorphBus.instance),
        ),
      ),
    );
  }
}
