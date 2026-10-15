import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/build_flags.dart';
import 'core/remote/tv_focus_debug.dart';
import 'core/layout/responsive_layout.dart';
import 'core/utils/app_haptics.dart';
import 'core/services/desktop_lyric_service.dart';
import 'core/services/diagnostic_logger.dart';
import 'modules/recognition/floating_recognition_service.dart';
import 'core/services/equalizer_service.dart';
import 'core/services/viper_master_service.dart';
import 'core/services/lyricon_provider_service.dart';
import 'core/services/listening_grade_service.dart';
import 'core/services/listen_report_service.dart';
import 'core/services/media_notification_service.dart';
import 'core/services/music_haptics_service.dart';
import 'core/services/play_history_sync_service.dart';
import 'core/services/usb_audio_service.dart';
import 'core/services/wakelock_service.dart';
import 'data/repositories/settings_repository.dart';
import 'providers/theme_provider.dart';
import 'modules/update/update_check_service.dart';
import 'modules/onboarding/onboarding_content.dart' show kOnboardingCompletedKey;
import 'modules/onboarding/user_agreement_page.dart';
import 'services/kugou_server.dart';
import 'utils/landscape_immersive.dart';
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
  // Zone 级兜底：任何未被 try/catch 与错误钩子接住的异步错误都记入诊断日志
  runZonedGuarded(_main, (error, stack) {
    DiagnosticLogger.instance.e('Zone 未捕获错误: $error\n$stack');
  });
}

