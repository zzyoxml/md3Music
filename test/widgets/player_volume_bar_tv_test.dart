// PlayerVolumeBar 的 TV 接线约定与触屏回归（AGENTS §12.4）。
//
// 两件事分开钉：
// 1. **TV 接线不参与手机包**：`kTvBuild` 在普通构建是 `const false`，
//    `if (kTvBuild) return DpadFocusable(...)` 整段被 AOT 树摇剔除，普通
//    `flutter test` 的树上根本不该出现 DpadFocusable（与
//    test/widgets/player_seek_bar_tv_test.dart、
//    test/core/remote/tv_scroll_region_test.dart 同一约定）。方向键的步进/夹取
//    判断在 TvVolumeStepper 里，由 test/core/remote/tv_volume_stepper_test.dart 钉。
// 2. **触屏行为零变化**：音量行是「喇叭键切静音 + 轨道横拖」，改动只是把这一行
//    再包一层焦点停点，拖动/点按/取消的时序与落点必须和改动前一致。
//
// harness 参照 test/widgets/playback_status_feedback_test.dart 的受控音频注入
// （ControlledAudioService + AudioServiceLoader），只挂 PlayerProvider：
// PlayerVolumeBar 的三态判据另外读 OutputModeCoordinator / UsbAudioService 两个
// 单例，两者都是惰性构造、建流时不碰 MethodChannel，默认可用。

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/player_volume_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

Widget _host(PlayerProvider player) {
  return ChangeNotifierProvider<PlayerProvider>.value(
    value: player,
    child: MaterialApp(
      home: Scaffold(
        // 定宽挂载：轨道用 Expanded 吃满剩余宽度，宽度固定才能把拖动距离换算成比例
        body: Center(
          child: SizedBox(
            width: 300,
            child: const PlayerVolumeBar(amStyle: false),
          ),
        ),
      ),
    ),
  );
}

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
  // 拖动起手会发一次 slider 触觉（AppHaptics.tick）：不 mock 这两条通道时，
  // _fire 的 300ms watchdog 会带着「Timer 仍在挂起」把测试判成失败。
  // 原生返回 true = 震动成功，watchdog 当场取消，与真机一致。
  messenger.setMockMethodCallHandler(
    services.SystemChannels.platform,
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('md3music/haptics'),
    (_) async => true,
  );
}

/// 轨道当前的展示值（`PlayerVolumeTrackBar.value`）。
///
/// 直接读 widget 而不是截图/语义：值展示走本地 `_display` ValueNotifier，
/// 读它就是读「画面此刻的音量」，也是「外部回写有没有被 `_dragging` 闸门挡住」
/// 的判据。
double _trackValue(WidgetTester tester) =>
    tester.widget<PlayerVolumeTrackBar>(find.byType(PlayerVolumeTrackBar)).value;

Future<void> _withPlayer(
  WidgetTester tester,
  Future<void> Function(PlayerProvider player, ControlledAudioService audio) body,
) async {
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  late final PlayerProvider player;
  try {
    await tester.runAsync(() async {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
    });
    await tester.pumpWidget(_host(player));
    await tester.pump();
    return await body(player, audio);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TV 接线不进入手机包', () {
    testWidgets('普通构建（kTvBuild=false）树里没有 DpadFocusable', (tester) async {
      await _withPlayer(tester, (player, audio) async {
        expect(find.byType(PlayerVolumeBar), findsOneWidget);
        // 钉住「音量行的 TV 接线不参与手机包构建」这条约定
        expect(find.byType(DpadFocusable), findsNothing);
      });
    });

    testWidgets('普通构建下音量行仍是纯手势控件（没被包进焦点停点）', (
      tester,
    ) async {
      await _withPlayer(tester, (player, audio) async {
        expect(
          find.ancestor(
            of: find.descendant(
              of: find.byType(PlayerVolumeTrackBar),
              matching: find.byType(GestureDetector),
            ),
            matching: find.byType(DpadFocusable),
          ),
          findsNothing,
        );
      });
    });
  });

  group('触屏回归', () {
    testWidgets('横拖轨道：展示值跟手，松手落定到播放器音量', (tester) async {
      await _withPlayer(tester, (player, audio) async {
        final Rect rect = tester.getRect(find.byType(PlayerVolumeTrackBar));
        final gesture = await tester.startGesture(
          Offset(rect.left + 5, rect.center.dy),
        );
        await tester.pump();
        await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
        await tester.pump();

        expect(
          _trackValue(tester),
          closeTo(0.5, 0.06),
          reason: '拖到轨道中点，画面就该是 50%',
        );

        await gesture.up();
        await tester.pump();
        expect(
          player.volume,
          closeTo(_trackValue(tester), 1e-6),
          reason: '松手写盘，播放器与画面必须对齐',
        );
      });
    });

    testWidgets('拖动被取消后，外部音量变化仍能回写画面（_dragging 闸门已复位）', (
      tester,
    ) async {
      await _withPlayer(tester, (player, audio) async {
        final Rect rect = tester.getRect(find.byType(PlayerVolumeTrackBar));
        final gesture = await tester.startGesture(
          Offset(rect.right - 5, rect.center.dy),
        );
        await tester.pump();
        // 拖出 slop，让 onDragStart/onDrag 真正跑起来（_dragging 置位）
        await gesture.moveTo(Offset(rect.right - 80, rect.center.dy));
        await tester.pump();
        expect(_trackValue(tester), greaterThan(0.3));
        // 取消（被系统手势抢走等）：父层的 _dragging 只在这里复位，
        // 漏掉就让滑条从此不反映系统/独占音量变化
        await gesture.cancel();
        await tester.pump();

        await tester.runAsync(() => player.setVolume(0.42));
        await tester.pump();

        expect(_trackValue(tester), closeTo(0.42, 1e-6));
      });
    });

    testWidgets('点喇叭键切静音，再点恢复上一个非零音量', (tester) async {
      await _withPlayer(tester, (player, audio) async {
        await tester.runAsync(() => player.setVolume(0.8));
        await tester.pump();

        await tester.tap(find.byIcon(Icons.volume_down));
        await tester.pump();
        expect(find.byIcon(Icons.volume_off), findsOneWidget);
        expect(_trackValue(tester), 0.0);
        expect(player.volume, 0.0);

        await tester.tap(find.byIcon(Icons.volume_off));
        await tester.pump();
        expect(
          _trackValue(tester),
          closeTo(0.8, 1e-6),
          reason: '恢复的是静音前那个非零值，不是固定 100%',
        );
      });
    });
  });
}
