import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/theme/motion_constants.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/bottom_bar_morph_overlay.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 只覆写播放态相关 getter 的假 provider（与本目录既有做法同款）。
class _FakePlayer extends PlayerProvider {
  _FakePlayer(this._song);

  final Song? _song;

  @override
  Song? get currentSong => _song;

  @override
  bool get isPlaying => true;

  @override
  Duration? get duration => const Duration(seconds: 60);

  @override
  Duration get position => const Duration(seconds: 12);
}

/// Flutter 测试默认视口 800×600（shortestSide = 600 → isPadLayout 判真），
/// 故显式指定手机竖屏视口。
void _setViewport(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
  addTearDown(tester.view.reset);
}

const Size _kPhonePortrait = Size(400, 869);

const ValueKey<String> _kBarTextKey = ValueKey<String>('morph-bar-text');

void main() {
  Song song() => const Song(
    id: 's0',
    title: '标题',
    artist: 'artist',
    album: 'album',
    duration: Duration(seconds: 60),
  );

  late _FakePlayer player;
  late CarModeProvider carMode;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 全局进度/窗口开关是跨用例共享的 ValueNotifier，必须显式复位。
    kBottomBarFormProgress.value = 0.0;
    kBarFormFlightActive.value = false;
    kBarFormResidentIsSource.value = true;
    player = _FakePlayer(song());
    carMode = CarModeProvider();
  });

  tearDown(() {
    kBottomBarFormProgress.value = 0.0;
    kBarFormFlightActive.value = false;
    player.dispose();
    carMode.dispose();
  });

  Widget host() => MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
      ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
      ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
    ],
    child: MaterialApp(
      home: Scaffold(
        // 与生产一致：浮层挂在 Navigator 之上的 Stack 里。
        body: const Stack(children: <Widget>[BottomBarMorphOverlay()]),
      ),
    ),
  );

  testWidgets('端点（p=0 / p=1）不渲染那一根条 —— 静止时零成本', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kBottomBarFormProgress.value = 0.0;
    await tester.pumpWidget(host());
    expect(find.byKey(_kBarTextKey), findsNothing);

    kBottomBarFormProgress.value = 1.0;
    await tester.pump();
    expect(find.byKey(_kBarTextKey), findsNothing);
  });

  testWidgets('飞行窗口内（开关开）渲染那一根条', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    kBottomBarFormProgress.value = 0.0;
    kBarFormFlightActive.value = false;
    await tester.pumpWidget(host());

    kBottomBarFormProgress.value = 0.5;
    kBarFormFlightActive.value = true;
    await tester.pump();
    expect(find.byKey(_kBarTextKey), findsOneWidget);
    // 两端共享的播放控制与桌面歌词按钮都在（浮层不写第三份行内容）。
    expect(find.byType(PlayerBarTransport), findsOneWidget);
    expect(find.byType(PlayerBarLyricButton), findsOneWidget);

    // 关窗（收敛到端点）即收干净。
    kBarFormFlightActive.value = false;
    kBottomBarFormProgress.value = 0.0;
    await tester.pump();
    expect(find.byKey(_kBarTextKey), findsNothing);
  });

  testWidgets('无曲目不渲染', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    final empty = _FakePlayer(null);
    kBottomBarFormProgress.value = 0.5;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: empty),
          ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
          ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: const Stack(children: <Widget>[BottomBarMorphOverlay()]),
          ),
        ),
      ),
    );
    expect(find.byKey(_kBarTextKey), findsNothing);
    empty.dispose();
  });

  // ─────────── K1：可见形变前置完成映射（窗口时长不砍，只折曲线） ───────────
  //
  // 用户报「底栏形态交叉过渡变形太慢」：可见形变原先与飞行窗口同长（整段铺满）。
  // 修复保持窗口判据（`inBottomBarFormFlight` 读的未缓动进度）一帧不动，只把
  // 「窗口进度 → 可见形态进度」的映射前置到窗口开头的
  // `kBarFormVisibleMorphDuration`（260ms）、其后停在端点。
  group('K1：可见形变前置完成（resolveVisibleBarFormProgress）', () {
    const Duration d = kBarFormVisibleMorphDuration; // 260ms
    const Curve c = M3ExpressiveMotion.barFormMorphEasing;

    double fwd(Duration e) =>
        resolveVisibleBarFormProgress(forward: true, elapsed: e);
    double rev(Duration e) =>
        resolveVisibleBarFormProgress(forward: false, elapsed: e);

    test('端点精确：u=0 / u=1 逐值等于两端端点（交棒两端无残差的前提）', () {
      expect(fwd(Duration.zero), 0.0);
      expect(rev(Duration.zero), 1.0);
      expect(fwd(d), 1.0);
      expect(rev(d), 0.0);
      // 浮点数意义上的精确（Curve.transform 对 t == 0 / 1 有短路）：
      expect(fwd(d) - 1.0, 0.0);
      expect(rev(d) - 0.0, 0.0);
    });

    test('窗口长于 260ms 时，形变走完后停在端点（K1 的"之后停在端点"）', () {
      for (final Duration e in <Duration>[
        d,
        d + const Duration(milliseconds: 40),
        const Duration(milliseconds: 450), // 最短真实窗口余量
        const Duration(milliseconds: 1000),
      ]) {
        expect(fwd(e), 1.0, reason: 'e=$e');
        expect(rev(e), 0.0, reason: 'e=$e');
      }
    });

    test('前向 = C(u)：强 ease-out，四分之一时间就完成大半', () {
      expect(fwd(const Duration(milliseconds: 65)), closeTo(c.transform(0.25), 1e-9));
      expect(fwd(const Duration(milliseconds: 65)), greaterThan(0.6)); // 实测 0.608
      expect(fwd(const Duration(milliseconds: 130)), greaterThan(0.87)); // 0.877
      // 「比 smoothstep 更早」：全时段支配 smoothstep（浮点误差 1e-6 内）。
      double smoothstep(double t) => t * t * (3.0 - 2.0 * t);
      for (var i = 0; i <= 1000; i++) {
        final double u = i / 1000;
        expect(fwd(Duration(microseconds: (u * d.inMicroseconds).round())),
            greaterThanOrEqualTo(smoothstep(u) - 1e-6),
            reason: 'u=$u 前向映射不得慢于 smoothstep');
      }
    });

    test('反向 = C(1 − u)（时间镜像）：与 reverseCurve: Interval(1 − portion, 1) 等价', () {
      // 反向第 65ms（1/4 行程）时形变已回到 C(0.75)（≈0.975），而不是拖到窗口尾。
      expect(rev(const Duration(milliseconds: 65)), closeTo(c.transform(0.75), 1e-9));
      expect(rev(const Duration(milliseconds: 195)), closeTo(c.transform(0.25), 1e-9));
      expect(rev(const Duration(milliseconds: 195)), lessThan(0.7)); // 实测 0.608
      // 前向/反向互为时间镜像：fwd(u) 与 rev(1 − u) 逐值一致。
      for (var i = 0; i <= 200; i++) {
        final double u = i / 200;
        final Duration e = Duration(microseconds: (u * d.inMicroseconds).round());
        expect(rev(d - e), closeTo(fwd(e), 1e-9), reason: 'u=$u');
      }
    });

    test('单调：前向不降、反向不升；两端之外夹住不走', () {
      double prevF = -1.0;
      double prevR = 2.0;
      for (var i = 0; i <= 1000; i++) {
        final Duration e = Duration(microseconds: i * 260); // 0..260ms 步进
        final double f = fwd(e);
        final double r = rev(e);
        expect(f, greaterThanOrEqualTo(prevF));
        expect(r, lessThanOrEqualTo(prevR));
        expect(f, inInclusiveRange(0.0, 1.0));
        expect(r, inInclusiveRange(0.0, 1.0));
        prevF = f;
        prevR = r;
      }
      // 越界（负时长）夹到起点端。
      expect(fwd(const Duration(milliseconds: -5)), 0.0);
      expect(rev(const Duration(milliseconds: -5)), 1.0);
    });
  });
}
