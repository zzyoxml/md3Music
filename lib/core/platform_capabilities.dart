import 'dart:io';

import 'package:flutter/foundation.dart';

import 'build_flags.dart';

/// 平台能力门控：区分「Android 专属」与「桌面端也有」的 UI 入口。
///
/// **为什么不用 `kTvBuild`**（`lib/core/build_flags.dart`）：那组是编译期 const
/// （`--dart-define`），AOT 可树摇；本文件判断的是**运行时**平台，
/// 同一份 Windows 包里既要走桌面分支、又要能识别 Android 分支，
/// 因此必须是普通 getter。
///
/// **为什么不直接散落 `Platform.isAndroid`**：Android 专属入口有 20+ 处，
/// 散落后每新增一处都要重新判断"这个功能在桌面端行不行"。集中到这里后：
/// - 新增平台只需改这一个文件；
/// - 搜索 `supportsXxx` 就能列出全部平台相关入口，不会漏。
///
/// 用 `defaultTargetPlatform` 而非 `Platform.isAndroid`：Web 编译期
/// `dart:io` 不可用，`Platform.*` 会抛 UnsupportedError。
bool get isAndroidPlatform {
  if (kIsWeb) return false;
  if (Platform.isAndroid) return true;
  return defaultTargetPlatform == TargetPlatform.android;
}

/// 当前是否桌面端（Windows / macOS / Linux）。用于"桌面端额外能力"的
/// 正向判断（例如 Windows 才有原生消息框兜底）。
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return true;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// 当前是否 Windows 桌面 —— 键鼠快捷键与窗口原生能力的唯一门控源。
///
/// **为什么不复用 [isDesktopPlatform]**：桌面能力里有两拨 —— 「mac/Linux 也成立」
/// 的（原生消息框兜底）和「只有本仓库的 Windows runner 实现了」的（无边框全屏、
/// F11、空格/F/Esc/鼠标侧键）。后者混进 `isDesktopPlatform` 会在 mac/linux 上
/// 留下按了没反应的死键位。
///
/// 口径用 `defaultTargetPlatform`，不用 `Platform.isWindows`：后者在 Windows 宿主
/// 上跑 `flutter test` 同样为 true，会把宿主平台泄漏进本该跑 Android 语义的测试
/// （`core/utils/app_toast.dart`、`WindowsFullscreen.supported` 同一教训）。
bool get isWindowsDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows;
}

/// ---- Android 专属功能入口 ----
///
/// 每一项对应设置页里一个只在 Android 上成立的入口。桌面端必须隐藏，
/// 否则用户会点进一个永远不生效的页面（历史上已多次出现：
/// 点"USB 独占"却提示"未检测到 USB 音频设备"，完全是死路）。

/// USB 独占输出（UAC1 DAC 直写 usbdevfs，需 Android USB Host + native cpp）。
///
/// **TV 构建同样视为不支持**：tv flavor 置 `FEATURE_TV=true`，既不编译 USB 独占
/// C++ 驱动，也在 `MainActivity.registerPlaybackPlugins` 里跳过
/// `UsbAudioPlugin` / `DirectPcmPlugin` 注册（见 android/app/build.gradle.kts）。
/// 若只判平台，TV 会露出一个点不动的「USB 独占」分类与歌曲信息页死区块。
/// `kTvBuild` 是 const，TV 包内本表达式可被树摇折叠。
bool get supportsUsbExclusive => isAndroidPlatform && !kTvBuild;

/// 听歌识曲：Android 走 `record` 的 unprocessed 采集，
/// Windows 走 `record_windows`（MediaFoundation）+ 本地 Rust PCM 前处理；
/// 两者共用同一套指纹链路（`/audio/match`），故桌面端只放行 Windows。
bool get supportsSongRecognition => isAndroidPlatform || isWindowsDesktop;

/// 悬浮窗识曲：依赖 Android 悬浮窗权限 + MediaProjection 授权，只有 Android 有。
/// 桌面端页面必须隐藏该入口（点了就是死路）。
bool get supportsFloatingSongRecognition => isAndroidPlatform;

