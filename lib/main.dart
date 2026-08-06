import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:async';
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

  // P0: 无依赖的初始化并行执行，替代串行 await，缩短 runApp 前的阻塞时间。
  // 同时预取 SharedPreferences（onboarding / 用户协议检查复用）。
  final prefsFuture = SharedPreferences.getInstance();
  await Future.wait([
    // 加载歌词字号/行间距偏好（从 SharedPreferences）
    LyricPreferences.instance.load(),
    // 加载 MD3 风格播放页的独立歌词偏好（与 Apple Music 风格完全分离）
    Md3LyricPreferences.instance.load(),
    // 恢复屏幕常亮开关状态，供 PlayerProvider/MV 页播放时读取
    WakelockService.instance.init().catchError((_) {}),
    // 初始化均衡器服务（恢复偏好设置，监听播放状态自动绑定）
    EqualizerService.instance.init().catchError((_) {}),
    // 恢复蓝牙歌词开关状态：让歌词服务定时器在需要时启动。
    // 原生端 AudioPlaybackService.onCreate 会自行从 SharedPreferences 恢复开关。
    _restoreBluetoothLyricPref(),
  ]);

  // 注册通知栏/悬浮窗回调（悬浮窗内按钮 → DesktopLyricService；通知栏桌面歌词按钮 → toggle）
  MediaNotificationService.initCallbacks();
  DesktopLyricService.instance.registerNativeCallbacks();
  // 注册 Lyricon 反向回调（连接状态变更 → UI 刷新）
  // initialize 内部仅 setMethodCallHandler，同步完成，无需 await
  LyriconProviderService.instance.initialize();

  // P0: 本地 API 服务器与 DLNA 本地 HTTP 服务器改为后台启动（不阻塞 runApp）。
  // 之前 await KugouApiServer.start() 在首帧前完成，其中
  // DynamicLibrary.open('libkugou_server.so')（dlopen，so 可达 10MB+）与
  // 服务器初始化可能耗时数秒 → 用户看到长时间启动画面/白屏。
  // 现在首帧立即渲染；发现页等首屏请求通过 KugouApiClient 的
  // serverReady 信号等待服务器就绪后再放行，不会因服务器未启动而失败。
  if (!kIsWeb && Platform.isAndroid) {
    unawaited(KugouApiServer.start().catchError((_) {}));
    unawaited(LocalHttpServer.instance.start().catchError((_) {}));
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
    final prefs = await prefsFuture;
    needsOnboarding = !(prefs.getBool('onboarding_completed') ?? false);
  } catch (_) {}

  // 检测是否需要展示用户协议（首次启动）
  final needsUserAgreement = !(await isUserAgreementAccepted());

  runApp(
    MyApp(
      showOnboarding: needsOnboarding,
      showUserAgreement: needsUserAgreement,
    ),
  );

  // P0: 权限请求推迟到首帧渲染后执行，避免冷启动期间的系统权限弹窗
  // 阻塞首屏绘制（部分设备上 permission_handler 可能耗时/弹窗）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // 权限请求包裹 try/catch：在部分设备/早期阶段 permission_handler 可能抛
    // "Unable to detect current Android Activity"，不能让它中断流程。
    try {
      _requestPermissions();
    } catch (e) {
      print('Request permissions error (ignored): $e');
    }
  });
}

/// 恢复蓝牙歌词开关：从 SettingsRepository 读取并同步到歌词服务。
Future<void> _restoreBluetoothLyricPref() async {
  try {
    final settings = SettingsRepository();
    final btLyricEnabled = await settings.getBluetoothLyricEnabled();
    await DesktopLyricService.instance.setBluetoothLyricEnabled(btLyricEnabled);
  } catch (_) {}
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
