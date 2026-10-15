// 全屏播放器「横屏控制面板独立页」（宽屏「控制」页签）的组件测试。
//
// 覆盖：宽屏 tab 结构（播放列表 / 控制 / 歌词 / 评论）与控制页内容（进度条/传输行/
// 音量条）、控制页手势锁（**只罩滑条行**：按住滑条期间横滑不切页，滑条之外的区域
// 照常滑动切页）、窄屏不受影响、全局开关 kLandscapeDetachedControlsEnabled 的常驻与
// 即时切换门控、unity 音量档下滑条禁用与提示文案。
// MD3 / AM 两套播放器逐条等价覆盖。
// 复用 full_player_narrow_layout_test.dart 的受控音频 harness
//（ControlledAudioService + AudioServiceLoader 注入与同一套清理顺序）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/output_mode_coordinator.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/modules/player/am_transport_controls.dart';
import 'package:md3music/modules/player/full_player.dart';
import 'package:md3music/modules/player/full_player_am.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_cover_morph_layer.dart';
import 'package:md3music/modules/player/player_tab_pager.dart';
import 'package:md3music/modules/player/player_volume_state.dart';
import 'package:md3music/modules/player/player_wide_pane.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/utils/landscape_immersive.dart';
import 'package:md3music/widgets/md3e_transport_row.dart';
import 'package:md3music/widgets/playback_status_feedback.dart';
import 'package:md3music/widgets/player_seek_bar.dart';
import 'package:md3music/widgets/player_tab_strip.dart';
import 'package:md3music/widgets/player_top_bar_actions.dart';
import 'package:md3music/widgets/player_top_bar_tab_dots.dart';
import 'package:md3music/widgets/player_dock/player_control_dock.dart';
import 'package:md3music/widgets/player_dock/zen_fade.dart';
import 'package:md3music/widgets/player_volume_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

Song _song() => Song(
  id: 'landscape-controls-target',
  title: 'Landscape Controls Target',
  artist: 'Layout Artist',
  album: 'Layout Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track.mp3',
  isOnline: true,
);

void _mockPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    const services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    ),
    MockStreamHandler.inline(
      onListen: (_, events) => events.success(<String>['wifi']),
    ),
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('com.md3music.md3music/home_widget'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    services.SystemChannels.platform,
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' => Directory.systemTemp.path,
      _ => null,
    },
  );
  // DeviceCapabilities 经 media_store 通道取 SDK 版本（进程内一次性加载），
  // unity 音量子开关的「平台支持」判定依赖它；必须在首个 PlayerProvider
  // 创建之前注册，否则 sdkKnown 恒为 false、forceUnityVolume 永远不成立。
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('com.md3music.md3music/media_store'),
    (call) async => call.method == 'getSdkVersion' ? 35 : null,
  );
}

Widget _host(PlayerProvider player, KugouProvider kugou, Widget page) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<KugouProvider>.value(value: kugou),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(
          create: (_) => FavoritesProvider(syncOnStart: false),
        ),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
        ChangeNotifierProvider(create: (_) => ListenTogetherProvider()),
      ],
      child: MaterialApp(home: page),
    );

// 控制 tab 图标只在导航条内找：更多菜单弹层里另有一个 Icons.tune。
/// 圆点页签没有图标可找，按段上挂的 Semantics.label 定位 ——
/// 这也正是「label 是圆点唯一语义来源」那条约定的用处。
Finder _tabSegment(String label) => find.descendant(
  of: find.byType(PlayerTabStrip),
  matching: find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == label,
  ),
);

Finder _tuneIcon() => _tabSegment('控制');

Finder _lyricsIcon() => _tabSegment('歌词');

Finder _volumeSlider() => find.descendant(
  of: find.byType(PlayerVolumeBar),
  matching: find.byType(PlayerVolumeTrackBar),
);

PlayerTabPagerState _pagerState(WidgetTester tester) =>
    tester.state<PlayerTabPagerState>(find.byType(PlayerTabPager));

/// 横屏标题块（曲名 / 艺人·专辑）外挂的那层 [ZenFade]：Zen 下必须与顶栏、
/// 控制带同源淡出。用**祖先关系**定位，避免误命中顶栏/底部导航条的 ZenFade。
Finder _titleZenFade() => find.ancestor(
  of: find.byType(PlayerTitleSlot, skipOffstage: false),
  matching: find.byType(ZenFade),
);

/// 当前 peek 压暗因子：播放页在 `build()` 根上包了唯一一层 [ZenChromeDim]，
/// 读它的 notifier 比反推渲染不透明度确定得多。
double _dim(WidgetTester tester) =>
    tester.widget<ZenChromeDim>(find.byType(ZenChromeDim)).notifier!.value;

