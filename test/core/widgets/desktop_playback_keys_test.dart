// 桌面方向键播放控制层（`core/widgets/desktop_playback_keys.dart`）的键位契约测试。
//
// ## 为什么钉子必须打在 widget 层
//
// 本层的正确性 **100% 取决于挂载位置**：裸方向键在框架里已被
// `WidgetsApp.defaultShortcuts` 绑成 `DirectionalFocusIntent`（焦点遍历），而那个
// `Shortcuts` 包着 `MaterialApp.builder` 的产物。挂在 builder 之外（`DesktopInputLayer`
// 的位置）就永远收不到；挂在 builder 之内才能先拿到按键。纯代码审查看不出这个差别
// —— 只有把宿主按 `app.dart` 的真实层级搭出来（probe → 本层 → MaterialApp），才能
// 同时钉住「先于默认遍历」和「放行后仍能冒泡到更外层」。
//
// 断言口径：
// - 「本层消费」：玩家侧调用有变化，且**外层探针收不到该键**；
// - 「本层放行」：外层探针收到该键（探针在 `Shortcuts` 之内、本层之上，
//   所以它收到 = 本层返回了 ignored，与随后框架怎么处理无关）；
// - 「页内控件优先」：页内 `Focus` 记到按键、玩家侧一次都没被调。
//
// 每个平台敏感用例都带 `TargetPlatformVariant.only(TargetPlatform.windows)`：
// 本层门控是 `isWindowsDesktop`（`defaultTargetPlatform` 口径），测试默认平台是
// android，不加 variant 时整层是直通的。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/widgets/desktop_playback_keys.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/player_video_active.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/controlled_audio_service.dart';

/// 只在 Windows 平台跑（本层的生效条件）；group 不支持 variant，逐用例挂。
final TargetPlatformVariant _windows =
    TargetPlatformVariant.only(TargetPlatform.windows);

/// 记录调用的播放器替身：键位语义只关心「有没有被调到、调到了多少」。
class _FakePlayer extends PlayerProvider {
  _FakePlayer() : super();

  static const Song _song = Song(
    id: 'k',
    title: '方向键测试曲',
    artist: '歌手',
    album: '专辑',
    duration: Duration(seconds: 120),
    isOnline: true,
    url: 'https://audio.invalid/k.mp3',
  );

  Song? song = _song;
  Duration? durationValue = const Duration(seconds: 120);
  Duration positionValue = const Duration(seconds: 30);
  double volumeValue = 0.5;

  int volumeCalls = 0;
  int seekCalls = 0;
  Duration? lastSeek;
  bool lastForceNotify = false;

  @override
  Song? get currentSong => song;
  @override
  bool get isPlaying => true;
  @override
  Duration? get duration => durationValue;
  @override
  Duration get position => positionValue;
  @override
  double get volume => volumeValue;

  @override
  Future<void> setVolume(double volume, {bool persist = true}) async {
    volumeCalls++;
    volumeValue = volume;
  }

