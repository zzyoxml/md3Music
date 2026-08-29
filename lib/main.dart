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
import 'modules/recognition/floating_recognition_service.dart';
import 'core/services/equalizer_service.dart';
import 'core/services/local_http_server.dart';
import 'core/services/lyricon_provider_service.dart';
import 'core/services/listening_grade_service.dart';
import 'core/services/media_notification_service.dart';
import 'core/services/usb_audio_service.dart';
import 'core/services/wakelock_service.dart';
import 'data/repositories/settings_repository.dart';
import 'modules/onboarding/user_agreement_page.dart';
import 'services/kugou_server.dart';
import 'widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'widgets/md3_lyric_preferences.dart';

/// 顶级 Navigator 的 GlobalKey，预留供后续扩展使用。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 用于在 MyApp 启动前缓存「冷启动时通过 shortcut 触发」的类型。
/// QuickActions.initialize 在 runApp 之前注册回调，但此时 Navigator 还未就绪，
/// 因此把 shortcut 类型暂存到该字段，由 _AppView 在首帧处理后清空。
String? pendingShortcutType;

/// 用于通知 _MainLayout 切换到指定 tab（携带 tab id，而非写死索引）。
/// shortcut 入口按 tab id 解析实际索引：tab 可见则切主 tab，被隐藏则以
/// 二级页面打开（避免依赖固定索引导致 tab 排序/隐藏后跳错）。
/// _MainLayout 在 initState 中监听此 notifier，收到非 null 值后处理并清空。
final ValueNotifier<String?> shortcutTabRequest = ValueNotifier<String?>(null);

Future<void> main() async {
  final (needsOnboarding, needsUserAgreement) = await runBootstrap();

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
      requestPermissions();
    } catch (e) {
      print('Request permissions error (ignored): $e');
    }
  });
}

/// 启动引导：并行初始化无依赖服务、恢复偏好、预取 SharedPreferences。
/// 返回 `(needsOnboarding, needsUserAgreement)`。
/// 公开入口（main）与私有入口（lib/private/main_private）复用同一流程，
/// 私有入口在此基础上安装扩展钩子后 runApp。
Future<(bool, bool)> runBootstrap() async {
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
    // 恢复蓝牙歌词开关 + 实时歌词推送协议（Lyricon/SuperLyric/LyricInfo 三选一）：
    // 让歌词服务定时器在需要时启动、启用选中协议。
    // 原生端 AudioPlaybackService.onCreate 会自行从 SharedPreferences 恢复开关。
    _restoreLyricPushPref(),
  ]);

  // 注册通知栏/悬浮窗回调（悬浮窗内按钮 → DesktopLyricService；通知栏桌面歌词按钮 → toggle）
  MediaNotificationService.initCallbacks();
  DesktopLyricService.instance.registerNativeCallbacks();
  // 注册悬浮窗识曲原生回调（PCM 段回传 / MediaProjection 授权结果 / 悬浮窗按钮动作）
  FloatingRecognitionService.instance.registerNativeCallbacks();
  // 注册 Lyricon 反向回调（连接状态变更 → UI 刷新）
  // initialize 内部仅 setMethodCallHandler，同步完成，无需 await
  LyriconProviderService.instance.initialize();
  // 启动 USB 独占输出状态轮询（设置页/歌曲信息页共用实时状态）
  if (!kIsWeb && Platform.isAndroid) {
    UsbAudioService.instance.init();
  }

  // 启动听歌等级：本地听歌时长累计 + 自动上报（内部按平台/登录态自行处理）
  ListeningGradeService.instance.init();

  // P0: 本地 API 服务器与 DLNA 本地 HTTP 服务器改为后台启动（不阻塞 runApp）。
  // 之前 await KugouApiServer.start() 在首帧前完成，其中
  // DynamicLibrary.open('libkugou_server.so')（dlopen，so 可达 10MB+）与
  // 服务器初始化可能耗时数秒 → 用户看到长时间启动画面/白屏。
  // 现在首帧立即渲染；发现页等首屏请求通过 KugouApiClient 的
  // serverReady 信号等待服务器就绪后再放行，不会因服务器未启动而失败。
  // 桌面与 Android 都启动本地服务器（桌面走 dart:ffi 加载 kugou_server.dll）。
  if (!kIsWeb) {
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

  return (needsOnboarding, needsUserAgreement);
}

