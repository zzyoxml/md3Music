import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/services/desktop_lyric_service.dart';
import 'core/services/equalizer_service.dart';
import 'core/services/local_http_server.dart';
import 'core/services/lyricon_provider_service.dart';
import 'core/services/media_notification_service.dart';
import 'core/services/wakelock_service.dart';
import 'data/repositories/settings_repository.dart';
import 'modules/onboarding/user_agreement_page.dart';
import 'modules/recognition/song_recognition_page.dart';
import 'modules/search/search_page.dart';
import 'services/kugou_server.dart';
import 'widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'widgets/md3_lyric_preferences.dart';

const String _kBatteryPromptShownKey = 'battery_prompt_shown';

/// 顶级 Navigator 的 GlobalKey，预留供后续扩展使用。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 用于在 MyApp 启动前缓存「冷启动时通过 shortcut 触发」的类型。
/// QuickActions.initialize 在 runApp 之前注册回调，但此时 Navigator 还未就绪，
/// 因此把 shortcut 类型暂存到该字段，由 _AppView 在首帧处理后清空。
String? pendingShortcutType;

/// 用于通知 _MainLayout 切换底部 tab。
/// shortcut 入口「我的收藏」需要切换到主页第 3 个 tab（index=2），
/// 而非 push 一个新的 FavoritesPage 路由（避免页面重复）。
/// _MainLayout 在 initState 中监听此 notifier，收到非 null 值后切换 tab 并清空。
final ValueNotifier<int?> shortcutTabRequest = ValueNotifier<int?>(null);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  // 加载歌词字号/行间距偏好（从 SharedPreferences）
  await LyricPreferences.instance.load();
  // 加载 MD3 风格播放页的独立歌词偏好（与 Apple Music 风格完全分离）
  await Md3LyricPreferences.instance.load();
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
  // 恢复屏幕常亮开关状态，供 PlayerProvider/MV 页播放时读取
  try {
    await WakelockService.instance.init();
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

  // 先启动本地 API 服务器，确保就绪后再运行 App
  // 否则发现页 post-frame callback 发出的请求会因服务器未启动而全部失败
  if (!kIsWeb && Platform.isAndroid) {
    try {
      await KugouApiServer.start();
    } catch (e) {
      print('API server start error: $e');
    }
    // 启动本地 HTTP 服务器，供 DLNA 投屏本地音乐
    // 失败不阻塞启动流程，投屏时若未启动会提示用户重启 App
    try {
      await LocalHttpServer.instance.start();
    } catch (e) {
      print('Local HTTP server start error: $e');
    }
  }

  // 注册 Android 长按应用图标 Shortcut 回调。
  // initialize 必须在 runApp 之前调用，以便冷启动时能接收到 shortcut 触发。
  if (!kIsWeb && Platform.isAndroid) {
    const quickActions = QuickActions();
    quickActions.initialize((shortcutType) {
      // 应用已就绪时直接处理；否则暂存，由 _AppView 在首帧处理
      if (appNavigatorKey.currentContext != null) {
        handleShortcut(shortcutType);
      } else {
        pendingShortcutType = shortcutType;
      }
    });
  }

  // 检测是否需要显示首次启动引导页（仅新安装/未完成教程时弹出）
  bool needsOnboarding = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    needsOnboarding = !(prefs.getBool('onboarding_completed') ?? false);
  } catch (_) {}

  // 检测是否需要展示用户协议（首次启动）
  final needsUserAgreement = !(await isUserAgreementAccepted());

  // 初始化均衡器服务（恢复偏好设置，监听播放状态自动绑定）
  await EqualizerService.instance.init();

  runApp(
    MyApp(
      showOnboarding: needsOnboarding,
      showUserAgreement: needsUserAgreement,
    ),
  );
}

/// 根据 shortcut 类型路由到对应页面。
/// 通过全局 [appNavigatorKey] 获取 NavigatorState，避免依赖具体 BuildContext。
void handleShortcut(String shortcutType) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  switch (shortcutType) {
    case 'action_open_favorites':
      // 切换到主页底部 tab index=2（我的收藏），而非 push 新路由
      shortcutTabRequest.value = 2;
      break;
    case 'action_open_recognition':
      nav.push(MaterialPageRoute(builder: (_) => const SongRecognitionPage()));
      break;
    case 'action_open_search':
      nav.push(MaterialPageRoute(builder: (_) => const SearchPage()));
      break;
  }
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
