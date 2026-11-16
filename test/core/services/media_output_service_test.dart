// 系统输出切换通道门面：透传 + 失败降级。
//
// 降级是重点：Windows、TV 老壳、未注册插件的构建里都**没有**这条通道，
// 门面必须安静地返回 false，让调用方隐藏入口，而不是把异常抛到 UI。
//
// 通道只做两件事：能力探测 + 唤起系统输出面板。**不再提供"当前输出设备名"**：
// AudioManager 只给可用列表、MediaRouter2 的系统路由在部分 ROM 上滞后，
// 两版都出现过"连着蓝牙却显示本机"，故该能力整体下掉。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/media_output_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'com.md3music.md3music/media_output',
  );
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('isSwitcherSupported 透传原生布尔', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'isSwitcherSupported');
      return true;
    });
    expect(await MediaOutputService.isSwitcherSupported(), isTrue);
  });

  test('showSystemOutputSwitcher 透传原生结果', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'showSystemOutputSwitcher');
      return false;
    });
    expect(await MediaOutputService.showSystemOutputSwitcher(), isFalse);
  });

  test('没有原生实现时全部降级', () async {
    // 不挂 mock handler：MethodChannel 会抛 MissingPluginException，
    // 门面必须吞掉并按"不支持"结算。
    expect(await MediaOutputService.isSwitcherSupported(), isFalse);
    expect(await MediaOutputService.showSystemOutputSwitcher(), isFalse);
  });
}
