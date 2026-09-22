import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/utils/app_toast.dart';
import '../../data/repositories/settings_repository.dart';
import 'github_release_client.dart';
import 'release_info.dart';
import 'release_version.dart';

/// 一次检查的结果。
enum UpdateCheckOutcome {
  /// 已 toast 提醒用户
  notified,
  /// 已是最新（或远端版本无法比较）
  upToDate,
  /// 本次跳过（开关关闭 / 未到检查间隔 / 同一版本已提醒 / 非 Android）
  skipped,
  /// 查询失败（网络等原因，静默）
  failed,
}

/// 提醒方式注入点：默认走全局原生 toast，测试中替换为收集器。
typedef UpdateNotifier = void Function(String message);

/// 版本更新检测与提醒。
///
/// 职责边界：只负责「查最新版本 → 比本地版本 → 提醒一次」，
/// 不做下载、不做安装、不展示更新日志。
class UpdateCheckService {
  UpdateCheckService({
    ReleaseSource? source,
    SettingsRepository? settings,
    UpdateNotifier? notifier,
    Future<String> Function()? readCurrentVersion,
  }) : _source = source ?? GithubReleaseClient(),
       _settings = settings ?? SettingsRepository(),
       _notifier = notifier ?? _defaultNotifier,
       _readCurrentVersion = readCurrentVersion ?? _defaultCurrentVersion;

  /// 全局单例（启动挂载点使用）。
  static final UpdateCheckService instance = UpdateCheckService();

  /// 启动后延迟多久检查：避开冷启动首帧与首屏接口竞争。
  static const Duration startupDelay = Duration(seconds: 8);

  /// 两次网络查询的最小间隔（跨启动持久化）。
  static const Duration minCheckInterval = Duration(hours: 12);

  final ReleaseSource _source;
  final SettingsRepository _settings;
  final UpdateNotifier _notifier;
  final Future<String> Function() _readCurrentVersion;

  /// 同一次运行内的防重入。
  bool _running = false;

  static void _defaultNotifier(String message) => showToast(message, long: true);

  static Future<String> _defaultCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (error) {
      debugPrint('[UpdateCheck] 读取本地版本失败：$error');
      return '';
    }
  }

  /// 启动挂载点：延迟 [startupDelay] 后自动检查一次。
  ///
  /// [suppress] 为 true 时直接跳过（首次启动引导 / 用户协议未确认时不应打扰）。
  void scheduleStartupCheck({bool suppress = false}) {
    if (suppress) return;
    // Release 资产只有 Android APK，其它平台检查无意义
    if (kIsWeb || !Platform.isAndroid) return;
    Timer(startupDelay, () {
      // ignore: discarded_futures
      checkAndNotify();
    });
  }

  /// 检查并在发现新版本时提醒。返回值便于日志与测试断言。
  Future<UpdateCheckOutcome> checkAndNotify() async {
    if (_running) return UpdateCheckOutcome.skipped;
    _running = true;
    try {
      return await _run();
    } finally {
      _running = false;
    }
  }

  Future<UpdateCheckOutcome> _run() async {
    if (!await _settings.getUpdateReminderEnabled()) {
      debugPrint('[UpdateCheck] 用户已关闭新版本提醒，跳过');
      return UpdateCheckOutcome.skipped;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastCheckMs = await _settings.getUpdateLastCheckMs();
    if (lastCheckMs > 0 && now - lastCheckMs < minCheckInterval.inMilliseconds) {
      debugPrint('[UpdateCheck] 距上次检查不足 12 小时，跳过');
      return UpdateCheckOutcome.skipped;
    }

    final release = await _source.fetchLatest();
    // 无论成败都记录时间戳：失败时不重试轰炸，下个窗口再试
    await _settings.setUpdateLastCheckMs(now);
    if (release == null) return UpdateCheckOutcome.failed;

    final current = await _readCurrentVersion();
    if (!isNewerRelease(release.version, current)) {
      debugPrint(
        '[UpdateCheck] 已是最新（本地 ${current.isEmpty ? '未知' : current}，远端 ${release.version}）',
      );
      return UpdateCheckOutcome.upToDate;
    }

    // 同一版本只提醒一次：避免每次启动都弹同一个版本
    if (await _settings.getUpdateLastNotifiedVersion() == release.version) {
      debugPrint('[UpdateCheck] ${release.version} 已提醒过，跳过');
      return UpdateCheckOutcome.skipped;
    }

    await _settings.setUpdateLastNotifiedVersion(release.version);
    _notify(release, current);
    debugPrint('[UpdateCheck] 已提醒新版本 ${release.version}（本地 $current）');
    return UpdateCheckOutcome.notified;
  }

  void _notify(ReleaseInfo release, String current) {
    final currentPart = current.isEmpty ? '' : '（当前 $current）';
    _notifier('发现新版本 ${release.tagName}$currentPart，可在「设置 → 关于」中更新');
  }
}
