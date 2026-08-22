import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../main.dart' show requestPermissions, runBootstrap;
import 'cache_bridge.dart';
import 'downloads_provider.dart';
import 'enhanced_ui.dart';

/// 私有入口（`flutter build -t lib/private/main_private.dart`）。
///
/// 与公开入口 `lib/main.dart` 唯一差异：
/// 1. 安装下载/缓存扩展钩子（installCacheHooks + installUiHooks）；
/// 2. 额外注册 DownloadsProvider；
/// 3. 首帧后请求权限（下载功能依赖存储权限）。
/// 本文件在导出公开版本时整体排除，永不进入公开仓库。
Future<void> main() async {
  final (needsOnboarding, needsUserAgreement) = await runBootstrap();

  // 安装扩展钩子：必须在 runApp 之前（Provider 惰性创建、widget 构建前生效）。
  installCacheHooks();
  installUiHooks();

  runApp(
    MyApp(
      showOnboarding: needsOnboarding,
      showUserAgreement: needsUserAgreement,
      extraProviders: [
        ChangeNotifierProvider(create: (_) => DownloadsProvider()),
      ],
    ),
  );

  // 权限请求推迟到首帧后，避免阻塞首屏。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      requestPermissions();
    } catch (e) {
      print('Request permissions error (ignored): $e');
    }
  });
}
