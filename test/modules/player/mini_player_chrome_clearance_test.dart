import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/bottom_chrome_scope.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/mini_player.dart';
import 'package:md3music/modules/player/player_bar_progress_painter.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/widgets/smart_artwork_image.dart';

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

/// 常驻播放条的底部净空必须随底栏收起**线性过渡**：
/// 旧实现按 bool 二选一，转场末帧会出现十几到几十 dp 的内容跳变。
///
/// 进度一律走**进度源**（`BottomChromeScope.collapseProgress`，生产里就是
/// `ResponsiveScaffold._chromeHideCurve`）而不是快照字段：MiniPlayer 订阅它、
/// 不在 build 里读它，这正是本轮「收缩动画流畅度」优化的被测行为。测试因此也用
/// 可变的 `AnimationController` 驱动 —— 值在变、树不重建，与生产逐帧驱动同构；
/// 用 `AlwaysStoppedAnimation` 会退化成「换值必须重建 MiniPlayer」，测不到重点。
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

  /// 复刻生产环境：底栏在场时 `Scaffold` 已经把 body 的 `padding.bottom`
  /// 整段移除（= 0），系统手势条净空只剩在 `viewPadding.bottom` 里。
  Widget host({
    required Animation<double> progress,
    bool hasBottomChrome = true,
    double viewPaddingBottom = 48,
    BorderRadius? cornerRadii,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(400, 869),
            viewPadding: EdgeInsets.only(bottom: viewPaddingBottom),
            displayCornerRadii: cornerRadii,
          ),
          child: Scaffold(
            body: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: BottomChromeScope(
                    hasBottomChrome: hasBottomChrome,
                    bottomChromeCollapse: progress.value,
                    collapseProgress: progress,
                    child: const MiniPlayer(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 可变进度源（生产收起动画的等价物）。
  AnimationController progress(WidgetTester tester, double value) {
    final controller = AnimationController(
      vsync: tester,
      duration: kBottomChromeToggleDuration,
      value: value,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets('收起进度 0 / 0.5 / 1 对应净空 0 / 24 / 48（线性，不是二选一）', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);

    final controller = progress(tester, 0.0);
    await tester.pumpWidget(host(progress: controller));
    await tester.pumpAndSettle();
    final double h0 = tester.getSize(find.byType(MiniPlayer)).height;

    controller.value = 0.5;
    await tester.pump();
    final double hMid = tester.getSize(find.byType(MiniPlayer)).height;

    controller.value = 1.0;
    await tester.pump();
    final double h1 = tester.getSize(find.byType(MiniPlayer)).height;

    expect(h1 - h0, closeTo(48, 0.5), reason: '底栏完全让位时底部净空 = viewPadding.bottom');
    expect(hMid - h0, closeTo(24, 0.5), reason: '中途必须是线性过渡，不是二选一');
    expect(tester.takeException(), isNull);
  });

  testWidgets('坞位不存在时直接按"自身即最底部"处理', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);

    final controller = progress(tester, 0.0);
    await tester.pumpWidget(
      host(progress: controller, hasBottomChrome: false),
    );
    await tester.pumpAndSettle();
    final double h = tester.getSize(find.byType(MiniPlayer)).height;

    // 坞位不存在 → 进度值怎么走都按「自身即屏幕最底部」（= viewPadding.bottom）
    controller.value = 0.5;
    await tester.pump();
    expect(
      tester.getSize(find.byType(MiniPlayer)).height,
      closeTo(h, 0.01),
      reason: '进度在中途也不该改变净空（坞位不存在时它无意义）',
    );
    controller.value = 1.0;
    await tester.pump();
    expect(tester.getSize(find.byType(MiniPlayer)).height, closeTo(h, 0.01));

    // 换到坞位在场：进度 0 与上面的差值 = viewPadding.bottom（48）
    await tester.pumpWidget(host(progress: controller));
    controller.value = 0.0;
    await tester.pump();
    final double hWithChrome = tester.getSize(find.byType(MiniPlayer)).height;

    expect(h - hWithChrome, closeTo(48, 0.5));
  });

  testWidgets('逐帧插值期间：留白层照常动，内容子树一个都不重建', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);

    final controller = progress(tester, 0.0);
    await tester.pumpWidget(host(progress: controller));
    await tester.pumpAndSettle();
    final cover0 = tester.widget(find.byType(SmartArtworkImage));
    final title0 = tester.widget(find.text('标题'));
    final double h0 = tester.getSize(find.byType(MiniPlayer)).height;

    // 与生产同构：进度自己往前走（值在变、树不重建），逐帧只该动留白层。
    // 直接改值而不是 forward()：这里要的是「进度源通知 → 留白层重算」这条链路，
    // 不依赖测试环境里 ticker 的推进方式。
    for (final double t in <double>[0.25, 0.5, 0.75]) {
      controller.value = t;
      await tester.pump();

      expect(
        identical(cover0, tester.widget(find.byType(SmartArtworkImage))),
        isTrue,
        reason: '封面（含 Image 提供者）必须跨帧缓存，不得逐帧重建',
      );
      expect(
        identical(title0, tester.widget(find.text('标题'))),
        isTrue,
        reason: '文字同样跨帧缓存（逐帧只有留白层那两层 Padding 重建）',
      );
    }

    final double hMid = tester.getSize(find.byType(MiniPlayer)).height;
    expect(
      hMid,
      greaterThan(h0),
      reason: '留白层必须照常逐帧插值 —— 否则就是动画被缓存吃掉了',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('左右内边距随进度源插值，进度条保持满宽', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);

    // 本机实测组合：R=58 / 底部 20dp → 终态左右 15dp。
    final controller = progress(tester, 0.0);
    await tester.pumpWidget(
      host(
        progress: controller,
        viewPaddingBottom: 20,
        cornerRadii: BorderRadius.circular(58),
      ),
    );
    await tester.pumpAndSettle();
    final double barWidth = tester.getSize(find.byType(MiniPlayer)).width;
    final double coverLeft0 = tester.getTopLeft(find.byType(SmartArtworkImage)).dx;
    // 进度条已从 M3ELinearProgressIndicator 换成同一 painter 的 formT=0 形态
    // （顶置直线），按 key 定位其 CustomPaint 盒子。
    final Finder progressFinder =
        find.byKey(const ValueKey('mini-player-progress'));
    final double progressWidth0 = tester.getSize(progressFinder).width;

    controller.value = 1.0;
    await tester.pump();
    final double coverLeft1 = tester.getTopLeft(find.byType(SmartArtworkImage)).dx;
    final double progressWidth1 = tester.getSize(progressFinder).width;

    expect(coverLeft0, closeTo(4.0, 0.01), reason: '底栏在场时走基础内边距');
    expect(coverLeft1, closeTo(15.0, 0.01), reason: '让位后按圆角反解值加宽');
    expect(progressWidth0, closeTo(barWidth, 0.01));
    expect(
      progressWidth1,
      closeTo(barWidth, 0.01),
      reason: '左右留白只加在内容行上，进度条必须保持满宽',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('常驻条进度按 M3E 直线口径配置（轨道色 / 间隙 / 端帽 / stop 点）', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 869);
    addTearDown(tester.view.reset);

    final controller = progress(tester, 0.0);
    await tester.pumpWidget(host(progress: controller));
    await tester.pumpAndSettle();

    final finder = find.byKey(const ValueKey('mini-player-progress'));
    final CustomPaint paint = tester.widget<CustomPaint>(finder);
    final PlayerBarProgressPainter painter =
        paint.painter! as PlayerBarProgressPainter;
    final ColorScheme scheme = Theme.of(tester.element(finder)).colorScheme;

    // formT=0 必须逐项复刻旧的 `M3ELinearProgressIndicator(value:, minHeight: 2,
    // backgroundColor: surfaceContainerHighest, color: primary)`：轨道色用的是调用点
    // **显式覆盖**的 surfaceContainerHighest，不是胶囊那套 onSurfaceVariant@0.16；
    // 端帽 round、gapSize 4、轨道末端 stop 点 4 都取 M3E 默认值（plan §2 修正段）。
    expect(painter.formT, 0.0);
    expect(painter.cornerRadius, 0.0);
    expect(painter.trackColor, scheme.surfaceContainerHighest);
    expect(
      painter.trackColor,
      isNot(scheme.onSurfaceVariant.withValues(alpha: 0.16)),
      reason: '常驻条轨道色不得被换成胶囊那一套',
    );
    expect(painter.activeColor, scheme.primary);
    expect(painter.gapSize, kPlayerBarProgressLineGap);
    expect(painter.strokeCap, StrokeCap.round);
    expect(painter.stopIndicatorSize, kPlayerBarProgressLineStopSize);
    // 进度盒高恒 = 直线描边宽（2dp），与 minHeight: 2 同尺寸。
    expect(
      tester.getSize(finder).height,
      closeTo(kPlayerBarProgressLineStroke, 0.01),
    );
    expect(tester.takeException(), isNull);
  });
}
