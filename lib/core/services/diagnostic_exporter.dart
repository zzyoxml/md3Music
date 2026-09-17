import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/kugou_server.dart';
import 'diagnostic_logger.dart';
import 'media_store_service.dart';
import 'usb_audio_service.dart';

/// 诊断报告构建与导出。
///
/// 流程：flush 日志 → 收集日志目录内全部文件（app.log*、native_crash_*.txt）
/// → 生成 diagnostic_info.txt（白名单字段）→ 打包 zip → share_plus 打开
/// 系统分享面板，由用户自主选择去向。
///
/// 安全约定：信息收集为白名单制，只包含设备与运行环境字段，
/// 绝不读取/写入任何登录令牌、cookie、用户 ID。
/// 新增字段前必须阅读计划文档「后续维护支持」第 2 条。
class DiagnosticExporter {
  DiagnosticExporter._();

  static const MethodChannel _diagnosticChannel = MethodChannel(
    'com.md3music.md3music/diagnostic_log',
  );

  /// 收集信息并构建 zip 报告，返回 zip 文件。
  static Future<File> buildReport() async {
    final logger = DiagnosticLogger.instance;
    logger.info('开始导出诊断日志');

    // 1. 先收集原生日志。收集过程产生的 Dart 日志随后一并 flush，避免导出包
    // 缺少最后几行；Android 原生日志使用系统自带 D/I/W/E 等级。
    String androidLogs = '';
    String usbLogs = '';
    if (!kIsWeb && Platform.isAndroid) {
      try {
        androidLogs =
            await _diagnosticChannel.invokeMethod<String>('getAndroidLogs') ??
            '';
      } catch (e) {
        logger.warning('Android 原生日志导出失败: $e');
      }
      try {
        usbLogs = await UsbAudioService.instance.getUsbLogs();
      } catch (e) {
        logger.warning('USB 日志导出失败: $e');
      }
    }

    // 2. 确保缓冲中的日志全部落盘
    await logger.flush();

    final logDir = logger.logDir;
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final tmpRoot = await getTemporaryDirectory();
    final workDir = Directory('${tmpRoot.path}/diagnostic_report_$stamp')
      ..createSync(recursive: true);

    // 3. 复制日志目录内全部文件（app.log / app.log.N / native_crash_*.txt）
    if (logDir != null && logDir.existsSync()) {
      for (final entity in logDir.listSync()) {
        if (entity is File) {
          try {
            entity.copySync('${workDir.path}/${_baseName(entity.path)}');
          } catch (_) {
            // 单文件复制失败（占用/轮转竞争）不中断其余日志收集
          }
        }
      }
    }

    if (androidLogs.isNotEmpty) {
      File(
        '${workDir.path}/android.log',
      ).writeAsStringSync(androidLogs, flush: true);
    }
    // USB 独占链路内部日志（app 侧内存环形 + native 传输层）。
    if (usbLogs.isNotEmpty) {
      File('${workDir.path}/usb.log').writeAsStringSync(usbLogs, flush: true);
    }

    // 4. 生成分级摘要，排查时可先看 WARNING / ERROR，再按文件定位原文。
    final logFiles = <String, String>{};
    for (final entity in workDir.listSync().whereType<File>()) {
      final name = _baseName(entity.path);
      if (!name.toLowerCase().contains('.log')) continue;
      try {
        logFiles[name] = entity.readAsStringSync();
      } catch (_) {}
    }
    File('${workDir.path}/log_summary.txt').writeAsStringSync(
      buildLogSummary(logFiles: logFiles, exportTime: DateTime.now()),
      flush: true,
    );

    // 5. 生成设备/应用概览 + 导出文件清单（缺 app.log 时可直接定位原因）
    final infoText = await _collectInfoText();
    final logInventory = _collectLogInventory(workDir);
    File(
      '${workDir.path}/diagnostic_info.txt',
    ).writeAsStringSync('$infoText\n$logInventory', flush: true);

    // 6. 打包 zip 并清理工作目录
    final zip = await packageZip(
      sourceDir: workDir,
      outputDir: tmpRoot,
      fileName: 'MD3Music_diagnostics_$stamp.zip',
    );
    try {
      workDir.deleteSync(recursive: true);
    } catch (_) {}
    return zip;
  }

  /// 经系统分享面板导出报告。
  static Future<void> shareReport() async {
    final zip = await buildReport();
    await Share.shareXFiles(
      [XFile(zip.path)],
      subject: 'MD3Music 诊断日志',
      text: 'MD3Music 诊断日志（包含设备信息，不包含账号数据）',
    );
  }

