import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/platform_capabilities.dart';
import 'package:md3music/modules/sheet/song_sheet_sheet.dart';

/// 曲谱渲染分流测试：平台门控 + SheetRenderTarget.url 兜底拼接。
///
/// 回归：曲谱详情页（SheetRenderPage）在桌面端无条件构造 WebViewController，
/// 而 webview_flutter 没有 Windows 平台实现（.flutter-plugins-dependencies
/// 实证），抛 MissingPluginException 后整页被全局 ErrorWidget
/// （「此处内容加载出错」）替换 —— 修复为 supportsInAppWebView 门控 +
/// 桌面/TV 降级系统浏览器（openSheetRender）。
///
/// 注意口径：flutter_tester 里 defaultTargetPlatform 默认恒为 android
/// （探针实测），模拟桌面必须用 debugDefaultTargetPlatformOverride；
/// dart:io Platform 在测试进程读的是宿主（Windows），isAndroidPlatform
/// 的 Platform.isAndroid 分支恒 false，override 生效。
void main() {
  test('模拟 Windows 桌面：supportsInAppWebView 必须为 false（降级系统浏览器）', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(supportsInAppWebView, isFalse);
  });

  test('flutter_tester 默认 android 语义：supportsInAppWebView 为 true', () {
    // 不设 override 时测试环境等同 Android（defaultTargetPlatform=android）。
    // 若这里为 false 说明门控口径被改坏，Android 真机会走系统浏览器降级。
    expect(supportsInAppWebView, isTrue);
  });

  test('SheetRenderTarget.url 优先 jump_url', () {
    const target = SheetRenderTarget(
      title: 'AI弹唱谱',
      opernId: '68435136_7_335924',
      jumpUrl: 'https://h5.kugou.com/voo/v-73bc3efd/xml.html?opernid=x',
    );
    expect(target.url, 'https://h5.kugou.com/voo/v-73bc3efd/xml.html?opernid=x');
  });

  test('SheetRenderTarget.url 无 jump_url 时按 opern_id 拼官方渲染页', () {
    const target = SheetRenderTarget(
      title: '弹唱谱',
      opernId: '68435136_1_0',
    );
    expect(target.url, contains('https://h5.kugou.com/voo/'));
    expect(target.url, contains('opernid=68435136_1_0'));
    expect(target.url, contains('sheetDataType=0'));
  });

  test('SheetRenderTarget.url 非 http 的 jump_url 视为无效走兜底', () {
    const target = SheetRenderTarget(
      title: '弹唱谱',
      opernId: 'a_b_c',
      jumpUrl: 'javascript:alert(1)',
    );
    expect(target.url, contains('opernid=a_b_c'));
  });
}
