import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'dart:io' show Platform;
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/services/desktop_lyric_service.dart';
import 'core/services/lyricon_provider_service.dart';
import 'core/services/media_notification_service.dart';
import 'data/repositories/settings_repository.dart';
import 'services/nodejs_server.dart';
import 'widgets/apple_lyrics/layout/lyric_preferences.dart';

const String _kBatteryPromptShownKey = 'battery_prompt_shown';

/// 顶级 Navigator 的 GlobalKey，预留供后续扩展使用。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  // 加载歌词字号/行间距偏好（从 SharedPreferences）
  await LyricPreferences.instance.load();
  // 注册通知栏/悬浮窗回调（悬浮窗内按钮 → DesktopLyricService；通知栏桌面歌词按钮 → toggle）
  MediaNotificationService.initCallbacks();
  DesktopLyricService.instance.registerNativeCallbacks();
  // 恢复蓝牙歌词开关状态：让歌词服务定时器在需要时启动。
  // 原生端 AudioPlaybackService.onCreate 会自行从 SharedPreferences 恢复开关。
  try {
    final settings = SettingsRepository();
    final btLyricEnabled = await settings.getBluetoothLyricEnabled();
    await DesktopLyricService.instance.setBluetoothLyricEnabled(btLyricEnabled);
  } catch (_) {}
  // 注册 Lyricon 反向回调（连接状态变更 → UI 刷新）
  // initialize 内部仅 setMethodCallHandler，同步完成，无需 await
  LyriconProviderService.instance.initialize();
  // 权限请求包裹 try/catch：在部分设备/早期阶段 permission_handler 可能抛
  // "Unable to detect current Android Activity"，不能让它中断启动流程。
  try {
    await _requestPermissions();
  } catch (e) {
    print('Request permissions error (ignored): $e');
  }

  // 先启动本地 Node.js API 服务器，确保就绪后再运行 App
  // 否则发现页 post-frame callback 发出的请求会因服务器未启动而全部失败
  if (!kIsWeb && Platform.isAndroid) {
    try {
      await NodeJsServer.start();
    } catch (e) {
      print('Node.js server start error: $e');
    }
  }

  runApp(const MyApp());
}

Future<void> _requestPermissions() async {
  // Web 平台不支持 permission_handler，跳过所有权限请求
  if (kIsWeb) return;

  // Android 13+ 通知权限
  if (await Permission.notification.isDenied) {
    try {
      await Permission.notification.request();
    } catch (e) {
      print('Notification permission request failed: $e');
    }
  }
  // Android 14+ 媒体权限
  if (await Permission.audio.isDenied) {
    try {
      await Permission.audio.request();
    } catch (e) {
      print('Audio permission request failed: $e');
    }
  }
  // Android 11+ 管理外部存储权限：修改公共目录文件元数据（封面/歌词）需要
  if (await Permission.manageExternalStorage.isDenied) {
    try {
      await Permission.manageExternalStorage.request();
    } catch (e) {
      print('Manage external storage permission request failed: $e');
    }
  }
  // 忽略电池优化：只弹一次（不管用户选什么都标记为已弹）
  try {
    final prefs = await SharedPreferences.getInstance();
    final alreadyShown = prefs.getBool(_kBatteryPromptShownKey) ?? false;
    if (!alreadyShown) {
      if (await Permission.ignoreBatteryOptimizations.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }
      await prefs.setBool(_kBatteryPromptShownKey, true);
    }
  } catch (_) {}
}
