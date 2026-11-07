import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/platform_capabilities.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/modules/settings/settings_search_index.g.dart';

/// Windows 端隐藏 Android 专属入口的回归测试。
///
/// **背景**：Windows 上原先直接显示 USB 独占 / 听歌识曲 / 预测性返回手势 /
/// 音乐频谱 / 震动反馈 / 桌面快捷方式等入口，点进去全是死路
///（截图证据：点"USB 独占"只得到"未检测到 USB 音频设备"）。
/// 这些功能依赖 Android 专属能力：
///   - USB 独占：USB Host + native cpp（UAC1 DAC 直写 usbdevfs）
///   - 预测性返回：Android 14+ 系统手势导航
///   - 震动反馈：Vibrator 硬件
///   - 桌面快捷方式：quick_actions_android
///
/// **音乐频谱已不再是 Android 专属**（2026-10）：Windows runner 用 WASAPI 环回
/// 采集本进程音频并做同款 FFT，与 Android 共用 `onFft` 协议，因此该能力在
/// 两个平台都为 true，只保留"其它桌面平台为 false"的口径。
///
/// **听歌识曲也放行 Windows**（2026-11）：Windows 走 `record_windows`
/// （MediaFoundation）麦克风采集 + 本地 Rust PCM 前处理，设备枚举由 runner 的
/// WASAPI 通道提供；只有悬浮窗识曲仍是 Android 专属。
///
/// 本测试锁两件事：
/// 1. 平台判定本身正确（非 Windows / 非 Android 的桌面端为 false，Windows 自己的
///    频谱为 true）；
/// 2. **门控点确实存在** —— 防止将来有人把这些 `if` 删掉或改名后
///    入口又冒出来却没人发现（这正是本次问题的成因：入口一直没被门控）。
void main() {
  group('平台判定', () {
    test('桌面端 Android 专属能力为 false，音乐频谱按平台单独判定', () {
      // flutter test 跑在宿主平台；CI/开发机通常是 Windows 或 macOS。
      // 这里不断言具体平台，只断言"非 Android 时 Android 专属能力全部为 false"。
      if (!isAndroidPlatform) {
        expect(supportsUsbExclusive, isFalse);
        // 听歌识曲：Windows 用麦克风 + 本地 Rust 前处理，桌面端可用；
        // 其它桌面平台（mac/Linux）没有对应采集分支，仍为 false。
        expect(supportsSongRecognition, isWindowsDesktop);
        expect(supportsPredictiveGesture, isFalse);
        expect(supportsHaptics, isFalse);
        expect(supportsDesktopShortcut, isFalse);
        expect(isDesktopPlatform, isTrue);
        // Windows 有 WASAPI 环回采集；mac/Linux 没有原生采集通路。
        expect(supportsMusicSpectrum, isWindowsDesktop);
      }
    });

    test('Android 能力判定在非 Web 下有确定值', () {
      // Web 下 Platform.* 会抛异常，实现里已用 kIsWeb 短路；
      // 这里只确认调用不抛。
      expect(() => isAndroidPlatform, returnsNormally);
      expect(() => isDesktopPlatform, returnsNormally);
    });
  });

  group('主页 tab：听歌识曲', () {
    test('非 Android 且非 Windows 时 kAllAvailableTabs 不含 recognition', () {
      if (isAndroidPlatform || isWindowsDesktop) return;
      expect(
        kAllAvailableTabs.any((t) => t.id == 'recognition'),
        isFalse,
        reason: 'mac/Linux 桌面端不应提供听歌识曲 tab',
      );
    });

    test('Windows 桌面端提供听歌识曲 tab', () {
      // flutter test 默认把 defaultTargetPlatform 覆盖成 android，
      // 不显式改回 windows 的话本用例会空转（一律走 Android 分支）。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(isWindowsDesktop, isTrue);
      expect(supportsSongRecognition, isTrue);
      expect(
        kAllAvailableTabs.any((t) => t.id == 'recognition'),
        isTrue,
        reason: 'Windows 已支持麦克风采集，tab 必须可见',
      );
    });

    test('kOptionalTabs 本身仍保留 recognition（Android 侧不被破坏）', () {
      // 关键：过滤只发生在 kAllAvailableTabs，**不能**改 kOptionalTabs
      // 本身——那是 const 声明，改了会让 Android 也失去该 tab。
      expect(
        kOptionalTabs.any((t) => t.id == 'recognition'),
        isTrue,
        reason: 'kOptionalTabs 是 Android 与桌面共用的常量，不得裁剪',
      );
    });

    test('kDefaultTabs 保持完整', () {
      expect(kDefaultTabs.map((t) => t.id), isNotEmpty);
      expect(kAllAvailableTabs.length,
          greaterThanOrEqualTo(kDefaultTabs.length));
    });
  });

  group('门控点存在性（防回归）', () {
    // 这些断言针对源码文本：确保门控没被后人删掉。
    // 用源码扫描而非运行时行为，是为了让"删掉 if 但忘了跑 UI 截图"
    // 这种改动在 CI 就暴露。
    test('平台能力门控：导出全部 getter', () {
      expect(supportsUsbExclusive, isA<bool>());
      expect(supportsSongRecognition, isA<bool>());
      expect(supportsPredictiveGesture, isA<bool>());
      expect(supportsMusicSpectrum, isA<bool>());
      expect(supportsHaptics, isA<bool>());
      expect(supportsDesktopShortcut, isA<bool>());
      expect(supportsSystemAudioEffects, isA<bool>());
      expect(supportsViperMaster, isA<bool>());
      expect(supportsLoudnessNormalization, isA<bool>());
    });

    test('supportsUsbExclusive 排除 TV 构建（源码扫描）', () {
      // kTvBuild 是编译期 const，测试进程无法覆盖；TV 包内该条件会被树摇折叠。
      // 这里锁住定义本身，防止有人改回只看 isAndroidPlatform —— TV 构建既不编译
      // USB 独占 C++ 驱动，也不注册 UsbAudioPlugin/DirectPcmPlugin（FEATURE_TV），
      // 只判平台会让设置页与歌曲信息页露出点不动的死 UI。
      final source = File(
        'lib/core/platform_capabilities.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'supportsUsbExclusive\s*=>\s*isAndroidPlatform\s*&&\s*!kTvBuild',
        ).hasMatch(source),
        isTrue,
        reason: 'USB 独占在 TV 构建没有原生能力，必须与桌面端同口径隐藏',
      );
    });

    test('频谱启动门控按平台能力而非 Platform.isAndroid（源码扫描）', () {
      // 历史上两个播放页把频谱写死成 Platform.isAndroid，导致 Windows 即使
      // 开了开关也永远不调用 SpectrumService.start()。能力化后必须走
      // supportsMusicSpectrum，否则以后再加平台还会漏。
      for (final path in <String>[
        'lib/modules/player/full_player.dart',
        'lib/modules/player/full_player_am.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source.contains('if (!supportsMusicSpectrum ||'),
          isTrue,
          reason: '$path 的 _tryStartSpectrum 必须按 supportsMusicSpectrum 门控',
        );
        expect(
          source.contains('if (supportsMusicSpectrum)'),
          isTrue,
          reason: '$path 的界面设置弹层频谱开关必须按能力显示',
        );
      }
      final settings = File(
        'lib/modules/settings/settings_page.dart',
      ).readAsStringSync();
      expect(
        settings.contains('if (supportsMusicSpectrum)'),
        isTrue,
        reason: '设置页「音乐频谱」子页入口必须按能力门控',
      );
    });

    test('USB 独占 UI 门控点存在（设置页 + 歌曲信息页）', () {      final settings = File(
        'lib/modules/settings/settings_page.dart',
      ).readAsStringSync();
      expect(
        settings.contains('if (supportsUsbExclusive)'),
        isTrue,
        reason: '设置页「USB 独占」分类必须按能力门控',
      );

      final songInfo = File(
        'lib/modules/player/song_info_page.dart',
      ).readAsStringSync();
      expect(
        RegExp(r'if \(supportsUsbExclusive\) \.\.\.\[').hasMatch(songInfo),
        isTrue,
        reason: '歌曲信息页的 USB 独占区块必须按能力门控',
      );
      expect(
        songInfo.contains('UsbExclusiveSection('),
        isTrue,
        reason: 'USB 独占区块应与设置页共用 UsbExclusiveSection',
      );
    });

    test('悬浮窗识曲仍为 Android 专属（源码扫描）', () {
      final source = File(
        'lib/core/platform_capabilities.dart',
      ).readAsStringSync();
      expect(
        RegExp(r'supportsFloatingSongRecognition\s*=>\s*isAndroidPlatform')
            .hasMatch(source),
        isTrue,
        reason: '悬浮窗走 Android 悬浮窗权限与 MediaProjection，桌面端不得露出',
      );
      final page = File(
        'lib/modules/recognition/song_recognition_page.dart',
      ).readAsStringSync();
      expect(
        page.contains('if (supportsFloatingSongRecognition)'),
        isTrue,
        reason: '识曲页的悬浮窗入口必须按能力门控',
      );
    });
  });

  group('音效链：桌面端必须为 false', () {
    // 这几项最危险：**不会报错**。EqualizerService.tryBind() 在非Android
    // 直接 return false，但 setEnabled(true) 照样成功、持久化照样写入，
    // 用户看到"已开启"却听不出任何变化 —— 典型的假成功。
    test('桌面端系统音效链全部不可用', () {
      if (isAndroidPlatform) return;
      expect(supportsSystemAudioEffects, isFalse);
      expect(supportsViperMaster, isFalse);
      expect(supportsLoudnessNormalization, isFalse);
    });

    test('音效链门控与 AudioSession 绑定点一致', () {
      // EqualizerService.tryBind 的守卫是 `!Platform.isAndroid`，
      // 门控必须与它同口径，否则会出现"入口可见但绑不上"的错配。
      final serviceSource = File(
        'lib/core/services/equalizer_service.dart',
      ).readAsStringSync();
      expect(
        serviceSource.contains('!Platform.isAndroid'),
        isTrue,
        reason: '若上游守卫变了，本门控需要重新评估',
      );
    });
  });

  group('设置搜索索引不含已隐藏的分类', () {
    // 索引是**编译期**常量（生成器只认 kTvBuild 这类 const 旗标，
    // 看不穿运行时平台判定），故由 `_searchResults` 在运行时按能力过滤。
    // 若桌面端不搜「USB」，结果里就不该再有 'USB 独占' 分类的条目——
    // 否则用户搜「USB / 采样率 / 抖动」会跳到一个根本不存在的分类。
    test('桌面端搜索结果不含 USB 独占条目', () {
      if (isAndroidPlatform) return;
      final usbEntries = kSettingsSearchIndex
          .where((e) => e.category == 'USB 独占')
          .toList();
      // 先确认索引里确实存在这些条目（否则本测试是空转、起不到防回归作用）
      expect(
        usbEntries,
        isNotEmpty,
        reason: '索引里应当仍保留 USB 独占条目（Android 侧要用），'
            '过滤发生在消费端；若这里为空说明索引被误删',
      );
      // 桌面端消费端会过滤掉它们 —— 这里断言过滤条件成立
      expect(supportsUsbExclusive, isFalse);
    });

    test('3D 封面过滤条件保持不变（既有不变量）', () {
      // kDepthCoverAvailable 控制的 3D 过滤是本次之前就有的，
      // 锁住它避免改 USB 过滤时误伤。
      final has3d = kSettingsSearchIndex.any(
        (e) => const {'3D 封面', '3D 封面强度'}.contains(e.label),
      );
      expect(has3d, isTrue, reason: '3D 条目应仍在索引中（Android 侧要用）');
    });
  });
}