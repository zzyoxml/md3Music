import 'dart:io';

import 'package:flutter/foundation.dart';

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

/// ---- Android 专属功能入口 ----
///
/// 每一项对应设置页里一个只在 Android 上成立的入口。桌面端必须隐藏，
/// 否则用户会点进一个永远不生效的页面（历史上已多次出现：
/// 点"USB 独占"却提示"未检测到 USB 音频设备"，完全是死路）。

/// USB 独占输出（UAC1 DAC 直写 usbdevfs，需 Android USB Host + native cpp）。
bool get supportsUsbExclusive => isAndroidPlatform;

/// 听歌识曲（依赖 Android `MediaSession`/麦克风采集链路与 RMS 分析）。
bool get supportsSongRecognition => isAndroidPlatform;

/// 预测性手势（横滑切歌 / 长按识别等，依赖 Android 系统的
/// `MotionEvent` 手势与振动反馈配合）。
bool get supportsPredictiveGesture => isAndroidPlatform;

/// 音乐频谱（依赖 Android 端 `Visualizer` 音频源采集 PCM 波形）。
bool get supportsMusicSpectrum => isAndroidPlatform;

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

/// 蝰蛇母带处理链（10 段均衡 + 限幅，母带级处理）。
///
/// 字幕已自述"仅 Android"；依赖 Android 端 `LoudnessEnhancer` /
/// `DynamicsProcessing` 等音频特效 API，关闭时输出逐字节透传。
bool get supportsViperMaster => isAndroidPlatform;

/// 音量均衡 / 参考响度（ReLU / 目标 dB 归一）。
///
/// 同样挂在 `EqualizerService` 的音效链上，桌面端一并失效。
bool get supportsLoudnessNormalization => isAndroidPlatform;