import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/usb_exclusive_section.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// USB 独占页底部「调试信息」折叠块的构建守卫。
///
/// 症状：点开「调试信息」后整块变成「此处内容加载出错」。这是
/// docs/agents/troubleshooting.md §4.13 记录的症状（main.dart 把
/// ErrorWidget.builder 换成兜底件，任何 build 期异常都顶成这块红字），
/// 但本案根因不同：PageStorage 标识符串台——折叠块把「是否展开」的 bool
/// 写进 bucket，SelectableText 内部的 Scrollable 在同一标识符上按 `double?`
/// 读回滚动偏移，抛 `type 'bool' is not a subtype of type 'double?'`。
///
/// 宿主必须复刻生产的两个要素，否则不复现：
/// 1. 列表带 `PageStorageKey`（设置页见 settings_page.dart 的 `_sectionListKey`）
///    —— 没有它，标识符链为空，PageStorage 根本不读写；
/// 2. 折叠块挂在路由的 `PageStorage` 之下（`MaterialApp` 的页面默认自带）。
class _FakePlayer extends PlayerProvider {
  @override
  Song? get currentSong => null;

  @override
  dynamic get audioService => null;
}

/// 原生状态：deviceConnected=false（外层开关置灰，不触发任何独占副作用），
/// diagnostics 非空，保证展开后诊断文本有内容。
const Map<String, dynamic> _fakeStatus = <String, dynamic>{
  'enabled': false,
  'deviceConnected': false,
  'streamAlive': false,
  'streamReady': false,
  'deviceName': 'Test DAC',
  'uacLabel': 'UAC2',
  'sampleRate': 0,
  'channelCount': 0,
  'dacBitDepth': 0,
  'lastSampleRate': 0,
  'lastChannelCount': 0,
  'lastEncoding': 0,
  'supportedRates': <int>[44100, 48000],
  'supportedBits': <int>[16, 24],
  'supportedChannels': <int>[2],
  'capabilitiesSource': 'probed',
  'diagnostics': 'topology: test\nendpoint: 0x03',
};

void _mockUsbChannel() {
  const channel = MethodChannel('com.md3music.md3music/usb_audio');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
    switch (call.method) {
      case 'getStatus':
      case 'probeDacCapabilities':
        return _fakeStatus;
      default:
        return null;
    }
  });
}

/// 与设置页二级分类页同构的宿主（含 PageStorageKey 的 ListView + ListTileTheme）。
Widget _host() {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: _FakePlayer()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ListView(
          key: const PageStorageKey<String>('settings|category|USB 独占'),
          children: const <Widget>[
            ListTileTheme(child: UsbExclusiveSection()),
          ],
        ),
      ),
    ),
  );
}

void _prepareViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 3000);
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _mockUsbChannel();
  });

  testWidgets('折叠态不构建诊断内容（ExpansionTile maintainState 默认 false）',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _prepareViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pump();

    expect(find.text('调试信息'), findsOneWidget);
    expect(find.text('复制诊断信息'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('点开「调试信息」后展开全程无 build 异常（PageStorage 不串台）',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _prepareViewport(tester);
    await tester.pumpWidget(_host());
    await tester.pump();

    await tester.ensureVisible(find.text('调试信息'));
    await tester.pump();
    await tester.tap(find.text('调试信息'));
    await tester.pumpAndSettle();

    expect(find.text('复制诊断信息'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 折叠 → 再展开：PageStorage 里的 bool 往返也不能污染文本滚动偏移。
    await tester.tap(find.text('调试信息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('调试信息'));
    await tester.pumpAndSettle();

    expect(find.text('复制诊断信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
