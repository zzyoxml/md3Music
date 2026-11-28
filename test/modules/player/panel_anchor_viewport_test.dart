import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/mini_player.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 只覆写播放态相关 getter 的假 provider（沿用本仓既有做法）。
class _FakePlayer extends PlayerProvider {
  Song? _song;
  bool _playing = false;

  @override
  Song? get currentSong => _song;

  @override
  bool get isPlaying => _playing;

  void simulate({Song? song, bool? playing}) {
    if (song != null) _song = song;
    if (playing != null) _playing = playing;
    notifyListeners();
  }
}

/// 锚点必须**跟随视口**重新登记。
///
/// 真机复现（用户录屏）：横屏点迷你条进播放页 → 转竖屏 → 下拉收起，面板停在
/// 屏高 1/3 处（横屏时迷你条顶端的绝对 Y），之后真迷你条才在屏底出现。
///
/// 根因是锚点只在「点击那一刻」登记一次，而它记录的是**旧视口的绝对 Y**；
/// 转屏后播放页的收起动画仍以它为落点。本用例锁死两条：
/// 1. 登记时带上「当时视口多高」（[PlayerPanelSignal.anchorViewportHeight]），
///    消费端据此判定锚点是否过期；
/// 2. 视口变化后迷你条会**重测并重新登记**（`_syncAnchorToViewport`），
///    因此过期窗口只存在于转屏那一两帧，且那一两帧里消费端不会误用旧值。
void main() {
  late _FakePlayer player;
  late CarModeProvider carMode;

  const Size kLandscape = Size(869, 400);
  const Size kPortrait = Size(400, 869);

  setUpAll(() {
    // DesktopLyricService 是单例、首次访问即起一个周期定时器（桌面歌词同步探针）。
    // 若在用例内部（fake_async 区）首次触发，它会以「pending timer」的形式让
    // 框架的销毁校验失败；在 setUpAll 里先建好即可（本仓既有用例同样撞这个坑）。
    DesktopLyricService.instance;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    playerExpansion.value = 0.0;
    playerDragOriginTop = 0.0;
    playerDragOriginBottom = 0.0;
    PlayerPanelSignal.anchorOwner = null;
    PlayerPanelSignal.anchorViewportHeight = 0.0;
    player = _FakePlayer()
      ..simulate(
        song: Song(
          id: 's0',
          title: '标题',
          artist: 'artist',
          album: 'album',
          duration: const Duration(seconds: 60),
        ),
        playing: true,
      );
    carMode = CarModeProvider();
  });

  tearDown(() {
    player.dispose();
    carMode.dispose();
    playerExpansion.value = 0.0;
    playerDragOriginTop = 0.0;
    playerDragOriginBottom = 0.0;
    PlayerPanelSignal.anchorOwner = null;
    PlayerPanelSignal.anchorViewportHeight = 0.0;
  });

  Widget host() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MiniPlayer(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void setViewport(WidgetTester tester, Size logical) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = logical;
  }

  /// 上滑越过 slop 触发锚点登记，随即松手（位移不足阈值 → 回弹，不 push 路由）。
  Future<void> publishAnchorBySwipe(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MiniPlayer)),
    );
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('横屏登记的锚点带视口高度，转竖屏后按新视口重测', (tester) async {
    setViewport(tester, kLandscape);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    // DisplayScaleAnchor 第 2 帧才挂上，多泵几帧让 didChangeDependencies 回填。
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await publishAnchorBySwipe(tester);

    final double landscapeTop =
        tester.getTopLeft(find.byType(MiniPlayer)).dy;
    expect(
      playerDragOriginTop,
      closeTo(landscapeTop, 0.5),
      reason: '横屏下锚点应是迷你条真实顶端',
    );
    expect(
      PlayerPanelSignal.anchorViewportHeight,
      closeTo(kLandscape.height, 0.5),
      reason: '登记时必须记下「当时视口多高」，否则消费端无法识别过期值',
    );
    expect(
      PlayerPanelSignal.anchorIsCurrent(kLandscape.height),
      isTrue,
    );

    // 转竖屏。迷你条在同一帧的帧末回调里按新视口重测并重登记 —— 过期窗口
    // 因此只有转场那一两帧，任何一帧之后消费端读到的都已是新值。
    // （「旧值判过期」本身由 bottom_chrome_sink_test 的纯函数用例逐值锁死。）
    setViewport(tester, kPortrait);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final double portraitTop = tester.getTopLeft(find.byType(MiniPlayer)).dy;
    expect(
      PlayerPanelSignal.anchorViewportHeight,
      closeTo(kPortrait.height, 0.5),
      reason: '重测后锚点必须归属新视口',
    );
    expect(
      playerDragOriginTop,
      closeTo(portraitTop, 0.5),
      reason: '重测值必须是竖屏下迷你条的真实顶端，而不是横屏遗留的那个 Y',
    );
    expect(
      playerDragOriginTop,
      greaterThan(landscapeTop),
      reason: '竖屏屏更高，迷你条顶端应当更靠下（旧值把面板收到半空即此处错位）',
    );
    expect(
      PlayerPanelSignal.anchorIsCurrent(kPortrait.height),
      isTrue,
      reason: '重登之后锚点在当前视口重新有效',
    );

    // 显式卸载：裸挂的 MiniPlayer 里封面会为重试调度一个 Timer，只有在
    // dispose 时才会取消（测试环境无网络，重试必然失败）。不主动卸载的话，
    // 框架的「widget 树销毁后仍挂着 Timer」校验会失败 —— 与本次改动无关，
    // 既有 mini_player_drag_origin_test 的 0.9 用例同样受此影响。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('重登的锚点让收起落点重新贴底（面板不再停在屏中间）', (tester) async {
    setViewport(tester, kLandscape);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await publishAnchorBySwipe(tester);
    final double staleTop = playerDragOriginTop;

    setViewport(tester, kPortrait);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 收起落点（面板 p=0 时的窗口上沿）= 锚点顶端；它必须与真迷你条重合。
    final Rect anchored = playerPanelAnchorRect(kPortrait);
    final double miniTop = tester.getTopLeft(find.byType(MiniPlayer)).dy;
    expect(
      anchored.top,
      closeTo(miniTop, 1.0),
      reason: '收起落点必须落在真迷你条上（旧值 $staleTop 在竖屏里是屏幕中间）',
    );
    expect(anchored.bottom, closeTo(kPortrait.height, 1.0));
  });
}