/// 预测性手势（横滑切歌 / 长按识别等，依赖 Android 系统的
/// `MotionEvent` 手势与振动反馈配合）。
bool get supportsPredictiveGesture => isAndroidPlatform;

/// 音乐频谱：Android 走 PCM 截取 / Visualizer 兜底，Windows 走 WASAPI 环回采集。
///
/// 两端共用同一条通道协议（`onFft` 40 段归一化幅值），差异只在原生数据源：
/// - Android：`SpectrumPlugin` 从 AudioSink 截 PCM，或挂 `Visualizer`；
/// - Windows：runner 的 `SpectrumCapture` 环回本进程音频（Win10 老版本回落到
///   系统混音）后做同款 1024 点 FFT。
bool get supportsMusicSpectrum => isAndroidPlatform || isWindowsDesktop;

/// 震动反馈（Android `Vibrator` / 鼓点节奏震动）。
bool get supportsHaptics => isAndroidPlatform;

/// 桌面快捷方式（Android 应用图标长按快捷入口，由
/// `ShortcutConfigProvider` + `quick_actions_android` 支撑）。
bool get supportsDesktopShortcut => isAndroidPlatform;

/// 系统音效链（均衡器 / 音效库 / 音量均衡 / 响度归一）。
///
/// 根���在 `EqualizerService`：它靠 `AudioSession` + `androidAudioSessionIds`
/// 绑定原生 `android.media.audiofx.Equalizer`。桌面端**没有任何等价实现**，
/// `tryBind()` 在非 Android 直接 `return false`。
///
/// ⚠️ 危险之处：**它不会报错**。`setEnabled(true)` 照样返回成功、
/// 持久化也照样写入，但 `tryBind()` 早已return false ⇒ 没有任何音效被挂载。
/// 用户看到"已开启"却听不出变化，是典型的假成功。必须隐藏入口。
bool get supportsSystemAudioEffects => isAndroidPlatform;

/// 硬件解码播放（系统 audio offload 直通）。
///
/// 依赖 Media3 audio offload + API29（`Build.VERSION.SDK_INT >= 29`）协商，
/// 仅 Android：桌面端 / Web 没有 `AudioTrack` offload 通路，必须隐藏入口。
bool get supportsAudioOffload => isAndroidPlatform;

/// 蝰蛇母带处理链（10 段均衡 + 限幅，母带级处理）。
///
/// 字幕已自述"仅 Android"；依赖 Android 端 `LoudnessEnhancer` /
/// `DynamicsProcessing` 等音频特效 API，关闭时输出逐字节透传。
bool get supportsViperMaster => isAndroidPlatform;

/// 音量均衡 / 参考响度（ReLU / 目标 dB 归一）。
///
/// 同样挂在 `EqualizerService` 的音效链上，桌面端一并失效。
bool get supportsLoudnessNormalization => isAndroidPlatform;

/// 应用内 WebView（`webview_flutter`）。
///
/// **只有 Android/iOS 有平台实现**：Windows 端插件注册表里没有 webview
/// （见 `windows/flutter/ephemeral/.plugin_symlinks/`），`WebViewController()`
/// 会抛 MissingPluginException，整块 UI 被全局 ErrorWidget（"此处内容加载出错"）
/// 替换 —— 曲谱详情页（酷狗 H5 谱面渲染）已踩坑。桌面端调用方必须降级
/// （如用 url_launcher 打开系统浏览器），TV 构建同样视为不支持。
bool get supportsInAppWebView => isAndroidPlatform && !kTvBuild;

/// 小米 CarWith（车机互联）：连接判据（CarWith 虚拟屏 + `ucar_night_mode`）
/// 全部来自小米/MIUI 原生接口，只有 Android 存在该通道。
///
/// **为什么不在这里判 TV**：CarWith 的连接判据在原生侧是「虚拟屏是否存在」，
/// TV 盒子上永远没有这块屏，读数恒为未连接；把 TV 排除在门外反而会让设置页
/// 在投屏类设备上少一个入口，交给原生读数说话即可（读数失败一律按未连接，
/// 行为与不显示该开关等价）。桌面端隐藏入口的原因同 [supportsFloatingSongRecognition]：
/// 点了就是一个永远不生效的死开关。
bool get supportsCarWith => isAndroidPlatform;