Future<void> _main() async {
  final (
    needsOnboarding,
    needsUserAgreement,
    initialUseBackgroundImage,
  ) = await runBootstrap();

  runApp(
    MyApp(
      showOnboarding: needsOnboarding,
      showUserAgreement: needsUserAgreement,
      initialUseBackgroundImage: initialUseBackgroundImage,
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
/// 返回 onboarding / 用户协议状态，以及首帧使用的背景图开关值。
/// 公开入口（main）与私有入口（lib/private/main_private）复用同一流程，
/// 私有入口在此基础上安装扩展钩子后 runApp。
Future<(bool, bool, bool)> runBootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  final startupClock = Stopwatch()..start();
  void markStartup(String phase) {
    final elapsedMs = startupClock.elapsedMilliseconds;
    final message = '[Startup] phase=$phase elapsed_ms=$elapsedMs';
    DiagnosticLogger.instance.i(message);
    // 启动阶段日志便于设备采样时区分 Dart bootstrap 与原生窗口首显；
    // 仅包含阶段名和耗时，不输出偏好值、端口或请求信息。
    debugPrint(message);
    if (phase == 'first_frame') {
      debugPrint('[StartupFrame] elapsed_ms=$elapsedMs');
    }
  }

  // 诊断日志尽早初始化（滚动文件 + 全局错误钩子），保证启动期异常也被记录。
  // 内部自带失败兜底，不会中断启动。
  await DiagnosticLogger.instance.init();
  markStartup('diagnostics_ready');
  // 在runBootstrap注册，公开与私有入口都可记录真正的首帧时间。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    markStartup('first_frame');
  });

  // 全局 ErrorWidget 兜底：release 版默认 ErrorWidget 是纯灰块，横竖屏切换时
  // 某个 widget 构建异常会让整屏变纯灰且无任何线索（问题③）。改为可读占位
  // （非灰、带图标与提示），并把异常写入诊断日志，便于 adb logcat / 导出定位。
  // 双入口（main / main_private）共用 runBootstrap，一处生效两端。
  ErrorWidget.builder = (FlutterErrorDetails details) {
    DiagnosticLogger.instance.e(
      'ErrorWidget: ${details.exceptionAsString()}\n${details.stack}',
    );
    return _FallbackErrorWidget(details: details);
  };

  await initializeDateFormatting('zh_CN');
  markStartup('date_format_ready');

  // P0: 无依赖的初始化并行执行，替代串行 await，缩短 runApp 前的阻塞时间。
  // 同时预取 SharedPreferences（onboarding / 用户协议检查复用）。
  final prefsFuture = SharedPreferences.getInstance();
  await Future.wait([
    // 加载歌词字号/行间距偏好（从 SharedPreferences）
    LyricPreferences.instance.load(),
    // 加载 MD3 风格播放页的独立歌词偏好（与 Apple Music 风格完全分离）
    Md3LyricPreferences.instance.load(),
    // 恢复震动反馈总开关与类别开关：全站震动点都在 AppHaptics 内闸门，
    // 首帧前就位才不会让刚进来的用户感到开关状态失真。
    AppHaptics.load().catchError((_) {}),
    // 音乐节奏震动：恢复偏好并开始订阅频谱特征流。
    // 内部自建五重闸门（自身开关 / 全站震动总开关 / 非模拟频谱 / 特征新鲜 / 原生可用），
    // 默认关闭，故这里无条件启动是安全的：不开开关就一个震动也不发。
    MusicHapticsService.instance.load().catchError((_) {}),
    // 恢复屏幕常亮开关状态，供 PlayerProvider/MV 页播放时读取
    WakelockService.instance.init().catchError((_) {}),
    // 初始化均衡器服务（恢复偏好设置，监听播放状态自动绑定）
    EqualizerService.instance.init().catchError((_) {}),
    // 初始化蝰蛇母带服务（恢复开关与 10 段增益并推送原生处理链）
    ViperMasterService.instance.init().catchError((_) {}),
    // 恢复蓝牙歌词开关 + 实时歌词推送协议（Lyricon/SuperLyric/LyricInfo 三选一）：
    // 让歌词服务定时器在需要时启动、启用选中协议。
    // 原生端 AudioPlaybackService.onCreate 会自行从 SharedPreferences 恢复开关。
    _restoreLyricPushPref(),
    // 恢复全屏播放器横屏沉浸开关（全局变量，播放器同步读取）
    _restoreLandscapeImmersivePref(),
    // 预热频谱「圆盘是否生效」同步镜像（全局变量）。
    // 必须在 runApp 前：迷你条上滑展开时跟手覆盖层是当场新建的播放页，
    // 其封面连贯资格在第一帧就要读到真值，等不及各播放页自己的异步读取。
    _restoreSpectrumCoverPref(),
  ]);
  markStartup('local_preferences_ready');

  // 注册通知栏/悬浮窗回调（悬浮窗内按钮 → DesktopLyricService；通知栏桌面歌词按钮 → toggle）
  MediaNotificationService.initCallbacks();
  DesktopLyricService.instance.registerNativeCallbacks();
  // 注册悬浮窗识曲原生回调（PCM 段回传 / MediaProjection 授权结果 / 悬浮窗按钮动作）
  FloatingRecognitionService.instance.registerNativeCallbacks();
  // 注册 Lyricon 反向回调（连接状态变更 → UI 刷新）
  // TV 版不编入：无蓝牙歌词屏场景
  if (!kTvBuild) {
    LyriconProviderService.instance.initialize();
  } else {
    // TV：安装焦点诊断日志（仅 debug 构建实际生效，release 随 kDebugMode 树摇剔除）。
    TvFocusDebug.install();
  }
  // 启动 USB 独占输出状态轮询（设置页/歌曲信息页共用实时状态）
  if (!kIsWeb && Platform.isAndroid) {
    UsbAudioService.instance.init();
  }

  // 启动听歌等级：本地听歌时长累计 + 自动上报（内部按平台/登录态自行处理）
  ListeningGradeService.instance.init();
  // CSCC 真实播放事件上报（/user/listen/report）：由 PlayerProvider 在切歌/播放
  // 边沿驱动，开关复用 settings_upload_listening_duration（「听歌数据云同步」）。
  ListenReportService.instance.init();
  // 云端播放历史上传（/playhistory/upload）：与 CSCC 同一切歌边沿驱动，
  // 同一开关总控；启动时补传上次失败的 pending 队列。
  PlayHistorySyncService.instance.init();

  // P0: 本地 API 服务器与 DLNA 本地 HTTP 服务器改为后台启动（不阻塞 runApp）。
  // 之前 await KugouApiServer.start() 在首帧前完成，其中
  // DynamicLibrary.open('libkugou_server.so')（dlopen，so 可达 10MB+）与
  // 服务器初始化可能耗时数秒 → 用户看到长时间启动画面/白屏。
  // 现在首帧立即渲染；发现页等首屏请求通过 KugouApiClient 的
  // 按本地服务启动代次等待ready；启动失败或停止时请求快速失败，不触碰旧端口。
  // 桌面与 Android 都启动本地服务器（桌面走 dart:ffi 加载 kugou_server.dll）。
  // LocalHttpServer（DLNA 拉流）不再无条件启动：仅投屏本地歌曲时由
  // DlnaProvider.castSong 懒启动，避免 App 常驻一个局域网监听 socket。
  if (!kIsWeb) {
    final serverClock = Stopwatch()..start();
    unawaited(
      KugouApiServer.start()
          .then((_) {
            DiagnosticLogger.instance.i(
              '[Startup] phase=api_ready elapsed_ms=${startupClock.elapsedMilliseconds} '
              'server_ms=${serverClock.elapsedMilliseconds}',
            );
          })
          .catchError((Object error) {
            DiagnosticLogger.instance.e(
              '[Startup] phase=api_failed elapsed_ms=${startupClock.elapsedMilliseconds} '
              'server_ms=${serverClock.elapsedMilliseconds} '
              'error_type=${error.runtimeType}',
            );
          }),
    );
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
  var initialUseBackgroundImage = true;
  try {
    final prefs = await prefsFuture;
    needsOnboarding = !(prefs.getBool(kOnboardingCompletedKey) ?? false);
    initialUseBackgroundImage =
        prefs.getBool(ThemeProvider.backgroundImageEnabledPreferenceKey) ??
            true;
    // TV 构建强制关悬浮形态、首帧即常驻条（悬浮条本体无 DpadFocusable 停点，
    // 见 app.dart _loadSecondaryPlayerEnabled 同一门控）；只门控播种值，
    // 不回写 prefs——切回手机版不丢用户设置。
    kSecondaryPlayerEnabled.value = kTvBuild
        ? false
        : prefs.getBool(
              SettingsRepository.secondaryPlayerEnabledPreferenceKey,
            ) ??
            false;
    kSecondaryPlayerProgressEnabled.value =
        prefs.getBool(
              SettingsRepository.secondaryPlayerProgressPreferenceKey,
            ) ??
            true;
    kSecondaryPlayerOnPrimaryPages.value =
        prefs.getBool(
              SettingsRepository.secondaryPlayerOnPrimaryPreferenceKey,
            ) ??
            true;
    kHideNavBarOnSecondaryPages.value =
        prefs.getBool(SettingsRepository.hideNavBarOnSecondaryPreferenceKey) ??
            true;
    // 桌面外壳开关：不播种则首帧是手机导航壳、app.dart 异步载入后整树跳成
    // 侧栏（M5）。默认 false，与 SettingsRepository.getDesktopModeEnabled 及
    // kDesktopModeEnabled 初值三处一致。
    kDesktopModeEnabled.value =
        prefs.getBool(SettingsRepository.desktopModeEnabledPreferenceKey) ??
            false;
  } catch (_) {}
  markStartup('onboarding_state_ready');

  // 检测是否需要展示用户协议（首次启动）
  final needsUserAgreement = !(await isUserAgreementAccepted());
  markStartup('agreement_state_ready');

  // 启动后静默检查 GitHub Release：发现新版本仅 toast 提醒。
  // 首次启动引导 / 用户协议未确认时抑制，避免与首启流程争夺注意力。
  // 内部仅在 Android 生效、延迟 8s 后执行、12 小时内不重复请求；可在设置中关闭。
  UpdateCheckService.instance.scheduleStartupCheck(
    suppress: needsOnboarding || needsUserAgreement,
  );

  markStartup('bootstrap_ready');
  return (needsOnboarding, needsUserAgreement, initialUseBackgroundImage);
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

    // 锁屏歌词（独立开关）：开启后歌词服务定时器运行以推送整首歌词
    // （样式全部跟随 AM 歌词偏好，与播放页 Zen 沉浸模式一致）
    final lockScreenLyricEnabled = await settings.getLockScreenLyricEnabled();
    // ignore: discarded_futures
    DesktopLyricService.instance.setLockScreenLyricEnabled(
      lockScreenLyricEnabled,
    );

    // 魅族 Flyme 状态栏歌词（独立开关）：冷启动/后台唤醒后无需进设置页即可继续推送
    // 顺序有讲究：先灌提前量再开开关。开启会立刻回灌当前行，
    // 若此时提前量还是 0，第一行就按未提前的时间轴显示，要等到下次翻行才对。
    final flymeAdvance = await settings.getFlymeLyricAdvanceMs();
    // ignore: discarded_futures
    DesktopLyricService.instance.setFlymeAdvanceMs(flymeAdvance);
    final flymeLyricEnabled = await settings.getFlymeStatusBarLyricEnabled();
    // ignore: discarded_futures
    DesktopLyricService.instance.setFlymeStatusBarLyricEnabled(flymeLyricEnabled);

    // 实时歌词推送协议（TV 版不编入：无蓝牙歌词屏/系统歌词桥/车机歌词场景）
    if (!kTvBuild) {
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
          await LyriconProviderService.instance.setDisplayTranslation(
            translation,
          );
          await LyriconProviderService.instance.setDisplayRoma(roma);
          await LyriconProviderService.instance.setEnabled(true);
        } catch (_) {}
      } else if (protocol == 'super_lyric') {
        // ignore: discarded_futures
        DesktopLyricService.instance.setSuperLyricEnabled(true);
      } else if (protocol == 'lyric_info') {
        // 先恢复 ColorOS Bridge 兼容模式，再启用推送（避免首推旧格式）
        final colorOs = await settings.getLyricInfoColorOs();
        // ignore: discarded_futures
        DesktopLyricService.instance.setLyricInfoColorOs(colorOs);
        // ignore: discarded_futures
        await DesktopLyricService.instance.setLyricInfoEnabled(true);
      }
      // MD3Music fork: lyricInfo 推送无条件启用（Vivo 车载歌词依赖此链路：extras LYRICS_WHOLE
      // + 原子随身听 lrc_change）。协议开关只控制 lyricon/super_lyric 等展示通道；
      // 此前受开关控制 + 覆盖安装残留旧设置（lyric_push_protocol='none'）导致链路关闭，
      // 原子随身听缺 8/16 能力位（无歌词无进度条）、车机无歌词。
      // ignore: discarded_futures
      DesktopLyricService.instance.setLyricInfoEnabled(true);
    }
  } catch (_) {}
}