  /// 清空全部诊断日志（Dart 日志 + 原生崩溃文件）。
  ///
  /// 必须先关闭日志文件句柄再删除：否则后续写入会进已删除的 inode，
  /// app.log 在下次进程重启前永久消失（历轮报告缺 app.log 的根因）。
  static Future<void> clearLogs() async {
    final logger = DiagnosticLogger.instance;
    await logger.closeSinkForClearing();
    final logDir = logger.logDir;
    if (logDir != null && logDir.existsSync()) {
      for (final entity in logDir.listSync()) {
        try {
          if (entity is File) entity.deleteSync();
        } catch (_) {}
      }
    }
    logger.reopenSinkAfterClearing();
    logger.i('诊断日志已被用户清空');
  }

  /// 生成日志目录清单文本（文件名 + 字节数），随 diagnostic_info.txt 导出。
  static String _collectLogInventory(Directory? logDir) {
    final buffer = StringBuffer()
      ..writeln('')
      ..writeln('[日志文件清单]');
    if (logDir == null || !logDir.existsSync()) {
      buffer.writeln('日志目录不可用（DiagnosticLogger 未初始化或初始化失败）');
      return buffer.toString();
    }
    buffer.writeln('目录: ${logDir.path}');
    final files = logDir.listSync().whereType<File>().toList()
      ..sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
    if (files.isEmpty) {
      buffer.writeln('（目录为空）');
    }
    for (final f in files) {
      var size = 0;
      try {
        size = f.lengthSync();
      } catch (_) {}
      buffer.writeln('${_baseName(f.path)}: $size 字节');
    }
    return buffer.toString();
  }

  /// 生成分级日志摘要。兼容新版完整标签、旧版单字母标签及 Android logcat。
  @visibleForTesting
  static String buildLogSummary({
    required Map<String, String> logFiles,
    required DateTime exportTime,
  }) {
    final total = <DiagnosticLogLevel, int>{
      for (final level in DiagnosticLogLevel.values) level: 0,
    };
    final perFile = <String, Map<DiagnosticLogLevel, int>>{};
    final importantLines = <String>[];

    final names = logFiles.keys.toList()..sort();
    for (final name in names) {
      final counts = <DiagnosticLogLevel, int>{
        for (final level in DiagnosticLogLevel.values) level: 0,
      };
      for (final line in logFiles[name]!.split(RegExp(r'\r?\n'))) {
        final level = _parseLevel(line);
        if (level == null) continue;
        counts[level] = counts[level]! + 1;
        total[level] = total[level]! + 1;
        if (level == DiagnosticLogLevel.warning ||
            level == DiagnosticLogLevel.error) {
          importantLines.add('[$name] $line');
        }
      }
      perFile[name] = counts;
    }

    String row(String name, Map<DiagnosticLogLevel, int> counts) =>
        '$name: DEBUG=${counts[DiagnosticLogLevel.debug]} '
        'INFO=${counts[DiagnosticLogLevel.info]} '
        'WARNING=${counts[DiagnosticLogLevel.warning]} '
        'ERROR=${counts[DiagnosticLogLevel.error]}';

    final buffer = StringBuffer()
      ..writeln('MD3Music 分级日志摘要')
      ..writeln('生成时间: ${exportTime.toIso8601String()}')
      ..writeln('统计口径: 按带级别标记的日志行统计')
      ..writeln('')
      ..writeln('[按文件统计]');
    if (perFile.isEmpty) {
      buffer.writeln('（没有可统计的日志文件）');
    } else {
      for (final name in names) {
        buffer.writeln(row(name, perFile[name]!));
      }
    }
    buffer
      ..writeln('')
      ..writeln('[合计]')
      ..writeln(row('全部日志', total))
      ..writeln('')
      ..writeln('[最近 WARNING / ERROR，最多 100 行]');
    final recent = importantLines.length > 100
        ? importantLines.sublist(importantLines.length - 100)
        : importantLines;
    if (recent.isEmpty) {
      buffer.writeln('（无）');
    } else {
      for (final line in recent) {
        buffer.writeln(line);
      }
    }
    return buffer.toString();
  }

  static DiagnosticLogLevel? _parseLevel(String line) {
    final dartMatch = RegExp(
      r'^\d{4}-\d{2}-\d{2} .*\[(DEBUG|INFO|WARNING|ERROR|D|I|W|E)\] ',
    ).firstMatch(line);
    if (dartMatch != null) {
      return switch (dartMatch.group(1)) {
        'DEBUG' || 'D' => DiagnosticLogLevel.debug,
        'INFO' || 'I' => DiagnosticLogLevel.info,
        'WARNING' || 'W' => DiagnosticLogLevel.warning,
        'ERROR' || 'E' => DiagnosticLogLevel.error,
        _ => null,
      };
    }

    // Android threadtime：`09-16 12:34:56.789  pid  tid D Tag: message`
    // USB 环形：`09-16 12:34:56.789 D/Tag: message`
    final nativeMatch = RegExp(
      r'^\d{2}-\d{2} .*?\s([VDIWEF])(?:\s|/)',
    ).firstMatch(line);
    return switch (nativeMatch?.group(1)) {
      'V' || 'D' => DiagnosticLogLevel.debug,
      'I' => DiagnosticLogLevel.info,
      'W' => DiagnosticLogLevel.warning,
      'E' || 'F' => DiagnosticLogLevel.error,
      _ => null,
    };
  }