  @override
  Future<void> seek(Duration position, {bool forceNotify = false}) async {
    seekCalls++;
    lastSeek = position;
    lastForceNotify = forceNotify;
    // 真实现里 seek 会先同步更新位置（见 PlayerProvider.seek），连按才能累加。
    positionValue = position;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlayer player;
  /// 冒泡穿过本层、到达 `Shortcuts` 之内探针的按键（= 本层放行）。
  late List<LogicalKeyboardKey> escaped;
  late List<String> toasts;

  const MethodChannel toastChannel = MethodChannel('md3music/desktop_message');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioServiceLoader.setTestOverride(() async => ControlledAudioService());
    player = _FakePlayer();
    escaped = <LogicalKeyboardKey>[];
    toasts = <String>[];
    DesktopPlaybackKeys.resetFeedbackThrottle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(toastChannel, (call) async {
          final args = call.arguments;
          if (args is Map && args['message'] is String) {
            toasts.add(args['message'] as String);
          }
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(toastChannel, null);
    player.dispose();
    AudioServiceLoader.setTestOverride(null);
    while (kVideoPlaybackActive.value) {
      exitVideoPlayback();
    }
  });

  /// 被测宿主：`MaterialApp.builder` → 探针 → DesktopPlaybackKeys → Navigator。
  /// 与 `app.dart::_MAppView.build` 的挂载位置一致（本层在 builder 之内）。
  Widget host(Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ChangeNotifierProvider(create: (_) => CarModeProvider()),
    ],
    child: MaterialApp(
      builder: (context, child) => Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) escaped.add(event.logicalKey);
          return KeyEventResult.ignored;
        },
        child: DesktopPlaybackKeys(child: child!),
      ),
      home: home,
    ),
  );

  Future<void> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(host(home));
    await tester.pumpAndSettle();
  }

  /// 发一次按键并放行一次微任务（Toast 走异步 MethodChannel）。
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  testWidgets('↑/↓ 逐击 ±5%：夹取 0..1，到边界仍消费', (tester) async {
    await pump(tester, const Placeholder());

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(player.volume, closeTo(0.55, 1e-9), reason: '↑ 一次 = +5%');
    expect(player.volumeCalls, 1);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(player.volume, closeTo(0.5, 1e-9), reason: '↓ 一次 = -5%');

    // 上边界：100% 再按 ↑ 不越界，但仍算「已消费」（否则按键开始乱跳焦点）。
    player.volumeValue = 1.0;
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(player.volume, 1.0);
    expect(
      player.volumeCalls,
      2,
      reason: '目标值没变时不得重复下发（也就不会重复写盘）',
    );

    // 下边界同上。
    player.volumeValue = 0.0;
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(player.volume, 0.0);
    expect(player.volumeCalls, 2);

    expect(escaped, isEmpty, reason: '本层已消费，不得再外抛');
  }, variant: _windows);

  testWidgets('←/→ 逐击 ∓/±5 秒：夹取 [0, duration]，并要求房间感知', (tester) async {
    await pump(tester, const Placeholder());

    player.positionValue = const Duration(seconds: 30);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(player.lastSeek, const Duration(seconds: 35));
    expect(player.lastForceNotify, isTrue, reason: '键盘 seek 属于用户显式操作');

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(player.lastSeek, const Duration(seconds: 30));

    player.positionValue = const Duration(seconds: 2);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(player.lastSeek, Duration.zero, reason: '不得退到负时间');

    player.positionValue = const Duration(seconds: 118);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(
      player.lastSeek,
      const Duration(seconds: 120),
      reason: '不得越过曲目时长',
    );
    expect(escaped, isEmpty);
  }, variant: _windows);

  testWidgets('无歌 / 时长未知：方向键不吞，交回框架', (tester) async {
    await pump(tester, const Placeholder());

    player.durationValue = null;
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(player.seekCalls, 0);
    expect(
      escaped,
      contains(LogicalKeyboardKey.arrowRight),
      reason: '时长未知的轨道不该吃掉方向键',
    );

    player.durationValue = const Duration(seconds: 120);
    player.song = null;
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(player.volumeCalls, 0);
    expect(escaped, contains(LogicalKeyboardKey.arrowUp));
  }, variant: _windows);

  testWidgets('文本输入聚焦：方向键让位给光标移动', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(
      tester,
      Scaffold(body: Center(child: TextField(controller: controller))),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowLeft);

    expect(player.volumeCalls, 0, reason: '输入框里 ↑ 不能变成调音量');
    expect(player.seekCalls, 0, reason: '输入框里 ← 不能变成快退');
    expect(
      escaped,
      containsAll(<LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
      ]),
      reason: '必须原样放行给 DefaultTextEditingShortcuts',
    );
  }, variant: _windows);

  testWidgets('带修饰键一律放行：Ctrl+←/→ 仍归外层切歌', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(player.volumeCalls, 0);
    expect(player.seekCalls, 0);
    expect(
      escaped,
      containsAll(<LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown,
      ]),
    );
  }, variant: _windows);

  testWidgets('按住不放只走一步（KeyRepeat 不连发）', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(
      player.volumeCalls,
      1,
      reason: '连发会把音量几帧内拉满，只认首个 KeyDownEvent',
    );
  }, variant: _windows);

  testWidgets('页内自带方向键语义的控件优先（滑块/排序字段类）', (tester) async {
    var innerHits = 0;
    final inner = FocusNode(debugLabel: 'page/inner-arrow-consumer');
    addTearDown(inner.dispose);
    await pump(
      tester,
      Scaffold(
        body: Focus(
          focusNode: inner,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.arrowUp) {
              innerHits++;
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    inner.requestFocus();
    await tester.pump();

    await press(tester, LogicalKeyboardKey.arrowUp);

    expect(innerHits, 1, reason: '更靠近焦点的控件必须先拿到按键');
    expect(player.volumeCalls, 0, reason: '本层不得抢页内控件的方向键');
  }, variant: _windows);

  testWidgets('视频页在前台时让行（MV 期间不动背景音频进度）', (tester) async {
    enterVideoPlayback();
    await pump(tester, const Placeholder());

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowUp);

    expect(player.seekCalls, 0);
    expect(player.volumeCalls, 0);
    expect(
      escaped,
      containsAll(<LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
      ]),
    );
  }, variant: _windows);

  testWidgets('音量提示走原生 Toast（节流后不逐击弹）', (tester) async {
    await pump(tester, const Placeholder());

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(toasts, ['音量 55%']);

    // 400ms 窗口内连按不重复弹；窗口外再弹。
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(toasts.length, 1, reason: '连按不该每击弹一次原生提示');
    DesktopPlaybackKeys.resetFeedbackThrottle();
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(toasts, ['音量 55%', '音量 65%']);
  }, variant: _windows);

  testWidgets('非 Windows 平台原样透传：不装方向键拦截', (tester) async {
    await pump(tester, const Placeholder());

    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(player.volumeCalls, 0, reason: 'Android / TV 不得被桌面方向键影响');
    expect(player.seekCalls, 0);
    expect(
      escaped,
      containsAll(<LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]),
    );
  });

  testWidgets('空焦点兜底：持焦控件在后台被销毁后，方向键仍生效', (tester) async {
    // 组合链路钉子：兜底（`EmptyFocusFallback`）必须挂在**本层之内**。
    // 若有人把它挪到本层外面，这条会挂 —— 那时焦点落在兜底节点上，冒泡链只经过
    // 它的祖先，方向键直接到不了 `DesktopPlaybackKeys`（空格 / Esc 却仍正常）。
    final node = FocusNode(debugLabel: 'page/button');
    addTearDown(node.dispose);
    var show = true;
    late StateSetter setShow;
    await pump(
      tester,
      Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            setShow = setState;
            return show
                ? Focus(
                    focusNode: node,
                    onKeyEvent: (_, _) => KeyEventResult.ignored,
                    child: const SizedBox.expand(),
                  )
                : const SizedBox.expand();
          },
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(node));

    // 后台 → 后台期间销毁持焦控件（`_suspendedNode` 被顺手清掉）→ 回前台：
    // 无人可还原，焦点永久停在 rootScope（空焦点）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    setShow(() => show = false);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pump();
    // 空焦点此刻已被兜底接管（对照组见 `empty_focus_fallback_test.dart`：
    // 同一序列在不挂兜底时 primaryFocus.context 为 null、按键被框架丢弃）。
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'desktop/empty-focus-fallback',
      reason: '前提：兜底已接管空焦点',
    );

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(
      player.volume,
      closeTo(0.55, 1e-9),
      reason: '空焦点被兜底接管后，←→/↑↓ 必须继续生效，而不是整层哑掉',
    );
  }, variant: _windows);

  group('纯逻辑（不依赖平台）', () {
    test('steppedVolume：步进与夹取', () {
      expect(DesktopPlaybackKeys.steppedVolume(0.5, up: true), closeTo(0.55, 1e-9));
      expect(DesktopPlaybackKeys.steppedVolume(0.5, up: false), closeTo(0.45, 1e-9));
      expect(DesktopPlaybackKeys.steppedVolume(1.0, up: true), 1.0);
      expect(DesktopPlaybackKeys.steppedVolume(0.0, up: false), 0.0);
      expect(DesktopPlaybackKeys.steppedVolume(1.02, up: true), 1.0);
    });

    test('steppedPosition：步进与夹取', () {
      const duration = Duration(seconds: 100);
      expect(
        DesktopPlaybackKeys.steppedPosition(
          const Duration(seconds: 30),
          duration: duration,
          forward: true,
        ),
        const Duration(seconds: 35),
      );
      expect(
        DesktopPlaybackKeys.steppedPosition(
          const Duration(seconds: 3),
          duration: duration,
          forward: false,
        ),
        Duration.zero,
      );
      expect(
        DesktopPlaybackKeys.steppedPosition(
          const Duration(seconds: 98),
          duration: duration,
          forward: true,
        ),
        duration,
      );
    });

    test('formatPosition：mm:ss', () {
      expect(DesktopPlaybackKeys.formatPosition(Duration.zero), '0:00');
      expect(
        DesktopPlaybackKeys.formatPosition(const Duration(minutes: 1, seconds: 5)),
        '1:05',
      );
      expect(
        DesktopPlaybackKeys.formatPosition(const Duration(minutes: 75, seconds: 9)),
        '75:09',
      );
      expect(
        DesktopPlaybackKeys.formatPosition(const Duration(seconds: -3)),
        '0:00',
      );
    });

    test('视频页引用计数：末个离开才清标志', () {
      enterVideoPlayback();
      enterVideoPlayback();
      exitVideoPlayback();
      expect(
        kVideoPlaybackActive.value,
        isTrue,
        reason: '退出动画期间新旧视频页可能并存，先走的那一个不能提前解锁方向键',
      );
      exitVideoPlayback();
      expect(kVideoPlaybackActive.value, isFalse);
    });
  });

  group('挂载位置（源码结构断言）', () {
    test('DesktopPlaybackKeys 必须在 MaterialApp.builder 之内', () {
      // 这条断言的实质：裸方向键会被 `WidgetsApp.defaultShortcuts` 的
      // `DirectionalFocusIntent` 先吃掉，而那个 `Shortcuts` 包着 builder 的产物。
      // 一旦有人把本层挪到 `MaterialApp` 之外（和 DesktopInputLayer 放一起），
      // 编译期与普通 widget 测试都不会报错，但真机上方向键整层失灵。
      final String source = File('lib/app.dart').readAsStringSync();
      final int appIndex = source.indexOf('MaterialApp(');
      final int layerIndex = source.indexOf('DesktopPlaybackKeys(');
      final int navigatorKeyIndex = source.indexOf('navigatorKey: appNavigatorKey');

      expect(appIndex, greaterThanOrEqualTo(0));
      expect(layerIndex, greaterThan(appIndex), reason: '本层必须在 MaterialApp 之内');
      expect(
        layerIndex,
        lessThan(navigatorKeyIndex),
        reason: '本层必须在 builder 里挂着（builder 在 navigatorKey 之前）',
      );
    });
  });
}
