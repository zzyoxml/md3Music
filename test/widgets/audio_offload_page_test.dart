// 「硬件解码播放」设置页的渲染 / 折叠 / 探测回调测试（新结构）。
//
// 页面结构：开关 → 精简状态卡（3 行常驻 + 异常态追加）→ **设备解码器能力**
// 折叠区（默认收起，header 摘要常驻）→「系统 offload 协商」折叠区（默认收起）
// → 操作按钮行。
//
// 依赖注入点：服务层没有测试专用的 fake 注入口，故按契约 mock 原生通道
// （`com.md3music.md3music/audio_offload`）：
// - `getCachedCapabilities` / `probeCapabilities` 返回固定 offload 协商快照；
// - `getCachedDecoderCapabilities` / `probeDecoderCapabilities` 返回固定解码器快照；
// - `getStatus` 返回 API 33 的平台状态；
// - 分别统计两个 `probe*` 调用次数，验证「重新探测」确实重跑了**两个数据源**。
//
// 注意：[AudioOffloadService] 是进程级单例且无 reset 入口，所以「无快照」用例必须
// 排在写入快照的用例之前（本文件按声明顺序执行）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/audio_offload_service.dart';
import 'package:md3music/widgets/audio_offload_page_body.dart';

const MethodChannel _channel = MethodChannel(AudioOffloadService.channelName);

/// 原生状态：API 33（≥29，平台支持），未进入 offload。
Map<String, dynamic> _statusMap({bool offloaded = false}) => <String, dynamic>{
      'apiLevel': 33,
      'offloaded': offloaded,
      'sleeping': false,
      'failed': false,
      'deviceKey': 'test-device-key',
    };

/// offload 协商快照：MP3 两条（44100 支持 / 48000 不支持）+ AAC-LC 一条（不支持）。
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
          'encoding': 9,
          'encodingName': 'audio/mpeg',
          'sampleRate': 48000,
          'channelCount': 2,
          'supported': false,
          'gapless': false,
          'speedChange': false,
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

