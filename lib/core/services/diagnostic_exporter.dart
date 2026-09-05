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

  /// 收集信息并构建 zip 报告，返回 zip 文件。
  static Future<File> buildReport() async {
    final logger = DiagnosticLogger.instance;
    // 1. 确保缓冲中的日志全部落盘
    await logger.flush();

    final logDir = logger.logDir;
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final tmpRoot = await getTemporaryDirectory();
    final workDir = Directory('${tmpRoot.path}/diagnostic_report_$stamp')
      ..createSync(recursive: true);

    // 2. 复制日志目录内全部文件（app.log / app.log.N / native_crash_*.txt）
    if (logDir != null && logDir.existsSync()) {
      for (final entity in logDir.listSync()) {
        if (entity is File) {
          entity.copySync('${workDir.path}/${_baseName(entity.path)}');
        }
      }
    }

    // 3. 生成设备/应用概览
    final infoText = await _collectInfoText();
    File('${workDir.path}/diagnostic_info.txt')
        .writeAsStringSync(infoText, flush: true);

    // 4. 打包 zip 并清理工作目录
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
  static Future<void> clearLogs() async {
    final logDir = DiagnosticLogger.instance.logDir;
    if (logDir != null && logDir.existsSync()) {
      for (final entity in logDir.listSync()) {
        try {
          if (entity is File) entity.deleteSync();
        } catch (_) {}
      }
    }
    DiagnosticLogger.instance.i('诊断日志已被用户清空');
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
      ..writeln('本文件由应用内诊断功能自动生成，仅包含设备与运行环境信息。');
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
            '${summary['manufacturer'] ?? ''} ${summary['model'] ?? ''}'
                .trim();
        osVersion =
            'Android ${summary['release'] ?? ''} (API ${summary['sdkInt'] ?? ''})';
      }
      // 渲染引擎（skia/impeller）由构建期 flavor 决定，是图形类 bug 的
      // 关键上下文；复用设置页「当前渲染引擎」同款通道（MainActivity 注册）。
      try {
        const channel =
            MethodChannel('com.md3music.md3music/render_engine');
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