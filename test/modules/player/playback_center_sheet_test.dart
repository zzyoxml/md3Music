// 「播放与输出」面板：两页签 + 音量 + 系统输出入口 / Windows 内联输出设备 + 底部音质。
//
// 钉住的五件事：① 默认落在「输出」页且音量条在场；② 切到「投屏」页换成
// DlnaCastView；③ 音质区在底部、点了就下发且面板不关；④ 面板里**没有**
// 蓝牙设置入口（用户明确不要），系统能力不支持时「更多设备」整行隐藏；
// ⑤ Windows 内联设备区只在 windowsDevices 形态出现，点选即切且当前项带 check。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/windows_audio_output_device_service.dart';
import 'package:md3music/modules/player/audio_quality_dialog.dart';
import 'package:md3music/modules/player/dlna_cast_sheet.dart';
import 'package:md3music/modules/player/playback_center_sheet.dart';
import 'package:md3music/providers/dlna_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/player_volume_bar.dart';
import 'package:md3music/widgets/player_volume_slider.dart';

/// 只把 SSDP 搜索换成空实现：单测没有局域网，验的是布局不是发现协议。
class _QuietDlnaProvider extends DlnaProvider {
  @override
  Future<void> startSearch() async {}
}

/// M3EToggleButtonGroup 的每个 action 在树里出现**两次**（组件自己留了一份用于
/// 计宽/溢出裁切），所以文案型断言只取第一份，不去数个数。
Finder _firstText(String label) => find.text(label).first;

