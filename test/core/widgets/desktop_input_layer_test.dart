// 桌面键鼠快捷键的**键位契约**测试（Windows 端）。
//
// 为什么必须钉在 widget 层：本层的正确性全来自「谁先消费按键」这个顺序问题。
// 按键从 primaryFocus 向外冒泡，第一个返回非 ignored 的节点赢：
// - 框架 app 级 `Shortcuts` 把 space 绑到 ActivateIntent（激活聚焦按钮）、
//   escape 绑到 DismissIntent（关 barrierDismissible 的弹层）；
// - `DefaultTextEditingShortcuts` 在文本框聚焦时把 space 交给 IME
//   （DoNothingAction(consumesKey:false) → skipRemainingHandlers）。
// 这两层都在 MaterialApp **之内**，所以本层必须挂在 MaterialApp **之外**才能让
// 它们先赢。一旦有人把本层挪回页面内部（旧 DesktopShell 的做法），
// 「桌面布局开着时搜索框打不出空格」的老缺陷立刻复现 —— 纯代码审查看不出来。
//
// 断言口径：
// - 「本层放行」用**最外层 Focus 探针**证明（只有冒泡穿过本层才收得到）；
// - 「本层没抢文本框的空格」用 `pauseCalls == 0` 证明 —— 那种情况下空格在文本层
//   就被截停，探针同样收不到，所以探针不能当唯一判据。
//
// 每个用例都带 `variant: TargetPlatformVariant.only(TargetPlatform.windows)`：
// `defaultTargetPlatform` 在测试里默认是 android，不加 variant 时本层根本不生效
// （group 不支持 variant，只能逐个加）。
//
// PlayerProvider 用子类覆写（currentSong/isPlaying/pause/resume/next/previous）：
// 真实播放链路要 just_audio 平台实现，与键位无关；构造期仍会跑 _initAudioService，
// 所以要注入 AudioServiceLoader 桩。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/widgets/desktop_input_layer.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/main.dart' show appNavigatorKey;
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/controlled_audio_service.dart';

/// 只在 Windows 平台跑（本层的生效条件）；group 不支持 variant，逐用例挂。
final TargetPlatformVariant _windows =
    TargetPlatformVariant.only(TargetPlatform.windows);

/// 记录调用次数的播放器替身（键位测试只关心「有没有被调到」）。
class _FakePlayer extends PlayerProvider {
  _FakePlayer() : super();

  static const Song _song = Song(
    id: 'k',
    title: '键位测试曲',
    artist: '歌手',
    album: '专辑',
    duration: Duration(seconds: 60),
    isOnline: true,
    url: 'https://audio.invalid/k.mp3',
  );

  Song? song = _song;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  bool _playing = true;

  @override
  Song? get currentSong => song;
  @override
  bool get isPlaying => _playing;
  @override
  Future<void> pause({bool notifyRoom = true}) async {
    pauseCalls++;
    _playing = false;
  }

  @override
  Future<void> resume({bool notifyRoom = true}) async {
    resumeCalls++;
    _playing = true;
  }

