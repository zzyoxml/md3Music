import 'package:flutter/foundation.dart';

import 'media_store_service.dart';

/// 单项能力的最低 API 要求。
///
/// 平台的 [minApi] / [minAndroid] 是**代码可执行的前提**（低于它符号不存在或行为缺失）；
/// 而「能否真正落到 AudioFlinger fast 通道」是 ROM/HAL 属性，不在此列 —— 见
/// `DirectPcmFeature.lowLatency` 的说明。
@immutable
class ApiRequirement {
  const ApiRequirement(this.minApi, this.minAndroid);

  /// 最低 `Build.VERSION.SDK_INT`。
  final int minApi;

  /// 对应的最低 Android 版本，仅用于文案。
  final String minAndroid;
}

/// Direct PCM 的子能力开关。
///
/// 每一项独立成开关：SDK 不足时**自动关闭 + 置灰 + 提示**，但**不写回用户持久化的值**
/// （只置灰显示），这样用户升级系统后设置能自动恢复生效。
///
/// 持久化 key 与 [specKey] 对应，见 `SettingsRepository` 的同名 getter/setter。
enum DirectPcmFeature {
  /// 高规格输出：强制 float32 / PCM_32bit，避免 `ToInt16PcmAudioProcessor` 把
  /// 24/32bit 源降为 16bit。这是 bit-perfect 的第一前提。
  highPrecisionOutput(
    specKey: 'settings_direct_pcm_high_precision',
    minApi: 21,
    minAndroid: '5.0',
    defaultOn: true,
  ),

  /// 效果链旁路：关闭音量均衡 / 原生均衡器 / 蝰蛇母带。
  dspBypass(
    specKey: 'settings_direct_pcm_dsp_bypass',
    minApi: 24,
    minAndroid: '7.0',
    defaultOn: true,
  ),

  /// unity 音量：把 AudioTrack 的 track volume 固定为 1.0，用户改用系统媒体音量键调音。
  ///
  /// 非 unity 时 fast mixer 会对样本施加增益，bit-perfect 判定必然不通过 —— 此时
  /// 状态区会如实显示「非 bit-perfect（应用音量 X%）」，不做虚报。
  unityVolume(
    specKey: 'settings_direct_pcm_unity_volume',
    minApi: 21,
    minAndroid: '5.0',
    defaultOn: true,
  ),

  /// 低延迟：`AudioTrack.setPerformanceMode(PERFORMANCE_MODE_LOW_LATENCY)`，
  /// 配合小缓冲让 track 有机会落进 AudioFlinger 的 fast 通道。
  ///
  /// API 26（Android 8.0）起才有该 API。**注意**：这只是必要条件 —— 真正能否走
  /// fast 通道还取决于厂商 audio HAL 是否把该输出标记为 fast device，
  /// 需 `dumpsys media.audio_flinger` 实测，不能靠版本推断。
  lowLatency(
    specKey: 'settings_direct_pcm_low_latency',
    minApi: 26,
    minAndroid: '8.0',
    defaultOn: true,
  ),

  /// 精确路由设备探测：`AudioTrack.getRoutedDevice()`（API 31+）。
  /// 关闭时回退 `getDeviceId()` + `AudioManager.getDevice(id)`，功能不缺失，
  /// 只是多一次查询，因此单独成开关以便告知用户差异。
  exactRouteProbe(
    specKey: 'settings_direct_pcm_exact_route',
    minApi: 31,
    minAndroid: '12.0',
    defaultOn: true,
  ),

  /// 原生输出率确认：反射 `AudioTrack.getNativeOutputSampleRate(sessionId)`（@hide，API 17+）。
  /// 反射失败时回退 `AudioManager.getProperty(PROPERTY_OUTPUT_SAMPLE_RATE)`；
  /// 两者都失败则状态标「无法确认」，绝不虚报 bit-perfect。
  nativeRateConfirm(
    specKey: 'settings_direct_pcm_native_rate',
    minApi: 17,
    minAndroid: '4.2',
    defaultOn: true,
  ),