/// 音质档位限定在音质区里找：面板右侧的「当前档」提示用的是同一个短标签。
Finder _qualityChip(String label) => find
    .descendant(
      of: find.byType(PlaybackQualitySection),
      matching: find.text(label),
    )
    .first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PlayerProvider player;
  late _QuietDlnaProvider dlna;
  late int switcherCalls;

  /// 捕获 toast 文案：`showToast` 在非 Windows 目标平台走 fluttertoast，
  /// 测试里 defaultTargetPlatform 默认 android，挂 fluttertoast 通道即可。
  late List<String> toasts;

  Future<void> pump(
    WidgetTester tester, {
    bool supported = true,
    bool switcherShown = true,
    bool? windowsDevices,
    List<WindowsAudioOutputDevice> devices = const [],
    String? selectedId,
    bool selectThrows = false,
    bool? showUsbExclusive,
    UsbExclusiveTrayRow? usbRow,
  }) async {
    SharedPreferences.setMockInitialValues({});
    toasts = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('PonnamKarthik/fluttertoast'),
      (MethodCall call) async {
        if (call.method == 'showToast') {
          toasts.add(
            (call.arguments as Map<Object?, Object?>?)?['msg'] as String? ?? '',
          );
        }
        return true;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('PonnamKarthik/fluttertoast'),
        null,
      );
    });
    player = PlayerProvider();
    dlna = _QuietDlnaProvider();
    switcherCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<DlnaProvider>.value(value: dlna),
          ],
          child: Scaffold(
            body: PlaybackCenterSheet(
              probeSwitcherSupported: () async => supported,
              showSystemSwitcher: () async {
                switcherCalls += 1;
                return switcherShown;
              },
              showWindowsOutputDevices: windowsDevices,
              showUsbExclusive: showUsbExclusive,
              listOutputDevices: () async => devices,
              selectedOutputDeviceId: () async => selectedId,
              selectOutputDevice: (id) async {
                if (selectThrows) throw Exception('native down');
                selectedId = id;
              },
              usbExclusiveRow: usbRow,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认在「输出」页：音量滑杆 + 更多设备，且不再显示设备名', (tester) async {
    await pump(tester);
    expect(find.text('播放与输出'), findsOneWidget);
    // 音量用 m3e_core 的滑杆（不是自绘的细轨道条）
    expect(find.byType(PlayerVolumeSlider), findsOneWidget);
    expect(find.byType(M3ESlider), findsOneWidget);
    expect(find.byType(PlayerVolumeBar), findsNothing);
    // "当前输出设备名"整体下掉：卡片里只有「音量」标题
    expect(find.text('本机'), findsNothing);
    expect(find.text('音量'), findsOneWidget);
    expect(find.text('更多设备'), findsOneWidget);
    // 页签带图标：投屏 = cast，输出 = speaker_group。
    // 组件内部每个 action 会渲染两份（计宽用），所以图标用 findsWidgets。
    final Finder tabGroup = find.byType(M3EToggleButtonGroup).first;
    expect(
      find.descendant(of: tabGroup, matching: find.byIcon(Icons.cast)),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: tabGroup,
        matching: find.byIcon(Icons.speaker_group_outlined),
      ),
      findsWidgets,
    );
    // 默认页不是投屏页
    expect(find.byType(DlnaCastView), findsNothing);
  });

  testWidgets('滑杆变化即下发音量（拖动中 persist:false，松手才落盘）', (tester) async {
    await pump(tester);
    final M3ESlider slider = tester.widget<M3ESlider>(find.byType(M3ESlider));
    expect(slider.value, closeTo(1.0, 0.01));

    // 直接驱动控件的回调（等价于拖到 40%）：绕开手势与落盘 I/O ——
    // setVolume 要写 SharedPreferences，在 fake-async 里 await 它会永久挂起，
    // 而 _volume 在 await 之前就已同步写入，断言不受影响。
    slider.onChanged!(0.4);
    await tester.pump();
    expect(player.volume, closeTo(0.4, 0.01), reason: '拖动中实时下发');
    expect(
      tester.widget<M3ESlider>(find.byType(M3ESlider)).value,
      closeTo(0.4, 0.01),
    );

    slider.onChangeEnd!(0.4);
    await tester.pump();
    expect(player.volume, closeTo(0.4, 0.01));
  });

  testWidgets('切到「投屏」页：换成 DlnaCastView，音量控件让位', (tester) async {
    await pump(tester);
    await tester.tap(_firstText('投屏'));
    await tester.pumpAndSettle();
    expect(find.byType(DlnaCastView), findsOneWidget);
    expect(find.byType(PlayerVolumeSlider), findsNothing);
  });

  testWidgets('音质区落在面板底部，点档位即下发且面板不关', (tester) async {
    await pump(tester);
    expect(find.text('音质'), findsOneWidget);
    for (final AudioQuality quality in kPlayerAudioQualities) {
      expect(
        find.descendant(
          of: find.byType(PlaybackQualitySection),
          matching: find.text(audioQualityShortLabel(quality)),
        ),
        findsWidgets,
      );
    }
    // 音质区在「更多设备」下方：y 更大
    final double qualityY = tester.getTopLeft(find.text('音质')).dy;
    final double moreY = tester.getTopLeft(find.text('更多设备')).dy;
    expect(qualityY, greaterThan(moreY));

    // 挑一个与当前档不同的档：已选中的那档再点一次会被组件当成"取消选中"。
    final AudioQuality before = player.audioQuality;
    final AudioQuality target = before == AudioQuality.flac
        ? AudioQuality.hires
        : AudioQuality.flac;
    await tester.tap(_qualityChip(audioQualityShortLabel(target)));
    await tester.pumpAndSettle();
    expect(player.audioQuality, target);
    expect(find.text('播放与输出'), findsOneWidget, reason: '面板不应关闭');
  });

  testWidgets('点「更多设备」调系统输出切换器', (tester) async {
    await pump(tester);
    await tester.tap(_firstText('更多设备'));
    await tester.pumpAndSettle();
    expect(switcherCalls, 1);
  });

  testWidgets('系统不支持时整行隐藏（不留假入口）', (tester) async {
    await pump(tester, supported: false);
    expect(find.text('更多设备'), findsNothing);
    expect(find.byType(PlayerVolumeSlider), findsOneWidget);
  });

  testWidgets('面板里没有蓝牙设置跳转', (tester) async {
    await pump(tester);
    expect(find.text('蓝牙设置'), findsNothing);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
    expect(find.byIcon(Icons.bluetooth), findsNothing);
  });

  testWidgets('本地歌曲锁死音质档位（只读）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackQualitySection(
            selected: AudioQuality.flac,
            locked: true,
            onSelected: (_) => fail('locked 时不应下发'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本地文件按码率显示'), findsOneWidget);
    // locked 时整组被 AbsorbPointer 挡住，命中测试落在屏障上，所以 warnIfMissed 关掉；
    // "没下发"由上面那个 fail() 断言。
    await tester.tap(_qualityChip('标准'), warnIfMissed: false);
    await tester.pumpAndSettle();
  });

  // ---- Windows 内联输出设备区（原 ⋯ 菜单二级弹窗收进本面板） ----

  testWidgets('非 Windows 形态不出现内联设备区（null 走运行时平台判定）', (tester) async {
    // 测试的 defaultTargetPlatform 是 android，isWindowsDesktop=false ⇒ 默认不画。
    await pump(tester);
    expect(find.byType(WindowsOutputDeviceSection), findsNothing);
    expect(find.text('输出设备'), findsNothing);
  });

  testWidgets('Windows 形态：设备列表内联、当前项带 check、点蓝牙设备即切换', (tester) async {
    await pump(
      tester,
      // Windows 上系统切换器探测返回 false（无该通道），「更多设备」不出现。
      supported: false,
      windowsDevices: true,
      devices: const [
        WindowsAudioOutputDevice(
          id: 'spk-1',
          name: 'Speakers (Realtek)',
          isSystemDefault: true,
        ),
        WindowsAudioOutputDevice(
          id: 'bt-1',
          name: 'WH-1000XM4 Bluetooth',
          isSystemDefault: false,
        ),
      ],
      selectedId: 'spk-1',
    );

    expect(find.text('输出设备'), findsOneWidget);
    expect(find.text('跟随系统默认'), findsOneWidget);
    expect(find.text('Speakers (Realtek)'), findsOneWidget);
    expect(find.text('WH-1000XM4 Bluetooth'), findsOneWidget);
    // 系统默认端点自己带副标题（与旧 picker 同口径）
    expect(find.text('系统默认'), findsOneWidget);
    // 蓝牙判定走蓝牙音频图标（不是通用喇叭）
    expect(find.byIcon(Icons.bluetooth_audio), findsOneWidget);
    // 只有一行被选中 ⇒ 恰好一个 check
    expect(find.byIcon(Icons.check), findsOneWidget);
    final spkRow = find
        .ancestor(
          of: find.text('Speakers (Realtek)'),
          matching: find.byType(InkWell),
        )
        .first;
    expect(
      find.descendant(of: spkRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('WH-1000XM4 Bluetooth'));
    await tester.tap(find.text('WH-1000XM4 Bluetooth'));
    await tester.pump();
    // fluttertoast 内部有 1s Timer，显式推进消化（避免挂起 Timer 断言）
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(
      toasts,
      contains('已切换到WH-1000XM4 Bluetooth'),
      reason: '切换要有可见反馈',
    );
    expect(find.text('播放与输出'), findsOneWidget, reason: '面板不应关闭');
    final btRow = find
        .ancestor(
          of: find.text('WH-1000XM4 Bluetooth'),
          matching: find.byType(InkWell),
        )
        .first;
    expect(
      find.descendant(of: btRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
      reason: 'check 要跟着挪到刚选的设备',
    );
  });

  testWidgets('Windows：枚举为空时如实提示，只剩「跟随系统默认」', (tester) async {
    await pump(tester, supported: false, windowsDevices: true);
    expect(find.text('未发现可用的输出设备'), findsOneWidget);
    expect(find.text('跟随系统默认'), findsOneWidget);
    expect(find.text('Speakers'), findsNothing);
  });

  testWidgets('Windows：切换失败时选中态回滚并提示失败', (tester) async {
    await pump(
      tester,
      supported: false,
      windowsDevices: true,
      devices: const [
        WindowsAudioOutputDevice(
          id: 'spk-1',
          name: 'Speakers (Realtek)',
          isSystemDefault: true,
        ),
      ],
      selectedId: 'spk-1',
      selectThrows: true,
    );

    await tester.tap(find.text('跟随系统默认'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(toasts, contains('切换输出设备失败'));
    // 回滚后 check 仍在原设备上，且只有一处 check
    expect(find.byIcon(Icons.check), findsOneWidget);
    final spkRow = find
        .ancestor(
          of: find.text('Speakers (Realtek)'),
          matching: find.byType(InkWell),
        )
        .first;
    expect(
      find.descendant(of: spkRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  // ---- 「USB 独占」托盘行（原 ⋯ 菜单「歌曲信息」入口在安卓上的新家） ----

  testWidgets('安卓形态：USB 独占行在音量与「更多设备」之间', (tester) async {
    await pump(tester, showUsbExclusive: true);
    expect(find.text('USB 独占'), findsOneWidget);
    // 位置契约：音量之下、「更多设备」之上
    final double usbY = tester.getTopLeft(find.text('USB 独占')).dy;
    final double volumeY = tester.getTopLeft(find.text('音量')).dy;
    final double moreY = tester.getTopLeft(find.text('更多设备')).dy;
    expect(usbY, greaterThan(volumeY));
    expect(usbY, lessThan(moreY));
    // 未连接 USB 设备：副标题说明原因，开关置灰
    expect(find.text('未检测到 USB 音频设备'), findsOneWidget);
    final Switch usbSwitch = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: find.text('USB 独占'),
          matching: find.byType(UsbExclusiveTrayRow),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(usbSwitch.onChanged, isNull, reason: '未连接时开关必须置灰');
  });

  testWidgets('USB 独占行：连接态开关可用且点开关走注入回调，点行体进二级页', (tester) async {
    final List<bool> toggles = [];
    int detailOpens = 0;
    await pump(
      tester,
      showUsbExclusive: true,
      usbRow: UsbExclusiveTrayRow(
        initialStatus: const {
          'deviceConnected': true,
          'deviceName': 'Test DAC',
          'enabled': false,
        },
        onToggle: (v) async => toggles.add(v),
        onOpenDetails: () => detailOpens += 1,
      ),
    );
    expect(find.text('Test DAC'), findsOneWidget, reason: '连接态副标题显示设备名');
    final Switch usbSwitch = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: find.text('USB 独占'),
          matching: find.byType(UsbExclusiveTrayRow),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(usbSwitch.value, isFalse);
    expect(usbSwitch.onChanged, isNotNull, reason: '连接后开关必须可用');

    // 点开关：走 onToggle，不开二级页
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, [true]);
    expect(detailOpens, 0);

    // 点行体（标题文字）：进二级页，开关不翻转
    await tester.tap(find.text('USB 独占'));
    await tester.pump();
    expect(detailOpens, 1);
    expect(toggles, [true], reason: '点行体不应触发开关');
  });

  testWidgets('showUsbExclusive=false 钉 Windows 形态：不出现 USB 独占行', (tester) async {
    await pump(tester, showUsbExclusive: false, usbRow: null);
    // 音量条只会在 USB 独占源下显示「USB 独占音量」chip，含「USB 独占」子串；
    // 精确匹配行标题「USB 独占」必须一个都没有。
    expect(find.text('USB 独占'), findsNothing);
    expect(find.byType(UsbExclusiveTrayRow), findsNothing);
  });
}