/// 走真机同一条入口进 Zen：长按封面满 2000ms。
/// 不能用 `tester.longPress` —— 它 500ms 就松手，被判为取消，Zen 不切换；
/// 也不能用**单次大跨度 pump**（首帧只起跳、动画不推进，实测 t=2100ms 仍未切换）。
Future<void> _longPressArtworkIntoZen(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(PlayerCoverSlot).first),
  );
  // 逐帧推进 2400ms：与真机 60fps 的帧序列一致
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 受控 harness：按 [viewport] 装载播放器并跑 [body]，结束后按
/// full_player_narrow_layout_test 的顺序清理（先缩起、再逐层 dispose）。
Future<void> _runPlayerTest(
  WidgetTester tester, {
  required Size viewport,
  required Widget Function() page,
  bool detachedControlsEnabled = true,
  bool tabDotsInTopBar = false,
  bool emitPlaying = true,
  required Future<void> Function(PlayerProvider player) body,
}) async {
  final originalTabIndex = playerTabIndex.value;
  addTearDown(() => playerTabIndex.value = originalTabIndex);
  // 进程级开关用完复位到默认（控制带常驻 = false、圆点在底部页签条 = false），
  // 避免污染同文件后续用例
  addTearDown(() => kLandscapeDetachedControlsEnabled.value = false);
  addTearDown(() => kTopBarTabDotsEnabled.value = false);
  final originalPhysicalSize = tester.view.physicalSize;
  final originalDevicePixelRatio = tester.view.devicePixelRatio;
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  KugouProvider.restoreLyric = (_) async => const KugouLyric(
    content: '[00:00.00]test lyric',
    decodedContent: '[00:00.00]test lyric',
  );
  kLandscapeDetachedControlsEnabled.value = detachedControlsEnabled;
  kTopBarTabDotsEnabled.value = tabDotsInTopBar;
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  final kugou = KugouProvider(registerDeviceOnStart: false);
  PlayerProvider? player;
  try {
    // 与 full_player_narrow_layout_test 同口径：PlayerProvider 必须在
    // tester.runAsync（真实异步区）内创建，fake-async 区里 audioReady 永不完成
    await tester.runAsync(() async {
      final activePlayer = PlayerProvider();
      player = activePlayer;
      await activePlayer.audioReady.timeout(const Duration(seconds: 10));
      final load = activePlayer.playPlaylist([_song()], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await load;
      if (emitPlaying) audio.emitPlaying(true);
    });

    await tester.pumpWidget(_host(player!, kugou, page()));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await body(player!);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    // 切到控制页会预建相邻评论页并发起评论请求；本地服务器在测试里永不就绪，
    // KugouApiClient 会挂着 8s 等待定时器。树已卸载（组件级定时器已清），
    // 这里用伪时钟冲掉这枚 zone 级定时器，让请求走「未就绪快速拒绝」路径。
    await tester.pump(const Duration(seconds: 9));
    player?.dispose();
    kugou.dispose();
    await tester.runAsync(() => HistoryRepository().flush());
    await audio.dispose();
    AudioServiceLoader.setTestOverride(null);
    KugouProvider.restoreLyric = null;
    tester.view.physicalSize = originalPhysicalSize;
    tester.view.devicePixelRatio = originalDevicePixelRatio;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, page) in <(String, Widget Function())>[
    ('MD3', () => const FullPlayer(dockMode: false)),
    ('AM', () => const AmStyleFullPlayer(dockMode: false)),
  ]) {
    final transportRow = find.byType(
      name == 'MD3' ? MD3ETransportRow : AMTransportControls,
    );

    testWidgets('$name 宽屏出现「控制」页签且点按进入控制页', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        body: (player) async {
          // 宽屏顺序为 播放列表0 / 控制1 / 歌词2 / 评论3。
          // 竖屏默认停在专辑页，专辑页与控制页互为跨形态替身
          // （见 player_tab_layout.dart 的 _twinKind），故冷启动进横屏直接落在控制页。
          expect(_pagerState(tester).page, 1);
          expect(_tuneIcon(), findsOneWidget);
          expect(
            tester.widget<PlayerTabPager>(find.byType(PlayerTabPager)).children,
            hasLength(4),
          );
          // 控制页承载原常驻区三件套：进度条 + 传输行 + 音量条
          expect(find.byType(PlayerSeekBar), findsOneWidget);
          expect(transportRow, findsOneWidget);
          expect(find.byType(PlayerVolumeBar), findsOneWidget);
          expect(find.byType(PlaybackStatusFeedback), findsOneWidget);
          // 横条音量**不写百分数**：量程由两端各一支喇叭标出
          expect(find.textContaining('%'), findsNothing);
          final sliderRect = tester.getRect(_volumeSlider());
          final quietRect = tester.getRect(
            find.descendant(
              of: find.byType(PlayerVolumeBar),
              matching: find.byIcon(Icons.volume_down),
            ),
          );
          final loudRect = tester.getRect(
            find.descendant(
              of: find.byType(PlayerVolumeBar),
              matching: find.byIcon(Icons.volume_up),
            ),
          );
          // 左「声音小」在轨道左侧、右「声音大」在轨道右侧，三者同一条水平带
          expect(quietRect.right, lessThanOrEqualTo(sliderRect.left + 0.5));
          expect(loudRect.left, greaterThanOrEqualTo(sliderRect.right - 0.5));
          for (final icon in [quietRect, loudRect]) {
            expect(
              (icon.center.dy - sliderRect.center.dy).abs(),
              lessThan(1),
              reason: '喇叭/轨道应在同一水平带上，不是上下错落',
            );
          }
          expect(
            sliderRect.height,
            greaterThanOrEqualTo(28),
            reason: '命中框不得小于 Apple 最小控件尺寸 28（24 那一版是踩过的坑）',
          );
          // 控制页纵向撑满到与左栏封面块同一段区间：进度条贴顶、音量条贴底
          final pageRect = tester.getRect(find.byType(PlayerTabPager));
          expect(
            tester.getRect(find.byType(PlayerSeekBar)).top,
            lessThan(pageRect.top + 40),
            reason: '进度条应贴着控制页顶部（状态反馈空态时 0 高）',
          );
          expect(
            sliderRect.bottom,
            greaterThan(pageRect.bottom - 40),
            reason: '音量条应贴着控制页底部',
          );
          // 导航条点按仍然有效：歌词 ↔ 控制
          await tester.tap(_lyricsIcon());
          await tester.pumpAndSettle();
          expect(_pagerState(tester).page, 2);
          await tester.tap(_tuneIcon());
          await tester.pumpAndSettle();
          expect(_pagerState(tester).page, 1);
        },
      );
    });

    testWidgets('$name 控制页手势锁：按住滑条不切页，滑条之外照常翻页', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        body: (player) async {
          final pager = _pagerState(tester);
          expect(pager.page, 1, reason: '冷启动进横屏落在控制页');
          // 对照：滑条之外（本页顶部留白）横滑照常翻页 控制 → 歌词
          final pagerRect = tester.getRect(find.byType(PlayerTabPager));
          await tester.dragFrom(
            Offset(pagerRect.center.dx, pagerRect.top + 12),
            const Offset(-640, 0),
          );
          await tester.pumpAndSettle();
          expect(pager.page, 2);
          await tester.tap(_tuneIcon());
          await tester.pumpAndSettle();
          expect(pager.page, 1);
          // 手势锁须在 pointer down 与 move 之间生效：先按住滑条让控制页
          // Listener 置锁（pager 物理换 NeverScrollableScrollPhysics），
          // 再横拖 —— 页面必须停在控制页
          final gesture = await tester.startGesture(
            tester.getCenter(_volumeSlider()),
          );
          await tester.pump(const Duration(milliseconds: 50));
          await gesture.moveBy(const Offset(-400, 0));
          await tester.pump(const Duration(milliseconds: 50));
          await gesture.moveBy(const Offset(-400, 0));
          await tester.pump(const Duration(milliseconds: 50));
          expect(pager.page, 1);
          await gesture.up();
          await tester.pumpAndSettle();
          expect(pager.page, 1);
          expect(find.byType(PlayerVolumeBar), findsOneWidget);
          // 进度条那一行同样在锁的作用域内（它也是水平拖动）
          final seek = await tester.startGesture(
            tester.getCenter(find.byType(PlayerSeekBar)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          await seek.moveBy(const Offset(-400, 0));
          await tester.pump(const Duration(milliseconds: 50));
          await seek.moveBy(const Offset(-400, 0));
          await tester.pump(const Duration(milliseconds: 50));
          await seek.up();
          await tester.pumpAndSettle();
          expect(pager.page, 1, reason: '拖进度条也不切页');
        },
      );
    });

    testWidgets('$name 控制页滑条之外的横滑仍然切页', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        body: (player) async {
          final pager = _pagerState(tester);
          await tester.tap(_tuneIcon());
          await tester.pumpAndSettle();
          expect(pager.page, 1);
          // 手势锁不能罩住整页：否则在控制页左右滑动永远切不了页，
          // 只能靠底部导航条离开。这里从页面顶部留白起手（不碰任何滑条行）。
          final pagerRect = tester.getRect(find.byType(PlayerTabPager));
          await tester.dragFrom(
            Offset(pagerRect.center.dx, pagerRect.top + 12),
            const Offset(-640, 0),
          );
          await tester.pumpAndSettle();
          expect(pager.page, 2, reason: '左滑：控制页 → 歌词页');
        },
      );
    });

    testWidgets('$name 点喇叭一键静音、再点恢复原音量', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        body: (player) async {
          // 先给一个非满值：要验的是"恢复**原**音量"，不是恒回 100%
          await player.setVolume(0.6);
          await tester.pumpAndSettle();
          // 横条不写百分数，值只从轨道长度与无障碍读数体现
          expect(find.textContaining('%'), findsNothing);

          // 左侧「声音小」的喇叭 = 静音开关
          await tester.tap(
            find.descendant(
              of: find.byType(PlayerVolumeBar),
              matching: find.byIcon(Icons.volume_down),
            ),
          );
          await tester.pumpAndSettle();
          expect(player.volume, 0, reason: '静音走当前档的下发（这里是应用音量）');
          final offIcon = find.descendant(
            of: find.byType(PlayerVolumeBar),
            matching: find.byIcon(Icons.volume_off),
          );
          expect(
            offIcon,
            findsOneWidget,
            reason: '静音态必须换图标，不能只靠变灰（color-not-only）',
          );

          await tester.tap(offIcon);
          await tester.pumpAndSettle();
          expect(player.volume, 0.6, reason: '再点回到静音前的那个值，而不是 100%');
          expect(
            find.byIcon(Icons.volume_off),
            findsNothing,
            reason: '恢复后左侧回到「声音小」的常态图标',
          );
          // 右侧「声音大」只是量程示意，不可点：点它什么都不该发生
          await player.setVolume(0.4);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(PlayerVolumeBar),
              matching: find.byIcon(Icons.volume_up),
            ),
          );
          await tester.pumpAndSettle();
          expect(player.volume, 0.4, reason: '右侧喇叭是刻度示意，不挂动作');
        },
      );
    });

    testWidgets('$name 窄屏无「控制」页签且底部常驻控制区保留', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(400, 800),
        page: page,
        body: (player) async {
          expect(_tuneIcon(), findsNothing);
          expect(find.byType(PlayerVolumeBar), findsNothing);
          // 常驻底部控制区仍在：进度条 + 传输行 + 含封面段的导航条
          expect(find.byType(PlayerSeekBar), findsOneWidget);
          expect(transportRow, findsOneWidget);
          expect(_tabSegment('封面'), findsOneWidget);
          expect(
            tester.widget<PlayerTabPager>(find.byType(PlayerTabPager)).children,
            hasLength(4),
          );
        },
      );
    });

    testWidgets('$name 宽屏关闭「横屏控制面板独立页」后控制带常驻、无「控制」页签', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          // 常驻档：控制不再是页
          expect(_tuneIcon(), findsNothing);
          expect(_tabSegment('封面'), findsNothing);
          expect(
            tester.widget<PlayerTabPager>(find.byType(PlayerTabPager)).children,
            hasLength(3),
          );
          // 尺与传输簇都在左栏（曲名下方），任何一页都看得见
          expect(find.byType(PlayerSeekBar), findsOneWidget);
          expect(transportRow, findsOneWidget);
          expect(find.byType(PlaybackStatusFeedback), findsOneWidget);
          // 音量**不在**常驻带里：带高要让给尺与封面，它搬进了顶栏 ⋯ 的更多菜单
          expect(find.byType(PlayerVolumeBar), findsNothing);
          // 运行中切回独立页：监听器触发 _syncTabLayout，控制页签即时恢复
          kLandscapeDetachedControlsEnabled.value = true;
          await tester.pumpAndSettle();
          expect(_tuneIcon(), findsOneWidget);
        },
      );
    });

    testWidgets('$name 宽屏 unity 音量档下控制页滑条禁用并显示提示', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        emitPlaying: false,
        body: (player) async {
          final OutputModeCoordinator coord = OutputModeCoordinator.instance;
          // 中途断言失败也要把进程级单例复位（正常路径在下方 runAsync 内复位）
          addTearDown(() async {
            await coord.setEnabled(false);
            await coord.setViaSystem(false);
            coord.consumeFallbackNotice();
          });
          // setEnabled/setViaSystem 有真实异步落盘，需逃出 fake-async 区
          await tester.runAsync(() async {
            await coord.setViaSystem(true);
            await coord.setEnabled(true);
          });
          expect(coord.isDirectPcmActive, isTrue);
          // 前提：_mockPlatformChannels 已把 media_store/getSdkVersion mock 成 35，
          // unity 音量子开关的平台门控因此生效
          expect(coord.forceUnityVolume, isTrue);
          await tester.tap(_tuneIcon());
          await tester.pumpAndSettle();
          expect(find.text(PlayerVolumeState.unityHintLabel), findsOneWidget);
          expect(find.text('关闭 unity 音量，恢复应用内滑块'), findsOneWidget);
          final PlayerVolumeTrackBar bar = tester.widget<PlayerVolumeTrackBar>(
            _volumeSlider(),
          );
          expect(bar.enabled, isFalse);
          expect(bar.onChanged, isNull);
          expect(bar.onDragEnd, isNull);
          // unity 档不可调 → 静音按钮同样禁用：值恒 1.0，点它应当什么都不动
          //（静默失败比没有按钮更糟，所以这里连手势都不挂）
          await tester.tap(
            find.descendant(
              of: find.byType(PlayerVolumeBar),
              matching: find.byIcon(Icons.volume_up),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('0%'), findsNothing, reason: '禁用态点喇叭不得下发静音');
          // 复位顺序：先关外层再切内层，避免「外层开着时切内层」触发回退提示 toast
          await tester.runAsync(() async {
            await coord.setEnabled(false);
            await coord.setViaSystem(false);
            coord.consumeFallbackNotice();
          });
        },
      );
    });

    testWidgets('$name dock 档：0 步可达传输簇，内容区横滑不会被滑条锁住', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          final pager = _pagerState(tester);
          // 常驻带挂在 pager 之外：停在任何内容页都不用切页就能按暂停
          expect(transportRow, findsOneWidget);
          expect(find.byType(PlayerSeekBar), findsOneWidget);

          // 内容区横滑照常切页
          final before = pager.page;
          final pagerRect = tester.getRect(find.byType(PlayerTabPager));
          await tester.dragFrom(
            Offset(pagerRect.center.dx, pagerRect.center.dy),
            const Offset(-640, 0),
          );
          await tester.pumpAndSettle();
          expect(pager.page, isNot(before), reason: '切页成功');

          // 再拖常驻带上的进度尺：dock 档没有 _lockSliderRowSwipe，
          // 按住滑条不会把整页翻页锁掉（计划 §2.2 ①、§1.6 checklist 退役）。
          // 音量已经不在带里了，尺是带里唯一可拖的东西。
          final afterFirstSwipe = pager.page;
          final slider = await tester.startGesture(
            tester.getCenter(find.byType(PlayerSeekBar)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          await slider.moveBy(const Offset(-300, 0));
          await tester.pump(const Duration(milliseconds: 50));
          await slider.up();
          await tester.pumpAndSettle();
          expect(pager.page, afterFirstSwipe, reason: '拖滑条只改音量，不抢翻页');

          // 拖完滑条之后，内容区仍然滑得动（锁没卡在置位状态）
          await tester.dragFrom(
            Offset(pagerRect.center.dx, pagerRect.center.dy),
            const Offset(640, 0),
          );
          await tester.pumpAndSettle();
          expect(pager.page, isNot(afterFirstSwipe));
        },
      );
    });

    testWidgets('$name 三档视口都不带常驻音量条（音量在 ⋯ 更多菜单里）', (
      tester,
    ) async {
      for (final viewport in <Size>[
        const Size(1280, 800),
        const Size(800, 360),
        const Size(640, 300),
      ]) {
        await _runPlayerTest(
          tester,
          viewport: viewport,
          page: page,
          detachedControlsEnabled: false,
          body: (player) async {
            // 带高让给尺与封面：三档一律不放音量（计划 C 轮）
            expect(
              find.byType(PlayerVolumeBar),
              findsNothing,
              reason: '$viewport 档不该有常驻音量条',
            );
            // 尺与传输三档都常驻
            expect(find.byType(PlayerSeekBar), findsOneWidget);
            expect(transportRow, findsOneWidget);
            // 也不再留 ⌃ 出口（与 ⋯ 功能重复，已删）
            expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
          },
        );
      }
    });


    testWidgets('$name dock 档：800×360 默认字号下歌词 5 行可达（计划验收硬线）', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(800, 360),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          // 常驻带吃回的高度必须仍留出 5 行歌词：按 30dp/行（实测字号 22 的
          // 行高上限）算下限，比逐行量行高更稳，也不随歌词内容抖动。
          const rowBudget = 30.0;
          final contentHeight =
              tester.getSize(find.byType(PlayerTabPager)).height;
          expect(
            contentHeight,
            greaterThanOrEqualTo(5 * rowBudget),
            reason: '800×360 常驻带下歌词可视高度不足 5 行（实测 $contentHeight）',
          );
          // 常驻档仍在：尺与传输簇都在左栏曲名下方
          expect(find.byType(PlayerSeekBar), findsOneWidget);
          expect(transportRow, findsOneWidget);
          expect(find.byType(PlayerVolumeBar), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    });

    testWidgets('$name 音量入口：常驻带没有，独立控制页里有且全程不写百分数', (
      tester,
    ) async {
      Finder percentLabels() => find.byWidgetPredicate(
        (w) => w is Text && (w.data?.endsWith('%') ?? false),
      );

      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          // 常驻带不放音量（带高让给尺与封面），也不留 ⌃ 出口 —— 入口在顶栏 ⋯
          expect(find.byType(PlayerVolumeBar), findsNothing);
          expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
        },
      );

      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        detachedControlsEnabled: true,
        body: (player) async {
          await tester.tap(_tuneIcon());
          await tester.pumpAndSettle();
          expect(find.byType(PlayerVolumeBar), findsOneWidget);
          // 两端各一支喇叭：左 = 静音开关（默认档 volume_down），右 = 量程示意
          expect(find.byIcon(Icons.volume_down), findsOneWidget);
          expect(find.byIcon(Icons.volume_up), findsOneWidget);
          expect(percentLabels(), findsNothing, reason: '音量行不写百分数');

          final slider = await tester.startGesture(
            tester.getCenter(_volumeSlider()),
          );
          await slider.moveBy(const Offset(-40, 0));
          await tester.pump();
          expect(percentLabels(), findsNothing, reason: '拖动期间也不写百分数');
          await slider.up();
          await tester.pumpAndSettle();
        },
      );
    });

    // 音质胶囊的落点：**统一在顶栏**，竖屏 / 宽屏常驻档 / 宽屏独立控制页三处同规则。
    // 唯一例外是车机窄面板（dockMode），那里顶栏塞不下，徽章留在时间数字那一行。
    testWidgets('$name 常驻档：音质标识只有一枚，且在顶栏', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          final label = player.currentQualityLabel;
          expect(
            find.descendant(
              of: find.byType(PlayerControlDock),
              matching: find.text(label),
            ),
            findsNothing,
            reason: '带里不该再有一枚音质胶囊',
          );
          expect(
            find.text(label),
            findsOneWidget,
            reason: '同一信息不能出现两次',
          );
          final rect = tester.getRect(find.text(label));
          expect(
            rect.top,
            lessThan(80),
            reason: '落在顶栏那条水平线内，实测 top=${rect.top}',
          );
          expect(
            rect.right,
            lessThanOrEqualTo(1280),
            reason: '顶栏右侧一组元素排得下，没被挤出屏幕',
          );
        },
      );
    });

    testWidgets('$name 独立控制页：音质标识同样在顶栏，控制页内不再出现', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        body: (player) async {
          final label = player.currentQualityLabel;
          // detached 档与常驻档同规则：徽章归顶栏，控制页那一行只留时间数字。
          expect(
            find.descendant(of: find.byType(PlayerControlDock), matching: find.text(label)),
            findsNothing,
            reason: '控制页里不该有第二枚',
          );
          expect(find.text(label), findsOneWidget);
          expect(
            tester.getRect(find.text(label)).top,
            lessThan(80),
            reason: '独立控制页的音质标识也在顶栏那条水平线内',
          );
        },
      );
    });

    testWidgets('$name 竖屏：音质标识也在顶栏，与尾部胶囊同一条水平线', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(400, 800),
        page: page,
        body: (player) async {
          final label = player.currentQualityLabel;
          expect(
            find.text(label),
            findsOneWidget,
            reason: '进度条那一行不再有它，整树只有一枚',
          );
          final badge = tester.getRect(find.text(label));
          expect(
            badge.top,
            lessThan(80),
            reason: '回到顶栏，实测 top=${badge.top}',
          );
          // 顶栏右侧三件（徽章 + 尾部胶囊 + 让位）不得把徽章挤出屏幕
          expect(badge.right, lessThanOrEqualTo(400));
          final more = tester.getRect(find.byIcon(Icons.more_horiz));
          expect(
            badge.bottom - more.bottom,
            lessThan(12),
            reason: '与尾部胶囊在同一行（实测 Δbottom=${badge.bottom - more.bottom}）',
          );
        },
      );
    });

    testWidgets('$name 独立控制页：中间三控件比常驻档放大', (tester) async {
      late Rect detachedPlay;
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        body: (player) async {
          detachedPlay = tester.getRect(transportRow);
          // 手势锁仍在（控制页内滑条与 pager 同树，必须锁）
          expect(find.byType(PlayerVolumeBar), findsOneWidget);
        },
      );
      late Rect bandPlay;
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          bandPlay = tester.getRect(transportRow);
        },
      );
      expect(
        detachedPlay.height,
        greaterThan(bandPlay.height),
        reason: '独立控制页有整页高度，中间三控件用全尺寸档；'
            '常驻带挤压空间才降档（实测 detached ${detachedPlay.height} vs band ${bandPlay.height}）',
      );
    });

    testWidgets('$name 常驻档：尺与播放键都落在左栏，圆点留在右栏底部', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(1280, 800),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          final paneRight = tester.getRect(find.byType(PlayerTabPager)).left;
          final transport = tester.getRect(transportRow);
          final seek = tester.getRect(find.byType(PlayerSeekBar));
          final dots = tester.getRect(find.byType(PlayerTabStrip));
          final cover = tester.getRect(find.byType(PlayerCoverSlot).first);
          final title = tester.getRect(find.byType(PlayerTitleSlot));
          // 左右边距只有一个来源：按左栏宽取的比例内衬（改造前是写死的 16，
          // 外加 dock 自带的第二层 16，四件宽度各不相同）
          final gutter = PlayerWidePane.gutter(paneRight);
          expect(
            seek.center.dx,
            lessThan(1280 / 2),
            reason: '进度尺已搬到左栏（封面与曲名那一侧）',
          );
          expect(
            transport.center.dx,
            lessThan(1280 / 2),
            reason: '播放控件在左半栏',
          );
          // 纵向顺序：曲名 → 进度尺 → 播放键
          expect(
            seek.top,
            greaterThan(title.bottom - 1),
            reason: '尺落在曲名正下方，实测 ${seek.top} vs 曲名底 ${title.bottom}',
          );
          expect(
            transport.top,
            greaterThan(seek.bottom - 1),
            reason: '播放键落在尺的再下方，实测 ${transport.top} vs 尺底 ${seek.bottom}',
          );
          // 四件共用同一条左右边线（1280×800 下封面由宽度封顶，与尺/播放键同宽）
          for (final (label, rect) in <(String, Rect)>[
            ('封面', cover),
            ('曲名', title),
            ('进度尺', seek),
          ]) {
            expect(
              rect.left,
              closeTo(gutter, 1),
              reason: '$label 左缘应贴在左栏比例内衬 $gutter 上，实测 ${rect.left}',
            );
            expect(
              rect.right,
              closeTo(paneRight - gutter, 1),
              reason: '$label 右缘应贴在左栏内容宽右端，实测 ${rect.right} vs '
                  '${paneRight - gutter}',
            );
          }
          // 播放键那一簇：三按钮本体是定宽居中的，只能保证不越出内衬盒
          expect(
            transport.left,
            greaterThanOrEqualTo(gutter - 0.5),
            reason: '播放键不得越出左栏内衬',
          );
          expect(
            transport.right,
            lessThanOrEqualTo(paneRight - gutter + 0.5),
            reason: '播放键不得越出左栏内衬',
          );
          // 圆点仍留在右栏底部：尺走人了，它下面不再压着任何东西
          expect(
            dots.center.dx,
            greaterThan(1280 / 2),
            reason: '页签圆点归属右栏',
          );
          expect(seek.bottom, lessThan(dots.top), reason: '尺已离开右栏，圆点在它下方');
        },
      );
    });

    // 手机横屏（800×360）是这档最常遇到的形态，也是封面最先被高度卡住的一档：
    // 左栏装得下「曲名 + 尺 + 播放键」，于是四件共用同一条比例内衬，而封面边长
    // 必须仍然等于曲名盒宽度 —— 预留值一旦小于实测 chrome，`Flexible` 就会把封面
    // 再压一截，封面与曲名的左右边缘又对不齐（改造前实测 147 vs 120）。
    testWidgets('$name 常驻档（手机横屏）：尺落在曲名与播放键之间，封面与曲名同宽', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(800, 360),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          final paneRight = tester.getRect(find.byType(PlayerTabPager)).left;
          final cover = tester.getRect(find.byType(PlayerCoverSlot).first);
          final title = tester.getRect(find.byType(PlayerTitleSlot));
          final seek = tester.getRect(find.byType(PlayerSeekBar));
          final transport = tester.getRect(transportRow);
          final dots = tester.getRect(find.byType(PlayerTabStrip));
          final gutter = PlayerWidePane.gutter(paneRight);
          expect(
            seek.center.dx,
            lessThan(paneRight),
            reason: '尺在左栏（实测 ${seek.center.dx} vs 分栏线 $paneRight）',
          );
          expect(seek.top, greaterThan(title.bottom - 1), reason: '曲名 → 尺');
          expect(transport.top, greaterThan(seek.bottom - 1), reason: '尺 → 播放键');
          expect(
            cover.width,
            closeTo(title.width, 1),
            reason: '封面边长必须等于曲名盒宽，否则两者左右边缘对不齐。'
                '实测封面 $cover / 曲名 $title',
          );
          expect(
            seek.left,
            closeTo(gutter, 1),
            reason: '尺贴在左栏比例内衬 $gutter 上（不再叠 dock 自带的 16），实测 ${seek.left}',
          );
          expect(
            seek.right,
            closeTo(paneRight - gutter, 1),
            reason: '尺横贯左栏内容宽，实测 ${seek.right}',
          );
          expect(
            dots.center.dx,
            greaterThan(paneRight),
            reason: '圆点仍归右栏，实测 ${dots.center.dx}',
          );
          // 提示条跟着尺走 would 溢出，故留在右栏 chrome：实例数必须还是 1
          expect(find.byType(PlaybackStatusFeedback), findsOneWidget);
        },
      );
    });

    // 兜底档：640×300 这类小横屏的左栏纵向只有 218，塞不下「曲名 + 尺 + 播放键」
    // （预留 190 + 封面下限 64 已经超了），尺退回右栏底部那条 chrome。
    // 硬塞的代价实测是把封面压成 64×33 的扁方块 —— 比进度条在右边更难看。
    testWidgets('$name 常驻档兜底：左栏装不下时尺回右栏，封面保持正方形', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(640, 300),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          final paneRight = tester.getRect(find.byType(PlayerTabPager)).left;
          final cover = tester.getRect(find.byType(PlayerCoverSlot).first);
          final seek = tester.getRect(find.byType(PlayerSeekBar));
          expect(
            seek.center.dx,
            greaterThan(paneRight),
            reason: '栏高不够，尺留在右栏底部那条 chrome（实测 ${seek.center.dx} vs $paneRight）',
          );
          expect(
            (cover.width - cover.height).abs(),
            lessThanOrEqualTo(1),
            reason: '封面必须是正方形，实测 $cover',
          );
          expect(tester.takeException(), isNull);
        },
      );
    });

    // 横屏顶栏尾部胶囊（含 ⋯）贴的是**页面比例内衬**，不再是写死的 8+2=10：
    // 左栏封面/曲名/进度尺都按 PlayerWidePane.gutter 对齐，胶囊若还贴旧的 10，
    // 右上角就会比整页边距更靠边，看着像被挤出去的一块。
    testWidgets('$name 横屏顶栏尾部胶囊与左栏共用比例内衬', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(800, 360),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          final capsule = tester.getRect(find.byType(TopBarTrailingCapsule));
          final gutter = PlayerWidePane.gutter(800 * 4 / 10);
          final inset = 800 - capsule.right;
          expect(
            inset,
            greaterThan(14),
            reason: '胶囊右缘不得再贴写死的 10dp（实测 inset $inset，gutter $gutter）',
          );
          expect(
            inset,
            lessThanOrEqualTo(gutter + 2.5),
            reason: '胶囊右缘应落在比例内衬附近（实测 inset $inset vs gutter $gutter）',
          );
          expect(capsule.top, lessThan(80), reason: '胶囊仍留在顶栏那条水平线上');
        },
      );
    });

    // 横屏（宽屏形态）尾部胶囊**不带连体底色**：那一版有整行宽度、文案恒显，
    // 底色会把一串各自独立的操作框成一块面板，压在封面/壁纸上尤其显脏。
    // 竖屏收缩态与「关掉收缩开关」两态仍保留底色（由组件侧的用例钉住），
    // 所以这里钉的是「wide → 裸」这条宿主接线。
    testWidgets('$name 横屏顶栏尾部胶囊是裸的（无连体底色）', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(800, 360),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          // 只认「涂了不透明底色 + StadiumBorder」的那层连体背景；
          // 涟漪用的 Material 是 Colors.transparent，不算背景。
          final backgrounds = find.descendant(
            of: find.byType(TopBarTrailingCapsule),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Material &&
                  w.shape is StadiumBorder &&
                  w.color != Colors.transparent,
            ),
          );
          expect(
            backgrounds,
            findsNothing,
            reason: '横屏尾部胶囊必须裸着：每格与 ⋯ 一样是裸图标 + 文案，不压在底色里',
          );
          // 裸掉之后交互与内容都还在（不是把整颗胶囊藏了）
          expect(
            find.descendant(
              of: find.byType(TopBarTrailingCapsule),
              matching: find.byIcon(Icons.more_horiz),
            ),
            findsOneWidget,
            reason: '⋯ 仍在本位',
          );
          expect(
            tester.widget<TopBarTrailingCapsule>(
              find.byType(TopBarTrailingCapsule),
            ).showBackground,
            isFalse,
            reason: '宽屏接线确实是 showBackground: !wide',
          );
        },
      );
    });

    // 「顶栏页签圆点」开关（默认关）的两态：关 = 页签条留在竖屏**底部**，且是改造前的
    // icon + 指示线形态；开 = 底部那条取消，改为顶栏中央的一排圆点。
    // 横屏位置不随开关变（恒在右栏底部：那里的顶栏没有可供挤进中段的宽度），
    // 但**形态与竖屏底部同源** —— 关 = icon + 指示线，开 = 圆点。
    testWidgets('$name 页签条：默认在竖屏底部且为 icon，开启后在顶栏为圆点', (
      tester,
    ) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(400, 800),
        page: page,
        body: (player) async {
          final center = tester.getCenter(find.byType(PlayerTabStrip));
          expect(
            (center.dx / 400 - 0.5).abs(),
            lessThan(0.06),
            reason: '竖屏居中于整宽，实测 ${center.dx}',
          );
          expect(
            center.dy,
            greaterThan(800 - 160),
            reason: '默认（开关关）：页签条留在传输键下方，实测 ${center.dy}',
          );
          // 原形态：图标 + 指示线，而不是圆点
          expect(
            find.descendant(
              of: find.byType(PlayerTabStrip),
              matching: find.byIcon(Icons.queue_music),
            ),
            findsOneWidget,
            reason: '关闭时底部必须是 icon 形态，与改造前一致',
          );
          expect(
            find.descendant(
              of: find.byType(PlayerTabStrip),
              matching: find.byType(AnimatedContainer),
            ),
            findsNothing,
            reason: 'icon 形态不叠加圆点',
          );
          expect(
            find.descendant(
              of: find.byType(PlayerTopBarTabDots),
              matching: find.byType(PlayerTabStrip),
            ),
            findsNothing,
          );
        },
      );

      await _runPlayerTest(
        tester,
        viewport: const Size(400, 800),
        page: page,
        tabDotsInTopBar: true,
        body: (player) async {
          final dots = tester.getRect(find.byType(PlayerTabStrip));
          // 顶栏右侧现在是「音质胶囊 + 尾部胶囊」两件，圆点按尾部宽度整体左移，
          // 因此不再居中是**预期**（旧阈值 0.12 是尾部只有一件时量的）。
          // 这里改判行为本身：同一水平线、不与尾部重叠、且被挤向返回键一侧。
          expect(
            dots.center.dy,
            lessThan(100),
            reason: '开启后升到顶栏那条水平线上，实测 ${dots.center.dy}',
          );
          final quality = tester.getRect(find.text(player.currentQualityLabel));
          expect(
            dots.right,
            lessThanOrEqualTo(quality.left - PlayerTopBarTabDots.endGap + 1),
            reason: '圆点右缘给尾部留出 endGap，实测 dots.right=${dots.right} '
                'quality.left=${quality.left}',
          );
          expect(
            dots.center.dx,
            lessThan(400 * 0.5),
            reason: '尾部变宽后圆点让位到左半边，实测 ${dots.center.dx}',
          );
          expect(
            find.descendant(
              of: find.byType(PlayerTabStrip),
              matching: find.byIcon(Icons.queue_music),
            ),
            findsNothing,
            reason: '顶栏形态只有圆点',
          );
          // 整树只有一处页签条：底部的随开关一起收起，不留第二排
          expect(find.byType(PlayerTabStrip), findsOneWidget);
        },
      );
    });

    testWidgets('$name 横屏页签条位置不变，形态随开关换（关=icon，开=圆点）', (
      tester,
    ) async {
      for (final dotsInTopBar in <bool>[false, true]) {
        await _runPlayerTest(
          tester,
          viewport: const Size(1280, 800),
          page: page,
          detachedControlsEnabled: false,
          tabDotsInTopBar: dotsInTopBar,
          body: (player) async {
            final center = tester.getCenter(find.byType(PlayerTabStrip));
            // 4/6 分栏：右半栏中心 = 40% + 60%/2 = 70%
            expect(
              (center.dx / 1280 - 0.7).abs(),
              lessThan(0.06),
              reason: '横屏居中于右半栏（开关=$dotsInTopBar），实测 ${center.dx}',
            );
            expect(
              center.dy,
              greaterThan(800 - 120),
              reason: '横屏的页签条恒留在右栏**底部**（尺已搬到左栏曲名下方），实测 ${center.dy}',
            );
            final stripIcon = find.descendant(
              of: find.byType(PlayerTabStrip),
              matching: find.byIcon(Icons.queue_music),
            );
            if (dotsInTopBar) {
              expect(
                stripIcon,
                findsNothing,
                reason: '开启时横屏同样是圆点',
              );
            } else {
              expect(
                stripIcon,
                findsOneWidget,
                reason: '关闭（默认）时横屏回到 icon + 指示线形态',
              );
            }
            // 整树只有一处页签条：顶栏那枚只在竖屏且开关开启时才渲染
            expect(find.byType(PlayerTabStrip), findsOneWidget);
          },
        );
      }
    });

    // ── Zen 下的 chrome 分层：曲名 / 艺人·专辑与顶栏、控制带一并淡出 ──
    //
    // 横屏 Zen 的左栏要只剩封面：标题块若留在树上，既与「只剩封面与歌词」的
    // Zen 语义冲突，也会在沉浸背景上糊出一行点得动却没用的文字。
    testWidgets('$name 横屏 Zen：曲名 / 艺人·专辑随 chrome 一并淡出', (tester) async {
      // 手机横屏（medium，600~839）与平板/折叠展开（expanded，>=840）是**两套独立
      // 布局**，标题块两处都要挂 ZenFade；只改一处就会在另一形态漏出一行曲名。
      for (final viewport in <Size>[
        const Size(800, 360),
        const Size(1280, 800),
      ]) {
        await _runPlayerTest(
          tester,
          viewport: viewport,
          page: page,
          // 常驻控制带档（默认档）：左栏是「封面 + 曲名 + 控制带」三件套
          detachedControlsEnabled: false,
          body: (player) async {
            expect(
              find.byType(PlayerTitleSlot),
              findsOneWidget,
              reason: '$viewport 左栏标题块应存在',
            );
            final fader = _titleZenFade();
            expect(
              fader,
              findsOneWidget,
              reason: '$viewport 横屏标题块必须挂在 ZenFade 上',
            );
            expect(
              tester.getSize(fader).height,
              greaterThan(0),
              reason: '$viewport 常态下标题块照常占位',
            );

            await _longPressArtworkIntoZen(tester);

            expect(
              kPlayerZenImmersiveActive.value,
              isTrue,
              reason: '$viewport 确实进了 Zen',
            );
            expect(
              tester.getSize(fader).height,
              0,
              reason: '$viewport Zen 下标题块要折成 0 高（与传输簇、顶栏同一套 ZenFade）',
            );
            expect(
              find.byType(PlayerTitleSlot),
              findsNothing,
              reason: '$viewport Offstage 之后标题退出命中树，不留看不见却拦手势的一行',
            );
          },
        );
      }
    });

    testWidgets('$name 竖屏 Zen 不受影响：曲名照常留在封面上方', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(400, 800),
        page: page,
        body: (player) async {
          expect(find.byType(PlayerTitleSlot), findsOneWidget);
          expect(
            _titleZenFade(),
            findsNothing,
            reason: '本次只淡出横屏（宽屏布局）的标题块，竖屏 compact 不挂 ZenFade',
          );

          await _longPressArtworkIntoZen(tester);
          expect(kPlayerZenImmersiveActive.value, isTrue, reason: '确实进了 Zen');
          expect(
            tester.getSize(find.byType(PlayerTitleSlot)).height,
            greaterThan(0),
            reason: '竖屏 Zen 下曲名/艺人·专辑保持可见',
          );
        },
      );
    });

    // ── 横屏 Zen 唤出 chrome 的倒计时渐隐 ──
    //
    // 需求是「看得到还剩多久收回」：整段 4s 停留里 chrome 不透明度线性降到 20%，
    // **抵达 20% 的那一帧**恢复 Zen（余下由 ZenFade 自己的 400ms 把 20% 补到 0）。
    // 斜坡挂在自建 100ms Timer 上（AGENTS §10.3：低于 60fps 的档不走共享节拍），
    // 所以这三条用例**全程只能分步 pump** —— pumpAndSettle 等不到常驻定时器 idle，
    // 还会把中间的采样点一口吞掉。
    testWidgets(
      '$name 横屏 Zen 单击封面：4s 内线性压暗，抵达 20% 那一刻恢复 Zen',
      (tester) async {
        await _runPlayerTest(
          tester,
          viewport: const Size(800, 360),
          page: page,
          // 常驻控制带档：左栏是「封面 + 曲名 + 控制带」，标题块挂在 ZenFade 上
          detachedControlsEnabled: false,
          body: (player) async {
            await _longPressArtworkIntoZen(tester);
            expect(kPlayerZenImmersiveActive.value, isTrue, reason: '先进 Zen');
            expect(
              _dim(tester),
              1.0,
              reason: '长按松手那次点按被 _consumeZenPressTap 吞掉，不该已经唤出',
            );

            await tester.tap(find.byType(PlayerCoverSlot).first);
            await tester.pump();
            expect(
              _dim(tester),
              1.0,
              reason: 'periodic 的首个 tick 在 +100ms，唤出这一帧还是满亮度',
            );

            // 4 档：chrome 正在 400ms reverse 展开，压暗同时开始
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(
              _dim(tester),
              closeTo(0.92, 0.001),
              reason: '1 - 0.8 × 4/40',
            );
            expect(
              tester.getSize(_titleZenFade()).height,
              greaterThan(0),
              reason: '压暗只是视觉的，chrome 必须照常占位',
            );
            expect(find.byType(PlayerTitleSlot), findsWidgets);

            // 推到半程（累计 20 档 = 2s）
            for (var i = 4; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(_dim(tester), closeTo(0.6, 0.001), reason: '半程正好剩六成');
            expect(
              kPlayerZenImmersiveActive.value,
              isFalse,
              reason: '中途仍处在唤出态，没提前收回',
            );

            // 最后 20 档：第 40 档既是「抵达 20%」也是「恢复 Zen」，必须同一帧
            for (var i = 20; i < 40; i++) {
              await tester.pump(const Duration(milliseconds: 100));
              if (i == 39) {
                expect(
                  _dim(tester),
                  0.2,
                  reason: '终点钉在 20%，不靠两段定时器对齐（同一 tick 收口）',
                );
                expect(
                  kPlayerZenImmersiveActive.value,
                  isTrue,
                  reason: '抵达 20% 的同一帧恢复 Zen',
                );
              }
            }

            // ZenFade 的 400ms 把 20% 补到 0 并折叠几何
            for (var i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(tester.getSize(_titleZenFade()).height, 0);
            expect(
              find.byType(PlayerTitleSlot),
              findsNothing,
              reason: '到点 Offstage，退出命中树不留拦手势的膜',
            );
            expect(
              _dim(tester),
              0.2,
              reason: '进 Zen 绝不复位因子，否则那 400ms 里 chrome 会从 0.2 闪回满亮度',
            );
          },
        );
      },
    );

    testWidgets('$name 唤出后显式退出 Zen：因子复位，下次唤出是满亮度', (tester) async {
      await _runPlayerTest(
        tester,
        viewport: const Size(800, 360),
        page: page,
        detachedControlsEnabled: false,
        body: (player) async {
          await _longPressArtworkIntoZen(tester);
          await tester.tap(find.byType(PlayerCoverSlot).first);
          // 走完整个斜坡：此时在 Zen 里，因子里留着 0.2
          for (var i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(_dim(tester), 0.2);
          expect(kPlayerZenImmersiveActive.value, isTrue);
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }

          // 长按退出：_exitZenMode 必须把残留因子按回 1.0，且必须在 !_zenMode 守卫之前
          await _longPressArtworkIntoZen(tester);

          expect(kPlayerZenImmersiveActive.value, isFalse, reason: '已退出 Zen');
          expect(
            _dim(tester),
            1.0,
            reason: '残留 0.2 泄到下次唤出，chrome 一出来就是暗的',
          );
          expect(
            tester.getSize(_titleZenFade()).height,
            greaterThan(0),
            reason: 'chrome 重新占位，配合满亮度才是正常唤出',
          );
        },
      );
    });

    // ── 横屏 Zen：封面四边留白对称 ──
    //
    // 两处会各自把封面推离中心，且都是「只折 chrome 本体」时看不出来的：
    // 1. 封面↔曲名的 16、曲名↔传输簇的 12 若留在 ZenFade **外层**，chrome 折成 0 后
    //    这 28px 仍占在封面下方，整列「居中」反而把封面顶上去（实测 16/16/146/174）。
    // 2. 暂停时 AnimatedScale 收到 0.85，锚点若在左下角，**可见**封面就偏到布局盒
    //    左下，左右上下四边留白立刻不等 —— 宽屏标题早已居中，该锚点的前提不成立。
    // 因此这里量的是含暂停缩放的**可见矩形**，四边留白必须两两相等。
    testWidgets('$name 横屏 Zen：封面四边留白对称（含暂停态）', (tester) async {
      for (final viewport in <Size>[
        const Size(800, 360),
        const Size(1280, 800),
      ]) {
        for (final emitPlaying in <bool>[true, false]) {
          await _runPlayerTest(
            tester,
            viewport: viewport,
            page: page,
            emitPlaying: emitPlaying,
            detachedControlsEnabled: false,
            body: (player) async {
              final cover = find.byType(PlayerCoverSlot).first;
              final tag = '$viewport play=$emitPlaying';

              /// 封面布局盒 → 真实屏幕矩形（暂停收到 0.85 时按锚点收）
              Rect visibleCover() {
                final scale = tester.widget<AnimatedScale>(
                  find
                      .descendant(
                        of: cover,
                        matching: find.byType(AnimatedScale),
                      )
                      .first,
                );
                return coverSettledVisualRect(
                  layout: tester.getRect(cover),
                  scale: scale.scale,
                  anchor: scale.alignment,
                );
              }

              void expectLeftRightAligned(String stage) {
                final v = visibleCover();
                final paneRight =
                    tester.getRect(find.byType(PlayerTabPager)).left;
                final left = v.left;
                final right = paneRight - v.right;
                expect(
                  (left - right).abs(),
                  lessThanOrEqualTo(0.5),
                  reason:
                      '$tag $stage：封面可见矩形必须居中于左栏（左 $left / 右 $right）',
                );
              }

              void expectTopBottomAligned(String stage) {
                final v = visibleCover();
                final top = v.top;
                final bottom = viewport.height - v.bottom;
                expect(
                  (top - bottom).abs(),
                  lessThanOrEqualTo(0.5),
                  reason:
                      '$tag $stage：Zen 下 chrome 已折成 0，封面上下留白必须相等'
                          '（上 $top / 下 $bottom）',
                );
              }

              expectLeftRightAligned('常态');
              await _longPressArtworkIntoZen(tester);
              expect(
                kPlayerZenImmersiveActive.value,
                isTrue,
                reason: '$tag 确实进了 Zen',
              );
              expectLeftRightAligned('Zen');
              expectTopBottomAligned('Zen');
            },
          );
        }
      }
    });

    // ── 横屏 Zen：折掉的 chrome 必须还给封面 ──
    //
    // 789ff83b 把宽屏封面从「Flexible 撑满剩余高度」改成「栏内高 − 固定 chrome」，
    // 而那条 chrome 是**常量、不看 Zen**：曲名 / 进度尺 / 播放键已被 `ZenFade` 的
    // SizeTransition 折成 0 高，`bandChrome()` = 16+50+12+60+12+40 = **190dp** 照旧扣掉，
    // 于是「进 Zen 封面不再变大」。800×360 实测（本用例跑出来的数）：
    //   · 折算生效：封面 82 → **288**（撞到栏内宽上限）
    //   · 折算去掉（= 789ff83b 的现状）：82 → **138**，白扣一整条 chrome
    // 平板 1280×800 是宽度受限档，前后差别看不出来，所以只要求「不许变小」。
    // 上面那条「四边留白对称」的用例通不掉这个 bug：封面不长大时它照样居中对称。
    testWidgets('$name 横屏 Zen：折掉的 chrome 补给封面（边长必须变大）', (
      tester,
    ) async {
      for (final viewport in <Size>[
        const Size(800, 360),
        const Size(1280, 800),
      ]) {
        await _runPlayerTest(
          tester,
          viewport: viewport,
          page: page,
          emitPlaying: true,
          detachedControlsEnabled: false,
          body: (player) async {
            final cover = find.byType(PlayerCoverSlot).first;
            final before = tester.getSize(cover);

            await _longPressArtworkIntoZen(tester);
            expect(
              kPlayerZenImmersiveActive.value,
              isTrue,
              reason: '$viewport 确实进了 Zen',
            );

            final after = tester.getSize(cover);
            // 任何情况下都不许被压成非方形（预留不足时旧实现会被 Flexible 压成扁方块）
            expect(
              (after.width - after.height).abs(),
              lessThanOrEqualTo(0.5),
              reason: '$viewport Zen 下封面必须仍是正方形，实测 $after',
            );
            if (viewport == const Size(800, 360)) {
              // 手机横屏是**高度受限**档：Zen 折掉的 chrome 实测 190dp（bandChrome），
              // 让出来的高度要几乎原样还给封面。实测对照：
              //   · 折算生效（现在）：82 → 288（撞到宽度上限）
              //   · 折算去掉（= 789ff83b 的现状）：82 → 138，白扣一整条 chrome
              // 阈值取 150：离两个实测值都有余量（换字体/显示大小不会误报），
              // 又足以钉住回归。
              expect(
                after.width - before.width,
                greaterThanOrEqualTo(150),
                reason: '$viewport 手机横屏 Zen：折掉的整条 chrome 必须补给封面，'
                    '实测 Zen 前 ${before.width} → Zen 后 ${after.width}'
                    '（只涨 ${(after.width - before.width).round()}dp，说明 chrome 还在照扣）',
              );
            } else {
              expect(
                after.width,
                greaterThanOrEqualTo(before.width),
                reason: '$viewport 平板横屏宽度受限，Zen 不该把封面缩小',
              );
            }
          },
        );
      }
    });
  }

  testWidgets('AM 传输按钮线宽 = 已播放进度条的 2 倍（侧键 4px）/ 3 倍（播放键 6px）', (
    tester,
  ) async {
    await _runPlayerTest(
      tester,
      viewport: const Size(1280, 800),
      page: () => const AmStyleFullPlayer(dockMode: false),
      body: (player) async {
        final controls = tester.widget<AMTransportControls>(
          find.byType(AMTransportControls),
        );
        // AM 页进度条是 PlayerSeekBar(md3Style: false) 的 2px 常态轨道（已播放段）；
        // iconic_morph 的 strokeWidth 是 24 基准 viewBox 单位、渲染时按 size/24
        // 缩放（_StaticIconPainter），故屏幕线宽 = strokeWidth × iconSize / 24。
        expect(
          controls.strokeWidth * controls.skipIconSize / 24,
          closeTo(4.0, 0.01),
          reason: '侧键线宽应为已播放进度条（2px）的两倍',
        );
        expect(
          controls.playStrokeWidth * controls.playIconSize / 24,
          closeTo(6.0, 0.01),
          reason: '播放键线宽应为已播放进度条的三倍（保持比侧键更粗）',
        );
      },
    );
  });

  testWidgets('竖屏 + 顶栏页签圆点：底部留白抬到 40dp、关闭态仍是 10dp（开关两态必须区分）', (
    tester,
  ) async {
    const screenH = 800.0;
    for (final (name, page) in <(String, Widget Function())>[
      ('MD3', () => const FullPlayer(dockMode: false)),
      ('AM', () => const AmStyleFullPlayer(dockMode: false)),
    ]) {
      double? onPagerHeight;
      await _runPlayerTest(
        tester,
        viewport: const Size(400, 800),
        page: page,
        tabDotsInTopBar: true,
        body: (player) async {
          final pager = tester.getRect(find.byType(PlayerTabPager));
          final seek = tester.getRect(find.byType(PlayerSeekBar));
          final transport = tester.getRect(
            name == 'MD3'
                ? find.byType(MD3ETransportRow)
                : find.byType(AMTransportControls),
          );
          onPagerHeight = pager.height;

          // 控件区不再有「黄金分割余量」：进度条紧贴内容区下方那笔 8dp 间距。
          // （改造前这里还压着 24dp 空档，进度条因此比现在低 24dp。）
          expect(
            seek.top - pager.bottom,
            closeTo(8, 0.5),
            reason: '$name 进度条必须紧贴内容区（8dp），标题与进度条之间不该有空档',
          );
          // 控件块下边缘 = 屏底 − 导航栏 inset − 设计留白。
          // 开关开启时页签条已升到顶栏、底部没有它，留白取 40（playerBottomDesignInset）；
          // harness 没有设置系统栏 inset，所以这里就是 40。
          expect(
            screenH - transport.bottom,
            closeTo(40, 0.5),
            reason: '$name 开启开关时传输行下边缘距屏底应为「导航栏 + 40dp 设计留白」',
          );
          // 控件区高度 = 内容自然高（各子项实测高之和）—— 多一 dp 都会变成死区
          expect(
            screenH - pager.bottom,
            closeTo(8 + seek.height + 28 + transport.height + 40, 0.5),
            reason: '$name 控件区应恰为内容自然高，剩余高度全部归内容区',
          );
          expect(
            transport.top,
            greaterThan(seek.bottom),
            reason: '$name 进度条与传输行不应重叠',
          );
          expect(
            transport.bottom,
            lessThanOrEqualTo(screenH + 0.5),
            reason: '$name 传输行必须完整落在屏幕内',
          );
        },
      );

      // 关闭开关：页签条回到这一列底部（间隙 10 + 条高 34 = 44），但底部设计留白同时
      // 由 40 降回 10 —— **净额是内容区比开启态少 14dp**。这正是两态必须区分留白的由来：
      // 共用一个值时，要么关闭态页签条悬空 40、要么开启态控件贴底 10。
      await _runPlayerTest(
        tester,
        viewport: const Size(400, 800),
        page: page,
        body: (player) async {
          final pager = tester.getRect(find.byType(PlayerTabPager));
          final seek = tester.getRect(find.byType(PlayerSeekBar));
          final transport = tester.getRect(
            name == 'MD3'
                ? find.byType(MD3ETransportRow)
                : find.byType(AMTransportControls),
          );
          expect(
            pager.height,
            closeTo(onPagerHeight! - 14, 0.5),
            reason: '$name 关闭开关时内容区应少 14dp（页签条 44 回归 − 留白 40→10）',
          );
          expect(
            screenH - transport.bottom,
            closeTo(54, 0.5),
            reason: '$name 关闭开关时传输行应被页签条顶到「导航栏 + 10 + 条高 34 + 间隙 10」',
          );
          expect(
            seek.top - pager.bottom,
            closeTo(8, 0.5),
            reason: '$name 关闭开关时进度条同样紧贴内容区',
          );
        },
      );
    }
  });
}
