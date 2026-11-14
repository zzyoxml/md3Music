import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/ui_density.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/mini_player.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';

/// 只覆写播放态相关 getter 的假 provider（同 secondary_mini_player_test）。
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

void _setViewport(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
  addTearDown(tester.view.reset);
}

const Size _kPhonePortrait = Size(400, 869);

/// MiniPlayer 上滑拖拽起点（playerDragOriginTop）的坐标空间约定：
/// 它是拖拽起点 `_miniTopY` 的唯一出口，供路由 Transform.translate 与
/// MediaQuery 屏高（均为设计像素）混算，故必须上报**锚点（设计像素）
/// 空间**的顶端 Y，而不是 RenderView 根（窗口像素）空间。
void main() {
  late _FakePlayer player;
  late CarModeProvider carMode;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    playerExpansion.value = 0.0;
    playerDragOriginTop = 0.0;
    playerDragOriginBottom = 0.0;
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
  });

  Widget host({required double scale}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        builder: (context, child) =>
            DisplayScaleScope(scale: scale, child: child!),
        home: Scaffold(
          body: Stack(
            children: const <Widget>[
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

  /// 在 MiniPlayer 上按住并上滑超过 touch slop，触发拖拽激活
  /// （`_onRawMove` 里 `playerDragOriginTop = _miniTopY`）。
  Future<void> swipeUp(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MiniPlayer)),
    );
    addTearDown(gesture.removePointer);
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
  }

  testWidgets('0.9 显示缩放下拖拽起点上报设计像素（锚点空间）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host(scale: 0.9));
    // DisplayScaleAnchor 第 2 帧才挂上 DisplayScaleReference，
    // 再泵一帧让 MiniPlayer 的 didChangeDependencies 回填锚点。
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await swipeUp(tester);

    // 根（窗口）空间的顶端 Y：tester 全局坐标即窗口逻辑像素。
    final windowTop = tester.getTopLeft(find.byType(MiniPlayer)).dy;
    expect(windowTop, greaterThan(0), reason: '迷你条应贴在底部且顶端在屏内');
    // 锚点（设计像素）= 窗口 ÷ 0.9；两空间在 0.9 档下差异明显，
    // 若仍量根空间会偏差约 10%（≈ windowTop×(1/0.9−1)）。
    expect(
      playerDragOriginTop,
      closeTo(windowTop / 0.9, 0.5),
      reason: 'playerDragOriginTop 必须是设计像素，与路由位移/屏高同空间',
    );
  });

  testWidgets('1.0 档回归：锚点空间 ≡ 根空间（行为不变）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host(scale: 1.0));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await swipeUp(tester);

    final windowTop = tester.getTopLeft(find.byType(MiniPlayer)).dy;
    expect(playerDragOriginTop, closeTo(windowTop, 0.5));
  });

  testWidgets('底边锚点同样是设计像素（双向展开面板靠它反解条高）', (tester) async {
    _setViewport(tester, _kPhonePortrait);
    await tester.pumpWidget(host(scale: 0.9));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await swipeUp(tester);

    final windowBottom = tester.getBottomLeft(find.byType(MiniPlayer)).dy;
    expect(
      playerDragOriginBottom,
      closeTo(windowBottom / 0.9, 0.5),
      reason: '底边必须与顶端同一个坐标系，两者相减才是条高',
    );
    expect(
      playerDragOriginBottom,
      greaterThan(playerDragOriginTop),
      reason: '底边必须真的在顶端之下，否则面板起点会是一条 0 高的线',
    );
    expect(
      playerMiniBarHeight(),
      closeTo(playerDragOriginBottom - playerDragOriginTop, 0.5),
    );
    expect(playerMiniBarHeight(), greaterThan(0));
  });

  testWidgets('锚点未登记时回落到经验条高（不产生 0 高的面板）', (tester) async {
    playerDragOriginTop = 0;
    playerDragOriginBottom = 0;
    expect(playerMiniBarHeight(), kPlayerFallbackMiniBarHeight);
  });
}