  @override
  Future<void> next({bool autoPlay = true}) async => nextCalls++;
  @override
  Future<void> previous({bool autoPlay = true}) async => previousCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlayer player;
  /// 冒泡穿过本层、到达最外层探针的按键（= 本层放行）。
  late List<LogicalKeyboardKey> escaped;
  late int backHits;
  late int forwardHits;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioServiceLoader.setTestOverride(() async => ControlledAudioService());
    player = _FakePlayer();
    escaped = <LogicalKeyboardKey>[];
    backHits = 0;
    forwardHits = 0;
    DesktopInputRouter.backHandler = () async {
      backHits++;
      return true;
    };
    DesktopInputRouter.forwardHandler = () {
      forwardHits++;
      return true;
    };
  });

  tearDown(() {
    DesktopInputRouter.backHandler = null;
    DesktopInputRouter.forwardHandler = null;
    // 未清理的播放页路由会带着根 Navigator 引用活到下一个用例。
    final DraggablePlayerRoute<dynamic>? route = activePlayerRoute;
    if (route != null) route.navigator?.removeRoute(route);
    activePlayerRoute = null;
    playerExpansion.value = 0.0;
    player.dispose();
    AudioServiceLoader.setTestOverride(null);
  });

  /// 被测宿主：外层 Focus 探针 → DesktopInputLayer → MaterialApp。
  /// 与 app.dart 的挂载位置一致（本层在 MaterialApp 之外、MultiProvider 之内）。
  Widget host(Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ChangeNotifierProvider(create: (_) => CarModeProvider()),
    ],
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) escaped.add(event.logicalKey);
        return KeyEventResult.ignored;
      },
      child: DesktopInputLayer(
        child: MaterialApp(navigatorKey: appNavigatorKey, home: home),
      ),
    ),
  );

  Future<void> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(host(home));
    await tester.pumpAndSettle();
  }

  /// 侧键按下 + 松开成一对（引擎对一次侧键动作发 down/up 两次）。
  Future<void> sideButton(WidgetTester tester, int buttonBit) async {
    final gesture = await tester.startGesture(
      const Offset(20, 20),
      kind: PointerDeviceKind.mouse,
      buttons: buttonBit,
    );
    await gesture.up();
    await tester.pump();
  }

  testWidgets('空格切换播放/暂停：播放中→暂停，暂停中→继续', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.pauseCalls, 1, reason: '播放中按空格必须暂停');
    expect(player.isPlaying, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.resumeCalls, 1, reason: '暂停中按空格必须继续');
    expect(player.isPlaying, isTrue);

    expect(escaped, isEmpty, reason: '本层已消费，不得再外抛');
  }, variant: _windows);

  testWidgets('无正在播放歌曲时空格放行（不吞键）', (tester) async {
    player.song = null;
    await pump(tester, const Placeholder());

    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(player.pauseCalls, 0);
    expect(
      escaped,
      contains(LogicalKeyboardKey.space),
      reason: '没歌可切时必须放行给外层，否则用户在别处的空格被无声吃掉',
    );
  }, variant: _windows);

  testWidgets('聚焦按钮上按空格优先激活按钮，不切播放', (tester) async {
    var activated = 0;
    final buttonFocus = FocusNode();
    addTearDown(buttonFocus.dispose);
    await pump(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(
            focusNode: buttonFocus,
            onPressed: () => activated++,
            child: const Text('go'),
          ),
        ),
      ),
    );
    buttonFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    // 这就是「Windows 端键盘能控制按钮」不被新快捷键破坏的钉子：框架的
    // space→ActivateIntent 在更内层且终止冒泡，本层收不到。
    expect(activated, 1);
    expect(player.pauseCalls, 0);
    expect(player.resumeCalls, 0);
    expect(escaped, isEmpty);
  }, variant: _windows);

  testWidgets('文本框聚焦：空格不被抢，裸字母 F 放行', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(
      tester,
      Scaffold(body: Center(child: TextField(controller: controller))),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);

    // 空格：文本层的保护比本层更靠内，会终止冒泡 —— 本层必须一次都不命中。
    expect(player.pauseCalls, 0, reason: '桌面布局下搜索框要能打出空格');
    // 裸字母 F：本层放行（返回 handled 会让引擎丢掉对应 WM_CHAR，见
    // keyboard_manager.cc），否则搜索框打不出字母 f。
    expect(activePlayerRoute, isNull, reason: '输入中按 F 不能打开播放页');
    expect(escaped, contains(LogicalKeyboardKey.keyF), reason: 'F 必须原样放行给 IME');
  }, variant: _windows);

  testWidgets('F 打开完整播放页，连按不产生第二个实例', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(activePlayerRoute, isNotNull, reason: 'F 必须 push 播放页路由');
    final DraggablePlayerRoute<dynamic>? first = activePlayerRoute;

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(
      identical(activePlayerRoute, first),
      isTrue,
      reason: 'openFullPlayer 统一防重复入栈：不得并存两个播放页实例'
          '（各自驱动歌词动画会让整页帧率翻倍）',
    );
    // 不 pumpAndSettle：本 harness 不铺 FullPlayer 的全套依赖，tearDown 移除路由。
  }, variant: _windows);

  testWidgets('Esc 交给宿主返回链路', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    expect(backHits, 1, reason: '宿主已注册时必须走宿主链路');
    expect(escaped, isEmpty);
  }, variant: _windows);

  testWidgets('宿主未注册时 Esc 回落根 Navigator', (tester) async {
    DesktopInputRouter.backHandler = null;
    await pump(tester, const Placeholder());
    final nav = appNavigatorKey.currentState!;
    nav.push(MaterialPageRoute<void>(builder: (_) => const Placeholder()));
    await tester.pumpAndSettle();
    expect(nav.canPop(), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(nav.canPop(), isFalse, reason: '未注册宿主时 Esc 应弹掉栈顶页');
  }, variant: _windows);

  testWidgets('对话框在场时 Esc 由框架先消费，不走宿主链路', (tester) async {
    await pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(content: Text('dlg')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('dlg'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 框架给每个 ModalRoute 挂了 DismissAction（barrierDismissible 才 enabled），
    // 它在更内层先赢 —— 这条钉子保证「Esc 只关弹层」不被本层抢走。
    expect(find.text('dlg'), findsNothing);
    expect(backHits, 0);
  }, variant: _windows);

  testWidgets('鼠标侧键：后退走宿主、前进走 forwardHandler', (tester) async {
    await pump(tester, const Placeholder());

    await sideButton(tester, kBackMouseButton);
    expect(backHits, 1, reason: 'XBUTTON1 必须走返回链路');
    await sideButton(tester, kForwardMouseButton);
    expect(forwardHits, 1, reason: 'XBUTTON2 必须走前进链路');

    // 左键绝不能触发导航（否则会污染所有普通点击）。
    await sideButton(tester, kPrimaryButton);
    expect(backHits, 1);
    expect(forwardHits, 1);
  }, variant: _windows);

  testWidgets('Ctrl+←/→ 切歌，Alt+←/→ 后退/前进', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(player.nextCalls, 1);
    expect(player.previousCalls, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(forwardHits, 1, reason: 'Alt+→ 与侧键前进同一语义');
  }, variant: _windows);

  testWidgets('媒体键：播放暂停与上下曲', (tester) async {
    await pump(tester, const Placeholder());

    // platform 伪装成 android：flutter_test 的 windows keyCode 表里没有媒体键
    // （`_getKeyCode` 会断言失败），android 表里有。媒体键在真实 Windows 上主要
    // 经 SMTC 通道进来（见 windows/runner/media_controls.cpp），这里的按键路径
    // 只是兜底覆盖，逻辑键一致即可。
    Future<void> press(LogicalKeyboardKey key) =>
        tester.sendKeyEvent(key, platform: 'android');

    await press(LogicalKeyboardKey.mediaPlayPause);
    expect(player.pauseCalls, 1);
    await press(LogicalKeyboardKey.mediaTrackNext);
    expect(player.nextCalls, 1);
    await press(LogicalKeyboardKey.mediaTrackPrevious);
    expect(player.previousCalls, 1);
  }, variant: _windows);

  testWidgets('按住不放只响应首个按下（KeyRepeat 不连发）', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

    expect(
      player.pauseCalls,
      1,
      reason: '连发会把播放态来回抖，只认首个 KeyDownEvent',
    );
  }, variant: _windows);

  testWidgets('带 Shift 的空格不误判为快捷键（留给框架）', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(player.pauseCalls, 0, reason: '带 Shift 的组合不属于「播放/暂停」');
    expect(escaped, contains(LogicalKeyboardKey.space));
  }, variant: _windows);

  testWidgets('Android 平台原样透传：不装键盘与侧键拦截', (tester) async {
    await pump(tester, const Placeholder());

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await sideButton(tester, kBackMouseButton);

    expect(player.pauseCalls, 0, reason: 'Android/TV 不得被桌面键位影响');
    expect(activePlayerRoute, isNull);
    expect(backHits, 0);
    expect(
      escaped,
      containsAll(<LogicalKeyboardKey>[
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.escape,
      ]),
      reason: '本层原样返回 child，全部键位留给外层与框架',
    );
  });
}