  /// 采样率对齐（进程内重采样到 DAC 原生率）。
  ///
  /// **尚未实现**（P1）：Media3 1.x 全系已无进程内重采样器，方案已定但未落地
  /// （见计划 P1-a：复用 `androidx.media3.common.audio.SonicAudioProcessor`）。
  /// 在此之前恒为关闭并置灰。
  rateAlignment(
    specKey: 'settings_direct_pcm_rate_alignment',
    minApi: 24,
    minAndroid: '7.0',
    defaultOn: false,
    implemented: false,
  );

  const DirectPcmFeature({
    required this.specKey,
    required this.minApi,
    required this.minAndroid,
    required this.defaultOn,
    this.implemented = true,
  });

  /// 持久化 key（`SharedPreferences`）。
  final String specKey;

  /// 最低 API 要求。
  final int minApi;

  /// 最低 Android 版本（文案用）。
  final String minAndroid;

  /// 默认是否开启。
  final bool defaultOn;

  /// 是否已实现。false 表示恒置灰（如 [rateAlignment]）。
  final bool implemented;

  /// 该子开关的最低 API 要求。
  ApiRequirement get requirement => ApiRequirement(minApi, minAndroid);
}

/// SDK_INT → Android 版本名。仅覆盖本项目 minSdk 24 及以上的常见取值。
const Map<int, String> _sdkVersionNames = <int, String>{
  24: '7.0',
  25: '7.1',
  26: '8.0',
  27: '8.1',
  28: '9',
  29: '10',
  30: '11',
  31: '12',
  32: '12L',
  33: '13',
  34: '14',
  35: '15',
  36: '16',
};

/// 设备能力查询：把 `Build.VERSION.SDK_INT` 拿到 Dart 侧，供子开关门控与置灰文案使用。
///
/// 复用 [MediaStoreService.getSdkVersion]（走 `com.md3music.md3music/media_store`
/// 通道的 `getSdkVersion`），不新建原生通道。
class DeviceCapabilities extends ChangeNotifier {
  DeviceCapabilities._();

  static final DeviceCapabilities instance = DeviceCapabilities._();

  int? _sdkInt;
  bool _loaded = false;

  /// 是否已完成首次加载。
  bool get loaded => _loaded;

  /// 是否成功拿到 SDK 版本。非 Android / 通道不可用时为 false。
  bool get sdkKnown => _sdkInt != null;

  /// `Build.VERSION.SDK_INT`；未知时返回 0（表示「任何有版本要求的项都不满足」）。
  int get sdkInt => _sdkInt ?? 0;

  /// 当前 Android 版本名，未知时返回 null。
  String? get androidVersion => _sdkInt == null ? null : _sdkVersionNames[_sdkInt!];

  /// 载入并缓存 SDK 版本（幂等）。App 启动时调用一次。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final int? v = await MediaStoreService.getSdkVersion();
      if (v != null && v != _sdkInt) {
        _sdkInt = v;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DeviceCapabilities] 读取 SDK 版本失败: $e');
    }
  }

  /// 平台是否满足 [feature] 的最低 API 要求。
  ///
  /// SDK 版本未知时返回 false —— 宁可把开关置灰，也不要在无法确认时宣称可用。
  bool supports(DirectPcmFeature feature) {
    if (!feature.implemented) return false;
    if (!sdkKnown) return false;
    return _sdkInt! >= feature.minApi;
  }

  /// 计算某子开关的**生效值**：用户值与平台可用性的合取。
  ///
  /// 这是设置页渲染的唯一口径：`value: effective(...)`，且置灰时 `onChanged: null`。
  /// 注意本方法**不会**写回持久化值 —— 用户在低版本上关掉开关、系统升级后仍能恢复。
  bool effective(DirectPcmFeature feature, bool userValue) {
    if (!userValue) return false;
    return supports(feature);
  }

  /// 置灰原因文案；可用时返回 null。
  ///
  /// 例：「需 Android 8.0（当前 Android 7.1）」/「开发中」。
  String? unavailableReason(DirectPcmFeature feature) {
    if (!feature.implemented) return '开发中';
    if (!sdkKnown) return '无法确认系统版本，已停用';
    if (supports(feature)) return null;
    final current = androidVersion;
    final currentText = current == null ? 'API $_sdkInt' : 'Android $current';
    return '需 Android ${feature.minAndroid}（当前 $currentText）';
  }
}
