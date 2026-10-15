// 与被测页面保持一致：项目统一用 material_ui
// （Flutter 3.47 起 Material 库解耦；用 flutter/material.dart 会导致
//  MaterialApp 提供的 Material 与页面组件的 Material 不是同一个类而断言失败）
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/modules/library/remote_storage_page.dart';
import 'package:md3music/providers/remote_storage_provider.dart';
import 'package:provider/provider.dart';

void main() {
  // 用 ChangeNotifierProvider.value 包裹：与生产一致，页面从 Provider 树读取。
  Widget host(RemoteStorageProvider provider) {
    return ChangeNotifierProvider<RemoteStorageProvider>.value(
      value: provider,
      child: const MaterialApp(
        home: Scaffold(body: RemoteStoragePage()),
      ),
    );
  }

  testWidgets('无配置时显示引导文案与添加提示', (tester) async {
    final provider = RemoteStorageProvider();
    await tester.pumpWidget(host(provider));
    await tester.pump();

    expect(find.text('还没有远程存储'), findsOneWidget);
    expect(find.text('添加远程存储'), findsWidgets);
  });

  testWidgets('有配置时显示配置名称与协议标签', (tester) async {
    final provider = RemoteStorageProvider();
    provider.setConfigs(const [
      RemoteStorageConfig(
        id: 'a',
        name: '我的NAS',
        type: RemoteStorageType.webdav,
        host: '192.168.1.10',
        username: 'u',
      ),
    ]);
    await tester.pumpWidget(host(provider));
    await tester.pump();

    expect(find.text('我的NAS'), findsOneWidget);
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.text('192.168.1.10:80'), findsOneWidget);
  });

  testWidgets('FTP 配置显示 FTP 协议标签', (tester) async {
    final provider = RemoteStorageProvider();
    provider.setConfigs(const [
      RemoteStorageConfig(
        id: 'b',
        name: '老FTP',
        type: RemoteStorageType.ftp,
        host: '10.0.0.2',
      ),
    ]);
    await tester.pumpWidget(host(provider));
    await tester.pump();

    expect(find.text('老FTP'), findsOneWidget);
    expect(find.text('FTP'), findsOneWidget);
    expect(find.text('10.0.0.2:21'), findsOneWidget);
  });
}