/// 恢复「全屏播放器横屏隐藏状态栏」开关到全局变量（默认开启）。
/// 必须在 runApp 前完成：播放器 didChangeDependencies 首次应用系统栏时同步读取该变量。
Future<void> _restoreLandscapeImmersivePref() async {
  try {
    kLandscapeImmersiveEnabled = await SettingsRepository()
        .getLandscapeImmersiveEnabled();
  } catch (_) {}
}

/// 预热频谱「圆盘（style 0/1）是否生效」同步镜像。
/// 两个 getter 各自维护镜像里的一个字段（开关 / 样式），少任何一个都不成立，
/// 故这里**必须两个都读**，不能只读开关。
Future<void> _restoreSpectrumCoverPref() async {
  try {
    final settings = SettingsRepository();
    await Future.wait([
      settings.getSpectrumEnabled(),
      settings.getSpectrumStyle(),
    ]);
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

/// 请求启动后立即需要的运行时权限（通知）。
/// 音频库权限在用户打开本地曲库时按需请求；下载默认使用应用专属目录。
///
/// 通知权限不能不请求：播放通知由原生 `AudioPlaybackService`
/// （manifest 里 foregroundServiceType="mediaPlayback"）承载，Android 13+ 被拒
/// 就没有锁屏 / 通知栏播控。但也不该在冷启动第一屏就问——用户还没看到任何价值。
/// 因此这里闸门在「首启流程走完」之后：首帧后与两个完成点（用户协议已同意 /
/// 引导页已完成）都会调用本函数，闸门未过时直接返回，整体保持幂等且不阻塞启动。
Future<void> requestPermissions() async {
  // Web 平台不支持 permission_handler，跳过所有权限请求
  if (kIsWeb) return;
  // 桌面端无 Android 专属权限，跳过（permission_handler 桌面语义不同）
  if (!Platform.isAndroid) return;
  if (!await _isFirstLaunchFlowFinished()) return;

  // Android 13+ 通知权限
  if (await Permission.notification.isDenied) {
    try {
      await Permission.notification.request();
    } catch (e) {
      print('Notification permission request failed: $e');
    }
  }
}

/// 首启流程（用户协议 + 引导页）是否已走完。
/// 读不到偏好时按「已走完」处理：宁可退回改动前的行为照常请求，
/// 也不能因一次 prefs 异常让用户永久丢掉通知权限（= 丢掉锁屏播控）。
Future<bool> _isFirstLaunchFlowFinished() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final onboardingDone = prefs.getBool(kOnboardingCompletedKey) ?? false;
    return onboardingDone && await isUserAgreementAccepted();
  } catch (_) {
    return true;
  }
}

