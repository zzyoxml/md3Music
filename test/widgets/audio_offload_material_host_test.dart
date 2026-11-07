// 「硬件解码播放」页在 **material_ui** 宿主下的构建回归测试。
//
// 钉死 docs/agents/troubleshooting.md §4.13：设置页宿主是 setting 页的 material_ui
// `Scaffold`，它给 body 包的是 material_ui **自家**的 `Material`（同名不同型）。页内
// 若用 flutter/material 的 `SwitchListTile` / `InkWell`（按**类型**找祖先 Material），
// 就会抛 `No Material widget found`，再被全局 `_FallbackErrorWidget` 顶成
// 「此处内容加载出错」——真机表现为「播放 → 硬件解码播放」整块变成错误提示。
//
// 因此本测试的宿主**必须**是 material_ui 的 App/Scaffold，不能用 flutter/material 的
// Scaffold 糊过去（那样测试会假绿，真机仍然崩）。页面自身带的那层
// `Material(type: MaterialType.transparency)` 是修复本体，删掉它本用例应当变红。
//
// 依赖注入：服务层没有测试 fake 注入口，按契约 mock 原生通道
// `com.md3music.md3music/audio_offload` 的四个读取方法。
import 'package:flutter/material.dart' as fm;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/audio_offload_service.dart';
import 'package:md3music/widgets/audio_offload_page_body.dart';

/// 原生状态：API 33（≥29，平台支持），未进入 offload。
Map<String, dynamic> _statusMap() => <String, dynamic>{
      'apiLevel': 33,
      'offloaded': false,
      'sleeping': false,
      'failed': false,
      'deviceKey': 'test-device-key',
    };

/// offload 协商快照：MP3 一条（44100 支持）+ AAC-LC 一条（不支持）。
Map<String, dynamic> _offloadSnapshotMap() => <String, dynamic>{
      'deviceKey': 'test-device-key',
      'probedAt': DateTime(2026, 1, 2, 10, 30, 5).millisecondsSinceEpoch,
      'sdkInt': 33,
      'variableRateSupported': true,
      'outputSampleRate': 48000,
      'outputFramesPerBuffer': 1024,
      'probeError': null,
      'entries': <Map<String, dynamic>>[
        <String, dynamic>{
          'encoding': 9,
          'encodingName': 'audio/mpeg',
          'sampleRate': 44100,
          'channelCount': 2,
          'supported': true,
          'gapless': true,
          'speedChange': true,
        },
        <String, dynamic>{
          'encoding': 10,
          'encodingName': 'audio/mp4a-latm',
          'sampleRate': 44100,
          'channelCount': 2,
          'supported': false,
          'gapless': false,
          'speedChange': false,
        },
      ],
    };

/// 解码器能力快照：MP3 + AAC 各一个硬件解码器（AAC 未做位深实测）。
Map<String, dynamic> _decoderSnapshotMap() => <String, dynamic>{
      'deviceKey': 'test-device-key',
      'probedAtMs': DateTime(2026, 1, 2, 10, 30, 5).millisecondsSinceEpoch,
      'sdkInt': 33,
      'probeCostMs': 12,
      'probeError': null,
      'notes': <String>['APE 无系统解码器，只能软解'],
      'entries': <Map<String, dynamic>>[
        <String, dynamic>{
          'codecName': 'c2.android.mp3.decoder',
          'mime': 'audio/mpeg',
          'formatLabel': 'MP3',
          'hardware': true,
          'softwareOnly': false,
          'sampleRates': <int>[44100, 48000],
          'maxChannels': 2,
          'bitDepths': <String, String>{
            '16': 'supported',
            '24': 'unsupported',
            '32': 'unknown',
            'float': 'unknown',
          },
          'bitDepthProbed': true,
        },
        <String, dynamic>{
          'codecName': 'c2.android.aac.decoder',
          'mime': 'audio/mp4a-latm',
          'formatLabel': 'AAC',
          'hardware': true,
          'softwareOnly': false,
          'sampleRates': <int>[44100, 48000],
          'maxChannels': 2,
          'bitDepths': <String, String>{
            '16': 'supported',
            '24': 'unknown',
            '32': 'unknown',
            'float': 'unknown',
          },
          'bitDepthProbed': false,
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const MethodChannel channel = MethodChannel(AudioOffloadService.channelName);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'getStatus':
          return _statusMap();
        case 'getCachedCapabilities':
        case 'probeCapabilities':
          return _offloadSnapshotMap();
        case 'getCachedDecoderCapabilities':
        case 'probeDecoderCapabilities':
          return _decoderSnapshotMap();
        case 'setEnabled':
          return _statusMap();
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('material_ui 宿主下页面不抛 No Material widget found',
      (WidgetTester tester) async {
    // 视口放大：页面很长，展开折叠区要能点得到（不影响本用例的判定点）。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 先注入两个快照，让页面渲染出完整内容（编码卡、折叠 header 等 ink 组件）。
    await AudioOffloadService.instance.reloadAllCapabilities();

    // 宿主 = material_ui 的 App + Scaffold（与设置页一致），不是 flutter/material。
    await tester.pumpWidget(
      mui.MaterialApp(
        theme: mui.ThemeData.light(useMaterial3: true),
        home: mui.Scaffold(
          body: mui.SingleChildScrollView(
            child: const AudioOffloadPageBody(),
          ),
        ),
      ),
    );
    await tester.pump();

    // 核心断言：build 期没有异常（§4.13 复发时这里会是 No Material widget found）。
    expect(tester.takeException(), isNull);
    expect(find.text('硬件解码播放'), findsOneWidget);
    expect(find.byType(fm.SwitchListTile), findsOneWidget);

    // 解码器能力折叠 header 常驻 + 摘要在收起态可见（不只是开关活着）。
    expect(find.text('设备解码器能力'), findsOneWidget);
    expect(
      find.text('硬解解码器 2 个 · 支持编码 2 种 · 探测耗时 12 ms'),
      findsOneWidget,
    );

    // 两个折叠 header 用的都是 flutter/material 的 InkWell：在 material_ui 宿主
    // 下能点，点开后内容渲染也不抛异常。
    await tester.tap(find.text('设备解码器能力'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('MP3'), findsOneWidget);

    expect(find.text('系统 offload 协商'), findsOneWidget);
    await tester.tap(find.text('系统 offload 协商'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('设备指纹'), findsOneWidget);

    // 卸载页面，取消 1s 轮询 Timer（否则测试结束报 pending timer）。
    await tester.pumpWidget(const mui.SizedBox.shrink());
    await tester.pump();
  });
}