/// 恢复蓝牙歌词开关 + 实时歌词推送协议（Lyricon/SuperLyric/LyricInfo 三选一 + 关闭）。
/// 从 SettingsRepository 读取协议与共用偏好，启用选中协议、禁用其他，并同步偏好。
Future<void> _restoreLyricPushPref() async {
  try {
    final settings = SettingsRepository();
    // 逐字歌词时间偏移：加载到内存缓存（播放页每帧读取），默认 0
    await settings.getLyricTimeOffset();

    // 蓝牙歌词（独立开关）
    final btLyricEnabled = await settings.getBluetoothLyricEnabled();
    await DesktopLyricService.instance.setBluetoothLyricEnabled(btLyricEnabled);

    // 锁屏歌词（独立开关）：开启后歌词服务定时器运行以推送逐字数据
    final lockScreenLyricEnabled = await settings.getLockScreenLyricEnabled();
    // ignore: discarded_futures
    DesktopLyricService.instance.setLockScreenLyricEnabled(lockScreenLyricEnabled);

    // 锁屏歌词独立字体（字号/粗细，默认跟随 AM 歌词偏好）
    final lockScreenLyricFontSize = await settings.getLockScreenLyricFontSize();
    DesktopLyricService.instance.setLockScreenLyricFontSize(lockScreenLyricFontSize);
    final lockScreenLyricFontWeight = await settings.getLockScreenLyricFontWeight();
    DesktopLyricService.instance.setLockScreenLyricFontWeight(lockScreenLyricFontWeight);

    // 实时歌词推送协议
    final protocol = await settings.getLyricPushProtocol();
    final translation = await settings.getLyricPushTranslation();
    final roma = await settings.getLyricPushRoma();
    final preferTranslation = await settings.getLyricPushPreferTranslation();
    // 记录各协议 enabled key（兼容 Kotlin restoreLyricon 读 lyricon_enabled）
    await settings.setLyriconEnabled(protocol == 'lyricon');
    await settings.setSuperLyricEnabled(protocol == 'super_lyric');
    await settings.setLyricInfoEnabled(protocol == 'lyric_info');
    // 应用共用偏好
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricPushPreferences(
      translation: translation,
      roma: roma,
      preferTranslation: preferTranslation,
    );
    // 启用选中协议
    if (protocol == 'lyricon') {
      try {
        await LyriconProviderService.instance.setDisplayTranslation(translation);
        await LyriconProviderService.instance.setDisplayRoma(roma);
        await LyriconProviderService.instance.setEnabled(true);
      } catch (_) {}
    } else if (protocol == 'super_lyric') {
      // ignore: discarded_futures
      DesktopLyricService.instance.setSuperLyricEnabled(true);
    } else if (protocol == 'lyric_info') {
      // ignore: discarded_futures
      await DesktopLyricService.instance.setLyricInfoEnabled(true);
    }
  } catch (_) {}
}

/// 根据 shortcut 类型路由到对应页面。
/// 通过全局 [appNavigatorKey] 获取 NavigatorState，避免依赖具体 BuildContext。
///
/// 快捷方式类型统一为 `action_open_<tabId>`（与现有
/// action_open_favorites/recognition/search 兼容）。这里只把 tab id 交给
/// _MainLayout，由它按当前 tab 配置解析：可见 → 切主 tab；隐藏 → 二级页打开。
void handleShortcut(String shortcutType) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  if (!shortcutType.startsWith('action_open_')) return;
  final tabId = shortcutType.substring('action_open_'.length);
  if (tabId.isEmpty) return;
  shortcutTabRequest.value = tabId;
}

/// 请求运行时权限（通知 / 媒体 / 管理外部存储）。
/// 公开入口与私有入口共用；私有入口的下载功能依赖其中的存储权限。
Future<void> requestPermissions() async {
  // Web 平台不支持 permission_handler，跳过所有权限请求
  if (kIsWeb) return;
  // 桌面端无 Android 专属权限，跳过（permission_handler 桌面语义不同）
  if (!Platform.isAndroid) return;

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
}
