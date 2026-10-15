import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/settings_repository.dart';
import '../build_flags.dart';
import 'audio_service.dart';
import 'device_capabilities.dart';
import 'direct_pcm_service.dart';
import 'equalizer_service.dart';
import 'usb_audio_service.dart';
import 'viper_master_service.dart';

/// USB bit-perfect 输出协调器：**两层开关**模型。
///
/// 只有一个「USB 独占输出」总开关 [enabled]，总开关打开后再由 [viaSystem] 决定
/// **用哪种方案**。不接 DAC 时总开关不可用，整体等于系统默认。
///
/// | enabled | viaSystem | 实际路径 |
/// |---|---|---|
/// | OFF | 任意 | **系统默认**（无 bit-perfect 处理，DSP 全开） |
/// | ON | OFF | usbdevfs ISO URB 直写，绕开 AudioFlinger（音质最好，挑 DAC） |
/// | ON | ON | 系统 AudioTrack 跑 Direct PCM（兼容性最好，率匹配时真 bit-perfect） |
///
/// 两种方案**共用同一个 AudioSink 出口**，故必须互斥 —— 但互斥性由这两个 bool 的
/// 组合保证，不需要独立枚举。
///
/// 设计约束（实现时不要破坏）：
/// 1. **只恢复本协调器改动过的项**：用户在 Direct PCM 期间手动改过的设置，退出时
///    不应被旧值覆盖，故恢复前逐项对账当前值。
/// 2. **子开关置灰不写回持久化值**（见 `DeviceCapabilities.effective`），系统升级后自动恢复。
/// 3. 不直接操作播放器实例：由 PlayerProvider 注册的回调执行下发，本类只做决策。
class OutputModeCoordinator extends ChangeNotifier {
  OutputModeCoordinator._();

  static final OutputModeCoordinator instance = OutputModeCoordinator._();

  /// 内层开关的持久化键：`true` = 总开关打开时改用系统 Direct PCM。
  ///
  /// **默认 false** —— 即默认仍走原有 usbdevfs 直写，用户可见行为不变。
  static const String keyViaSystem = 'usb_bp_via_system';

  /// 外层总开关。**不持久化**（沿用现状：开关状态即原生状态），故重启后为
  /// `false`，即「未接 DAC / 系统默认」。
  bool _enabled = false;

  /// 内层方案选择（仅 [enabled] 为 true 时有意义）。持久化。
  bool _viaSystem = false;

  bool _inited = false;

  /// 本协调器**已改动过**的效果链开关原值。
  /// 只记这里出现过的键，退出时逐个对账恢复。
  final Map<String, bool> _bypassed = <String, bool>{};

  double? _savedVolume;

  /// 由 PlayerProvider 注册：把决策后的音量真正下发到播放器。
  void Function(double volume)? volumeApplier;

  /// 由 PlayerProvider 注册：请求重配输出（float 强制 / performanceMode / 缓冲
  /// 都在 `DefaultAudioSink.configure` 生效，必须重建 AudioTrack）。
  Future<void> Function()? rebuildRequester;

  /// 由 PlayerProvider 注册：进入 unity 音量档时把应用音量压到 1.0 并记住原值。
  ///
  /// 必须主动下发 —— `PlayerProvider.setVolume` 只在用户拖动滑块时才被调用，
  /// 切档本身不会经过它，不主动压一次的话 track volume 仍是旧值（如 0.8），
  /// fast mixer 会对样本施加增益，bit-perfect 判定必然不通过。
  void Function()? unityVolumeApplier;

  /// 外层「USB 独占输出」总开关是否打开。
  bool get enabled => _enabled;

  /// 内层：总开关打开时是否改用系统 Direct PCM（否则走 usbdevfs 直写）。
  bool get viaSystem => _viaSystem;

  /// 是否处于「非系统默认」态（UI 用它决定是否显示方案选择与状态明细）。
  bool get isCustom => _enabled;

  /// 系统 Direct PCM 方案是否**实际生效**（总开关 ON + 内层选中）。
  ///
  /// 这是效果链旁路、unity 音量、交叉淡化互斥的唯一判定入口。
  bool get isDirectPcmActive => _enabled && _viaSystem;

  /// usbdevfs 直写是否**实际生效**（总开关 ON + 内层未选）。
  ///
  /// 注意这不等价于 `UsbAudioService.isEnabled()`：内层选中时直写并未开启，
  /// 但外层开关仍应显示为 ON。
  bool get isUsbdevfsActive => _enabled && !_viaSystem;

