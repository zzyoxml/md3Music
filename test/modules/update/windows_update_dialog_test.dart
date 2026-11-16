import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:md3music/modules/update/release_info.dart';
import 'package:md3music/modules/update/windows_update_dialog.dart';
import 'package:md3music/modules/update/windows_update_service.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _WebLauncher extends UrlLauncherPlatform {
  final urls = <String>[];
  final modes = <PreferredLaunchMode>[];

  @override
  get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(url);
    modes.add(options.mode);
    return true;
  }
}

class _Installer extends WindowsUpdateService {
  final ready = Completer<void>();
  String? version;

  @override
  Future<File> download(ReleaseInfo release, {
    required void Function(int, int) onProgress,
    CancelToken? cancelToken,
  }) async => File('update.zip');

  @override
  Future<void> installAndExit(File archive, {required String expectedVersion}) {
    version = expectedVersion;
    return ready.future;
  }
}

void main() {
  testWidgets('更新弹窗底部按钮在下载前后整组水平居中', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
      TextButton(onPressed: () => showWindowsUpdateDialog(
        context,
        ReleaseInfo.fromTag(tagName: 'v6.1.0', htmlUrl: ''),
        service: _Installer(),
        onExitForUpdate: () async {},
      ), child: const Text('打开')),
    )));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    for (final label in ['下载更新', '立即更新']) {
      final first = tester.getRect(find.widgetWithText(M3ETextButton, '项目地址'));
      final last = tester.getRect(find.widgetWithText(M3EFilledButton, label));
      final content = tester.getRect(find.text('MD3Music v6.1.0'));
      final offset = (first.left + last.right) / 2 - content.center.dx;
      debugPrint('ACTION_CENTER $label offset=${offset.toStringAsFixed(2)}px');
      expect(offset.abs(), lessThan(1), reason: '按钮组应与弹窗内容水平中心对齐');
      if (label == '下载更新') {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('网页跳转：项目地址与镜像下载网站使用外部浏览器，下载后仍可访问', (tester) async {
    final original = UrlLauncherPlatform.instance;
    final launcher = _WebLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
      TextButton(onPressed: () => showWindowsUpdateDialog(
        context,
        ReleaseInfo.fromTag(tagName: 'v6.1.0', htmlUrl: ''),
        service: _Installer(),
        onExitForUpdate: () async {},
      ), child: const Text('打开')),
    )));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目地址'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('镜像下载网站'));
    await tester.pumpAndSettle();
    expect(launcher.urls, [
      'https://github.com/zzyoxml/md3Music',
      'https://git.hiwiki.org/zh-CN/repo/zzyoxml/md3music',
    ]);
    expect(launcher.modes, everyElement(PreferredLaunchMode.externalApplication));
    expect(find.text('下载更新'), findsOneWidget);
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('立即更新'), findsOneWidget);
    await tester.tap(find.text('镜像下载网站'));
    await tester.pumpAndSettle();
    expect(launcher.urls.last, 'https://git.hiwiki.org/zh-CN/repo/zzyoxml/md3music');
  });

  for (final failed in [false, true]) {
    testWidgets(failed ? '更新器准备失败显示错误，不退出当前程序' : '更新器就绪前不退出，完成交接才退出', (tester) async {
      final installer = _Installer();
      var exits = 0;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
        TextButton(onPressed: () => showWindowsUpdateDialog(
          context,
          ReleaseInfo.fromTag(tagName: 'v6.1.0', htmlUrl: ''),
          service: installer,
          onExitForUpdate: () async { exits++; },
        ), child: const Text('打开')),
      )));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即更新'));
      await tester.pump();
      expect(find.textContaining('正在解压并校验更新包'), findsOneWidget);
      expect(exits, 0);
      expect(installer.version, '6.1.0');
      if (failed) {
        installer.ready.completeError(StateError('更新程序未能就绪'));
      } else {
        installer.ready.complete();
      }
      await tester.pumpAndSettle();
      expect(exits, failed ? 0 : 1);
      if (failed) expect(find.textContaining('更新程序未能就绪'), findsOneWidget);
    });
  }
}