/// 解码器能力快照：MP3 + AAC 各一个硬件解码器。
///
/// MP3 做过位深实测（16 支持 / 24 不支持 / 32 与 float 未知），AAC 因 configure
/// 预算跳过实测（只有 16 支持，其余 unknown）—— 正好覆盖位深三态与「未实测」小字。
///
/// [probeError] 非空时用于验证「探测失败原因」以主题 error 色展示；
/// [allSoftware] 为 true 时 MP3 条目改软解（模拟移动平台 MediaCodec 无音频
/// 硬解的常态设备），用于验证 header 摘要与位深文案的「全软解」分支。
Map<String, dynamic> _decoderSnapshotMap({
  String? probeError,
  bool allSoftware = false,
}) =>
    <String, dynamic>{
      'deviceKey': 'test-device-key',
      'probedAtMs': DateTime(2026, 1, 2, 10, 30, 5).millisecondsSinceEpoch,
      'sdkInt': 33,
      'probeCostMs': 12,
      'probeError': probeError,
      'notes': <String>['APE 无系统解码器，只能软解'],
      'entries': <Map<String, dynamic>>[
        <String, dynamic>{
          'codecName': 'c2.android.mp3.decoder',
          'mime': 'audio/mpeg',
          'formatLabel': 'MP3',
          'hardware': !allSoftware,
          'softwareOnly': allSoftware,
          'sampleRates': <int>[44100, 48000],
          'maxChannels': 2,
          'bitDepths': <String, String>{
            '16': allSoftware ? 'unknown' : 'supported',
            '24': allSoftware ? 'unknown' : 'unsupported',
            '32': 'unknown',
            'float': 'unknown',
          },
          'bitDepthProbed': !allSoftware,
        },
        <String, dynamic>{
          'codecName': 'c2.android.aac.decoder',
          'mime': 'audio/mp4a-latm',
          'formatLabel': 'AAC',
          'hardware': !allSoftware,
          'softwareOnly': allSoftware,
          'sampleRates': <int>[44100, 48000],
          'maxChannels': 2,
          'bitDepths': <String, String>{
            '16': allSoftware ? 'unknown' : 'supported',
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

  int probeCalls = 0;
  int decoderProbeCalls = 0;
  String? decoderProbeError;
  bool decoderAllSoftware = false;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    probeCalls = 0;
    decoderProbeCalls = 0;
    decoderProbeError = null;
    decoderAllSoftware = false;
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      switch (call.method) {
        case 'getStatus':
          return _statusMap();
        case 'getCachedCapabilities':
          return _offloadSnapshotMap();
        case 'probeCapabilities':
          probeCalls++;
          return _offloadSnapshotMap();
        case 'getCachedDecoderCapabilities':
          return _decoderSnapshotMap(
            probeError: decoderProbeError,
            allSoftware: decoderAllSoftware,
          );
        case 'probeDecoderCapabilities':
          decoderProbeCalls++;
          return _decoderSnapshotMap(
            probeError: decoderProbeError,
            allSoftware: decoderAllSoftware,
          );
        case 'setEnabled':
          final Object? args = call.arguments;
          final bool enabled =
              args is Map && args['enabled'] == true;
          return _statusMap(offloaded: enabled);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  /// 页面主体是设置三级页的内容块（非独立 Scaffold），宿主提供主题与滚动容器。
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );
  }

  /// 挂载页面：默认 800x600 视口放不下整页（编码卡 + 折叠区 + 按钮行在折叠线以下），
  /// 用高视口保证按钮可点，避免 `tap()` 因目标在视口外而静默落空。
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(const AudioOffloadPageBody()));
    await tester.pump();
  }

  /// 卸载页面，确保 1s 轮询 Timer 被 dispose 取消（否则测试结束时报 pending timer）。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// 展开「系统 offload 协商」折叠区（验证自绘 header 而不是 ExpansionTile）。
  Future<void> expandOffload(WidgetTester tester) async {
    await tester.tap(find.text('系统 offload 协商'));
    await tester.pump();
  }

  /// 展开「设备解码器能力」折叠区（自绘 header，默认收起）。
  Future<void> expandDecoder(WidgetTester tester) async {
    await tester.tap(find.text('设备解码器能力'));
    await tester.pump();
  }

  testWidgets('没有能力快照时显示尚未探测', (WidgetTester tester) async {
    await mount(tester);

    expect(find.text('硬件解码播放'), findsOneWidget);
    // 解码器能力折叠 header 的空态摘要（收起态常驻可见）
    expect(find.text('设备解码器能力'), findsOneWidget);
    expect(find.text('尚未探测'), findsOneWidget);
    // 状态卡在没有曲目时给「待播放」而不是空白
    expect(find.text('待播放'), findsOneWidget);
    // 让路原因 / 平台为异常态动态行，正常态不渲染
    expect(find.text('让路原因'), findsNothing);
    expect(find.text('平台'), findsNothing);
    // 结论行保留（预测已融合进来，不再单列「解码器」「系统 offload」行）
    expect(find.text('结论'), findsOneWidget);
    expect(find.text('不确定 · 实测：软解中'), findsOneWidget);
    // offload 协商矩阵默认收起，所以它的「尚未探测」不应出现
    expect(find.text('系统 offload 协商'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('解码器能力默认收起，点开后渲染摘要、编码卡与位深三态',
      (WidgetTester tester) async {
    // 预先注入两个快照（等价于启动时读到缓存），再挂载页面。
    await AudioOffloadService.instance.reloadAllCapabilities();
    await mount(tester);

    // header 常驻 + 摘要在收起态就可见
    expect(find.text('设备解码器能力'), findsOneWidget);
    expect(
      find.text('硬解解码器 2 个 · 支持编码 2 种 · 探测耗时 12 ms'),
      findsOneWidget,
    );
    // 默认收起：编码卡内容不在
    expect(find.text('MP3'), findsNothing);
    expect(find.text('AAC'), findsNothing);

    await expandDecoder(tester);

    // 来源说明全区块只出现一次（不再每张卡重复）
    expect(find.text('以下能力为设备解码器（MediaCodec）上报，仅供参考'),
        findsOneWidget);

    // 每编码一张卡，按 byFormat 固定顺序：MP3 在 AAC 之上
    expect(find.text('MP3'), findsOneWidget);
    expect(find.text('AAC'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('MP3')).dy,
      lessThan(tester.getTopLeft(find.text('AAC')).dy),
    );
    // 硬解徽标 + 解码器计数 + 声道
    expect(find.text('硬解'), findsNWidgets(2));
    expect(find.text('1 个解码器'), findsNWidgets(2));
    expect(find.text('最多 2 声道'), findsNWidgets(2));

    // 采样率 chips：只列支持项（两张卡各 2 个）
    expect(find.text('44100 Hz'), findsNWidgets(2));
    expect(find.text('48000 Hz'), findsNWidgets(2));

    // 位深三态：16 / 24 / 32 / float 各两次
    expect(find.text('16'), findsNWidgets(2));
    expect(find.text('24'), findsNWidgets(2));
    expect(find.text('32'), findsNWidgets(2));
    expect(find.text('float'), findsNWidgets(2));
    // AAC 未实测 → 恰好一处「未实测（configure 预算内跳过）」
    expect(find.text('未实测（configure 预算内跳过）'), findsOneWidget);
    // 原生备注照原样展示
    expect(find.text('· APE 无系统解码器，只能软解'), findsOneWidget);

    // 三态配色：supported=主色 / unsupported=onSurfaceVariant 无描边 /
    // unknown=outline 描边（取第一张卡 MP3 的 16/24/32 三档核对）。
    final ColorScheme colorScheme =
        Theme.of(tester.element(find.text('MP3'))).colorScheme;
    TextStyle? styleOf(String label) =>
        tester.widget<Text>(find.text(label).first).style;
    BoxDecoration decorationOf(String label) {
      final Finder ancestor = find
          .ancestor(of: find.text(label).first, matching: find.byType(Container))
          .first;
      return tester.widget<Container>(ancestor).decoration! as BoxDecoration;
    }

    expect(styleOf('16')?.color, colorScheme.primary);
    expect(styleOf('24')?.color, colorScheme.onSurfaceVariant);
    expect(styleOf('32')?.color, colorScheme.onSurfaceVariant);
    expect((decorationOf('16').border! as Border).top.color,
        colorScheme.primary);
    expect(decorationOf('24').border, isNull);
    expect((decorationOf('32').border! as Border).top.color,
        colorScheme.outline);

    // 再点一次收起，编码卡消失
    await expandDecoder(tester);
    expect(find.text('MP3'), findsNothing);

    await unmount(tester);
  });

  testWidgets('解码器探测失败时用主题 error 色展示原因',
      (WidgetTester tester) async {
    decoderProbeError = '原生枚举超时';
    await AudioOffloadService.instance.reloadAllCapabilities();
    await mount(tester);

    // 收起态：header 摘要即显示失败原因（error 色）
    final Finder errorText = find.text('探测失败：原生枚举超时');
    expect(errorText, findsOneWidget);
    final ColorScheme colorScheme =
        Theme.of(tester.element(find.text('设备解码器能力'))).colorScheme;
    expect(tester.widget<Text>(errorText).style?.color, colorScheme.error);

    await unmount(tester);
  });

  testWidgets('全软解设备：摘要显示格式总数并点明 DSP 原因，位深文案区分',
      (WidgetTester tester) async {
    // 模拟移动平台常态：MediaCodec 音频全软解（硬解在 DSP/offload 完成）。
    decoderAllSoftware = true;
    await AudioOffloadService.instance.reloadAllCapabilities();
    await mount(tester);

    // 收起态 header 摘要：不再显示「硬解 0 个 · 支持编码 0 种」的误导性数字，
    // 而是给出格式总数并解释为什么没有硬解条目。
    expect(
      find.text('探测到 2 种编码 · 均为软解（音频硬解通常走 DSP，不经 MediaCodec）'),
      findsOneWidget,
    );
    // 旧文案（可硬解路径）不应出现
    expect(find.textContaining('硬解解码器'), findsNothing);

    await expandDecoder(tester);

    // 两个格式都无硬件解码器 → 位深小字统一为「无硬件解码器」文案，
    // 「预算内跳过」只应出现在确有硬解条目的快照（其它用例已覆盖）。
    expect(find.text('未实测（无硬件解码器，不做试配）'), findsNWidgets(2));
    expect(find.text('未实测（configure 预算内跳过）'), findsNothing);
    // 软解徽标两张卡各一枚
    expect(find.text('软解'), findsNWidgets(2));
    expect(find.text('硬解'), findsNothing);

    await unmount(tester);
  });

  testWidgets('解码器清单默认收起，点开后列出组件名与 MIME',
      (WidgetTester tester) async {
    await AudioOffloadService.instance.reloadAllCapabilities();
    await mount(tester);
    await expandDecoder(tester);

    expect(find.text('解码器清单（2）'), findsOneWidget);
    expect(find.text('c2.android.mp3.decoder'), findsNothing);
    expect(find.text('audio/mpeg'), findsNothing);

    await tester.tap(find.text('解码器清单（2）'));
    await tester.pump();

    expect(find.text('c2.android.mp3.decoder'), findsOneWidget);
    expect(find.text('c2.android.aac.decoder'), findsOneWidget);
    expect(find.text('audio/mpeg'), findsOneWidget);
    expect(find.text('audio/mp4a-latm'), findsOneWidget);
    // 再点一次收起
    await tester.tap(find.text('解码器清单（2）'));
    await tester.pump();
    expect(find.text('c2.android.mp3.decoder'), findsNothing);

    await unmount(tester);
  });

  testWidgets('系统 offload 协商默认收起，点开后出现协商矩阵',
      (WidgetTester tester) async {
    await AudioOffloadService.instance.reloadAllCapabilities();
    await mount(tester);

    // header 常驻，作用说明小字也在
    expect(find.text('系统 offload 协商'), findsOneWidget);
    expect(find.text('决定本开关是否真正生效'), findsOneWidget);
    // 默认收起：协商矩阵的设备卡与计数都不在
    expect(find.text('设备指纹'), findsNothing);
    expect(find.text('1/2'), findsNothing);

    await expandOffload(tester);

    expect(find.text('设备指纹'), findsOneWidget);
    expect(find.text('test-device-key'), findsOneWidget);
    expect(find.text('API 33'), findsWidgets);
    // 编码分节与支持计数（MP3: 1/2，AAC-LC: 0/1）
    expect(find.text('AAC-LC'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('0/1'), findsOneWidget);
    expect(find.text('gapless'), findsOneWidget);
    expect(find.text('未探测'), findsOneWidget);

    // 收起后矩阵消失
    await expandOffload(tester);
    expect(find.text('设备指纹'), findsNothing);

    await unmount(tester);
  });

  testWidgets('点击重新探测会同时重跑解码器枚举与 offload 协商',
      (WidgetTester tester) async {
    await AudioOffloadService.instance.reloadAllCapabilities();
    await mount(tester);

    final int beforeOffload = probeCalls;
    final int beforeDecoder = decoderProbeCalls;
    await tester.tap(find.text('重新探测'));
    await tester.pump();
    // 通道调用是异步的：推进一小段时间让两个 Future 完成后 setState 生效。
    await tester.pump(const Duration(milliseconds: 50));

    expect(probeCalls, beforeOffload + 1);
    expect(decoderProbeCalls, beforeDecoder + 1);
    // 探测结束后按钮恢复可点
    expect(find.text('重新探测'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('开关关闭时状态卡显示软解', (WidgetTester tester) async {
    await mount(tester);

    // 默认未开启：开关关 + 实际状态为软解（开关行不再在状态卡里重复）
    final SwitchListTile tile =
        tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
    expect(find.text('已关（软解）'), findsOneWidget);

    await unmount(tester);
  });
}