  /// Direct PCM 下是否强制 unity 音量（track volume 固定 1.0，改用系统媒体音量键）。
  bool get forceUnityVolume {
    if (!isDirectPcmActive) return false;
    return DirectPcmService.instance
        .featureEffective(DirectPcmFeature.unityVolume);
  }

  /// PlayerProvider.setVolume 在 unity 模式下被拦下时调用：记住用户意图，实际按 1.0 播放。
  void rememberUserVolume(double volume) {
    _savedVolume = volume.clamp(0.0, 1.0);
  }

  /// 退出 Direct PCM 时取走要恢复的音量。
  double? takeSavedVolume() {
    final double? v = _savedVolume;
    _savedVolume = null;
    return v;
  }

  /// 最近一次自动回退提示（UI 取走后即清空）。
  String? lastFallbackNotice;

  String? consumeFallbackNotice() {
    final String? n = lastFallbackNotice;
    lastFallbackNotice = null;
    return n;
  }

  /// 载入持久化的内层选择（幂等）。App 启动时调用一次。
  ///
  /// **不做「上次停在 usb_exclusive 就自动重开独占」**：外层不持久化，重启即
  /// 系统默认。旧版本遗留的 `output_mode` 键已被本键取代，直接忽略（功能当时
  /// 尚未发布，丢失该选择可接受），读不到就用默认 false（= 原直写行为）。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _viaSystem = prefs.getBool(keyViaSystem) ?? false;
    } catch (e) {
      debugPrint('[OutputMode] 读取 $keyViaSystem 失败: $e');
    }
    // 外层恒为 false（系统默认）；若内层被选中，原生 Direct PCM 也不能开着。
    await _pushToNative();
    await _applyDspBypass();
    notifyListeners();
  }

  /// 打开/关闭外层「USB 独占输出」总开关。
  ///
  /// 打开时按 [viaSystem] 分派：
  /// - 内层未选 → 真正调 `enableExclusive()`（含 USB 授权与建流）；**成功之后才**
  ///   置位，失败则保持关闭并记下原因 —— 避免把一个不成立的开关状态带给用户。
  /// - 内层选中 → 走系统 Direct PCM，**不需要 USB 授权**（不 force-claim 接口），
  ///   只开原生的 Direct PCM 并推子开关。
  ///
  /// 关闭时恢复系统默认：关直写（若开着）+ 关 Direct PCM + 恢复效果链与音量。
  Future<void> setEnabled(bool value) async {
    // TV 构建无 USB 独占（原生插件未注册、设置入口已剔除），防御性直接返回
    if (kTvBuild) return;
    if (value == _enabled) return;
    if (value) {
      // 判定用**目标状态** `_viaSystem`，不能用 isUsbdevfsActive ——
      // 此处 `_enabled` 尚未置位，读它会得到 false 而跳过直写开启。
      if (!_viaSystem) {
        final String? failure = await _enterUsbdevfs();
        if (failure != null) {
          // 开启失败：保持总开关关闭，并让副作用（DSP / 音量）也回到普通输出
          lastFallbackNotice = 'USB 独占不可用（$failure），已恢复普通输出';
          await _disableBoth();
          await _applyDspBypass();
          await _applyUnityVolume();
          notifyListeners();
          return;
        }
      }
      _enabled = true;
    } else {
      _enabled = false;
      await _disableBoth();
    }
    await _pushToNative();
    await _applyDspBypass();
    await _applyUnityVolume();
    notifyListeners();
  }

  /// 切换内层「改用系统 Direct PCM」。
  ///
  /// 切到系统 Direct PCM：先关直写，再开 Direct PCM。
  /// 切回 usbdevfs 直写：**必须先把 native 的 Direct PCM 关掉**再开直写 ——
  /// `UsbAudioSinkController.enable()` 有互斥守卫，Direct PCM 仍开启时会直接
  /// 拒绝（真机日志：`enable: rejected — Direct PCM 已开启（两档互斥）`）。
  ///
  /// 切回直写若开不起来：**留在 Direct PCM**，不关闭外层 —— 用户只是想换个方案，
  /// 把一个正在工作的 bit-perfect 方案踢回系统默认会造成「内层开关怎么也关不掉」
  /// （内层开关随之消失，只能去关外层）。此时提示写进 [lastFallbackNotice]。
  ///
  /// 总开关关闭时调用只记录选择、不产生副作用（UI 上内层开关此时不可见）。
  Future<void> setViaSystem(bool value) async {
    if (value == _viaSystem) return;
    _viaSystem = value;
    await _persistViaSystem();
    if (!_enabled) {
      notifyListeners();
      return;
    }
    if (value) {
      await _leaveUsbdevfs();
    } else {
      if (_isAndroid) {
        await DirectPcmService.instance.setEnabled(false);
      }
      final String? failure = await _enterUsbdevfs();
      if (failure != null) {
        // 直写开不起来：内层回到 Direct PCM 并把 native 重新打开，保持可用。
        _viaSystem = true;
        await _persistViaSystem();
        if (_isAndroid) {
          await DirectPcmService.instance.setEnabled(true);
          await DirectPcmService.instance.pushFeatures();
        }
        lastFallbackNotice =
            'USB 直写不可用（$failure），仍使用系统 Direct PCM';
        await _applyDspBypass();
        await _applyUnityVolume();
        notifyListeners();
        return;
      }
    }
    await _pushToNative();
    await _applyDspBypass();
    await _applyUnityVolume();
    notifyListeners();
  }

  /// 真正开启 usbdevfs 直写。返回 null 表示成功，否则返回失败原因（用于提示）。
  Future<String?> _enterUsbdevfs() async {
    if (!_isAndroid) return '当前平台不支持 USB 独占';
    try {
      await UsbAudioService.instance.enableExclusive();
      return null;
    } on UsbAudioException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  Future<void> _leaveUsbdevfs() async {
    if (!_isAndroid) return;
    try {
      if (await UsbAudioService.instance.isEnabled()) {
        await UsbAudioService.instance.disableExclusive();
      }
    } catch (e) {
      debugPrint('[OutputMode] 关闭 USB 直写失败: $e');
    }
  }

  /// 两条路径都关掉（= 恢复系统默认输出）。
  Future<void> _disableBoth() async {
    await _leaveUsbdevfs();
    if (_isAndroid) {
      await DirectPcmService.instance.setEnabled(false);
    }
  }

  Future<void> _persistViaSystem() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyViaSystem, _viaSystem);
    } catch (e) {
      debugPrint('[OutputMode] 持久化 $keyViaSystem 失败: $e');
    }
  }

  /// 是否检测到 USB 音频设备（外层总开关的可用性前提）。
  ///
  /// 数据源是 `UsbAudioService` 的原生状态（`UsbDeviceConnection` 是否存在），
  /// 由 UI 的 1s 轮询刷新（原生只在插拔时推事件，UI 需自行轮询）。
  bool get usbDeviceAvailable =>
      UsbAudioService.instance.lastStatus['deviceConnected'] == true;

  /// 把决策同步到原生开关 + 请求重配输出。
  Future<void> _pushToNative() async {
    if (_isAndroid) {
      await DirectPcmService.instance.setEnabled(isDirectPcmActive);
      if (isDirectPcmActive) {
        // 必须紧跟 setEnabled 推子开关：原生 DirectPcmController 启动时 features
        // 全为 false，不推则 float 强制 / 低延迟 / unity 音量 / 效果链旁路
        // 四个判定全部失效（表现为设置页开关是开的、实际没生效）。
        await DirectPcmService.instance.pushFeatures();
      }
    }
    await _requestRebuild();
  }

  /// 切换后若处于 Direct PCM 的 unity 音量档，主动把应用音量压到 1.0。
  ///
  /// 放在 `_pushToNative` 之后：此时子开关已推给原生，
  /// [forceUnityVolume] 读到的生效值与原生一致。
  Future<void> _applyUnityVolume() async {
    if (!forceUnityVolume) return;
    try {
      unityVolumeApplier?.call();
    } catch (e) {
      debugPrint('[OutputMode] 应用 unity 音量失败: $e');
    }
  }

  Future<void> _requestRebuild() async {
    try {
      await rebuildRequester?.call();
    } catch (e) {
      debugPrint('[OutputMode] 重建输出失败: $e');
    }
  }

  /// 效果链旁路：系统 Direct PCM 实际生效时强制关闭会破坏 bit-perfect 的 DSP，
  /// 退出时**只恢复本协调器改动过、且用户未再手动改回原值**的项。
  Future<void> _applyDspBypass() async {
    final shouldBypass = isDirectPcmActive &&
        DirectPcmService.instance
            .featureEffective(DirectPcmFeature.dspBypass);

    if (shouldBypass) {
      final SettingsRepository repo = SettingsRepository();
      // 1) 音量均衡（响度归一）：关掉会让 AudioService 撤掉 LoudnessEnhancer、归一增益归 0。
      await _bypassPref(
        repo.getVolumeNormalizationEnabled,
        repo.setVolumeNormalizationEnabled,
        'settings_volume_normalization_enabled',
        false,
      );
      // 暂停淡入淡出本身就是一段音量斜坡，与 unity 音量直接冲突，故同开同关。
      if (forceUnityVolume) {
        await _bypassPref(
          repo.getPauseFadeEnabled,
          repo.setPauseFadeEnabled,
          'settings_pause_fade_enabled',
          false,
        );
      }
      // 2) 蝰蛇母带（10 段 EQ + 限幅）
      await _bypassPref(
        repo.getViperMasterEnabled,
        repo.setViperMasterEnabled,
        'settings_viper_master_enabled',
        false,
      );
      // 3) 原生 Equalizer 是运行时状态（不是单个 pref）：挂起，退出时恢复
      EqualizerService.instance.setSuspended(true);
    } else {
      for (final String key in _bypassed.keys.toList()) {
        await _restorePref(key);
      }
      _bypassed.clear();
      EqualizerService.instance.setSuspended(false);
    }
    await _pushDspToRuntime();
  }

  /// 记录原值并写入旁路值；已是目标值则不记（避免退出时多余写回）。
  Future<void> _bypassPref(
    Future<bool> Function() getter,
    Future<void> Function(bool) setter,
    String key,
    bool target,
  ) async {
    if (_bypassed.containsKey(key)) return;
    try {
      final current = await getter();
      if (current == target) return;
      _bypassed[key] = current;
      await setter(target);
    } catch (e) {
      debugPrint('[OutputMode] 旁路 $key 失败: $e');
    }
  }

  /// 恢复单个 pref；若用户已手动改回原值则不再打扰。
  Future<void> _restorePref(String key) async {
    final bool? original = _bypassed[key];
    if (original == null) return;
    final SettingsRepository repo = SettingsRepository();
    try {
      switch (key) {
        case 'settings_volume_normalization_enabled':
          if (await repo.getVolumeNormalizationEnabled() != original) return;
          await repo.setVolumeNormalizationEnabled(original);
        case 'settings_pause_fade_enabled':
          if (await repo.getPauseFadeEnabled() != original) return;
          await repo.setPauseFadeEnabled(original);
        case 'settings_viper_master_enabled':
          if (await repo.getViperMasterEnabled() != original) return;
          await repo.setViperMasterEnabled(original);
      }
    } catch (e) {
      debugPrint('[OutputMode] 恢复 $key 失败: $e');
    }
  }

  /// 把旁路结果同步到运行时（撤 LoudnessEnhancer、撤母带 DSP）。
  Future<void> _pushDspToRuntime() async {
    if (!_isAndroid) return;
    try {
      final SettingsRepository repo = SettingsRepository();
      final bool vn = await repo.getVolumeNormalizationEnabled();
      final bool viper = await repo.getViperMasterEnabled();
      await AudioService().setVolumeNormalization(enabled: vn);
      await ViperMasterService.instance.setEnabled(viper);
    } catch (e) {
      debugPrint('[OutputMode] 同步 DSP 到运行时失败: $e');
    }
  }

  /// USB 独占开启失败（原生 `onExclusiveFailed` 事件，含拔插广播的自动恢复失败）
  /// → **关闭外层总开关，回到系统默认**。
  ///
  /// 不自动改用系统 Direct PCM：独占失败通常意味着设备/ROM 层面的问题，最保守
  /// 可预期的做法是回到「不做任何 bit-perfect 处理」的原默认行为，而不是替用户
  /// 换一个他没选的方案。返回是否发生了回退。
  Future<bool> onExclusiveFailed(String code, String message) async {
    if (!isUsbdevfsActive) return false;
    // ignore: avoid_print
    print('[OutputMode] USB 独占失败($code): $message → 回退普通输出');
    lastFallbackNotice = 'USB 独占不可用（$message），已恢复普通输出';
    await setEnabled(false);
    return true;
  }

  /// USB 音频设备被拔出：若外层总开关还开着，关闭它回到系统默认。
  ///
  /// 内层选中（系统 Direct PCM）时同样要关 —— 总开关的语义是「USB DAC 场景下的
  /// bit-perfect」，设备没了这个意图就不成立（Direct PCM 走系统 AudioTrack，
  /// 本身并不依赖本机的 USB DAC）。
  /// 返回是否发生了关闭。
  Future<bool> onDeviceLost() async {
    if (!_enabled) return false;
    lastFallbackNotice = 'USB 音频设备已断开，已恢复普通输出';
    await setEnabled(false);
    return true;
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