/// 全局 ErrorWidget 兜底占位（替代 release 默认的纯灰块）。
///
/// 仅在某个 widget 构建/布局抛异常时由 [ErrorWidget.builder] 使用；
/// 用中性可读外观（surface 背景 + 图标 + 简短提示）替代整屏纯灰，
/// 让用户知道是局部错误而非崩溃，同时异常已写入 [DiagnosticLogger]。
/// 无 MaterialApp 上下文时也能独立渲染（用 Directionality + 直接取色），
/// 因为它可能在 widget 树任意位置替换出错子树。
class _FallbackErrorWidget extends StatelessWidget {
  const _FallbackErrorWidget({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    // 尽量取当前主题色；拿不到时回退到中性深灰（仍非纯灰全屏）。
    //
    // 此处用 findAncestorWidgetOfExactType 而非 Theme.of：本仓库依赖的
    // material_ui 未提供 Theme.maybeOf（只有 of/brightnessOf/maybeBrightnessOf），
    // 而 Theme.of 在无 Theme 祖先时会回退到 ThemeData.fallback()（浅色），与下方
    // 「中性深灰」意图相反。MaterialApp 无论是否走 AnimatedTheme，最终都会构建
    // Theme widget，故这里能取到与 Theme.maybeOf 等价的 ThemeData，无祖先时为 null。
    final theme = context.findAncestorWidgetOfExactType<Theme>()?.data;
    final bg = theme?.colorScheme.surface ?? const Color(0xFF1C1B1F);
    final fg = theme?.colorScheme.onSurfaceVariant ?? const Color(0xFFCAC4D0);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 40, color: fg),
            const SizedBox(height: 12),
            Text(
              '此处内容加载出错',
              textAlign: TextAlign.center,
              style: TextStyle(color: fg, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