  /// 生成诊断信息文本（白名单字段，测试可见）。
  ///
  /// 只输出入参给出的字段；不要在此读取 SharedPreferences 或任何账号数据。
  @visibleForTesting
  static String buildInfoText({
    required String appVersion,
    required String packageName,
    required String platform,
    required String osVersion,
    required String deviceModel,
    required String renderEngine,
    required int? serverPort,
    required bool serverRunning,
    required DateTime exportTime,
  }) {
    final buffer = StringBuffer()
      ..writeln('MD3Music 诊断报告')
      ..writeln('导出时间: ${exportTime.toIso8601String()}')
      ..writeln('')
      ..writeln('[应用]')
      ..writeln('版本: $appVersion')
      ..writeln('包名: $packageName')
      ..writeln('')
      ..writeln('[设备]')
      ..writeln('平台: $platform')
      ..writeln('系统: $osVersion')
      ..writeln('机型: $deviceModel')
      ..writeln('渲染引擎: $renderEngine')
      ..writeln('')
      ..writeln('[本地 API 服务器]')
      ..writeln('运行中: $serverRunning')
      ..writeln('端口: ${serverPort ?? '未知'}')
      ..writeln('')
      ..writeln('[说明]')
      ..writeln('本文件由应用内诊断功能自动生成，仅包含设备与运行环境信息。')
      ..writeln('日志级别: DEBUG / INFO / WARNING / ERROR')
      ..writeln('日志文件: app.log*、android.log、usb.log、log_summary.txt');
    return buffer.toString();
  }

  /// 把目录内全部文件打包为 zip（测试可见）。
  @visibleForTesting
  static Future<File> packageZip({
    required Directory sourceDir,
    required Directory outputDir,
    required String fileName,
  }) async {
    final archive = Archive();
    for (final entity in sourceDir.listSync()) {
      if (entity is File) {
        final bytes = entity.readAsBytesSync();
        archive.addFile(
          ArchiveFile(_baseName(entity.path), bytes.length, bytes),
        );
      }
    }
    final encoded = ZipEncoder().encode(archive);
    final out = File('${outputDir.path}/$fileName');
    out.writeAsBytesSync(encoded ?? const []);
    return out;
  }

  /// 收集真实环境信息（生产路径）。
  static Future<String> _collectInfoText() async {
    String appVersion = '未知';
    String packageName = '未知';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
      packageName = info.packageName;
    } catch (_) {}

    String osVersion = '未知';
    String deviceModel = '未知';
    String renderEngine = '不适用';
    if (!kIsWeb && Platform.isAndroid) {
      final summary = await MediaStoreService.getDeviceSummary();
      if (summary != null) {
        deviceModel =
            '${summary['manufacturer'] ?? ''} ${summary['model'] ?? ''}'.trim();
        osVersion =
            'Android ${summary['release'] ?? ''} (API ${summary['sdkInt'] ?? ''})';
      }
      // 渲染引擎（skia/impeller）由构建期 flavor 决定，是图形类 bug 的
      // 关键上下文；复用设置页「当前渲染引擎」同款通道（MainActivity 注册）。
      try {
        const channel = MethodChannel('com.md3music.md3music/render_engine');
        final v = await channel.invokeMethod<String>('getCurrent');
        renderEngine = v == 'impeller' ? 'impeller' : 'skia';
      } catch (_) {}
    } else if (!kIsWeb) {
      // Windows 桌面（私有版）等非 Android 平台
      osVersion = Platform.operatingSystemVersion;
      deviceModel = Platform.operatingSystem;
    }

    bool serverRunning = false;
    int? serverPort;
    try {
      serverRunning = await KugouApiServer.isRunning();
      final port = KugouApiServer.currentPort;
      serverPort = port > 0 ? port : null;
    } catch (_) {}

    return buildInfoText(
      appVersion: appVersion,
      packageName: packageName,
      platform: kIsWeb ? 'web' : Platform.operatingSystem,
      osVersion: osVersion,
      deviceModel: deviceModel,
      renderEngine: renderEngine,
      serverPort: serverPort,
      serverRunning: serverRunning,
      exportTime: DateTime.now(),
    );
  }

  /// 取路径最后一段（兼容 / 与 \ 分隔符）。
  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;
}
