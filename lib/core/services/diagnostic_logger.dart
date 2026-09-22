import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 诊断日志级别
enum DiagnosticLogLevel {
  debug('DEBUG'),
  info('INFO'),
  warning('WARNING'),
  error('ERROR');

  const DiagnosticLogLevel(this.tag);

  /// 日志行中的完整级别标记
  final String tag;
}

/// 轻量诊断日志服务：内存缓冲 + 滚动文件落盘。
///
/// 参考成熟方案（Frezyx/talker、zubairehman/Flogs）的文件滚动与导出思路，
/// 按本项目自包含服务风格（core/services 单例）轻量实现，不引入 DB。
///
/// 捕获面：
/// - 重定向全局 [debugPrint]（项目存量日志大多走 debugPrint，自动入库）；
/// - 安装 [FlutterError.onError] 与 [PlatformDispatcher.onError] 捕获框架错误；
/// - Zone 级未捕获错误由 main.dart 的 runZonedGuarded 经 [e] 记入（见 Task 3）；
/// - Kotlin 侧未捕获异常由原生 handler 写入同目录（见 Task 6）。
///
/// 滚动策略：单文件默认 512KB，备份默认 2 份（app.log.1 / app.log.2），
/// 总量上限约 1.5MB，永不膨胀。写入为批量刷盘（2 秒或缓冲超 8KB），
/// 不阻塞主线程；写入失败一律静默，诊断功能不得影响主流程。
class DiagnosticLogger {
  DiagnosticLogger._();

  static final DiagnosticLogger instance = DiagnosticLogger._();

  /// 单文件大小上限（字节）
  static const int defaultMaxFileSize = 512 * 1024;

  /// 备份文件数量上限（不含当前文件）
  static const int defaultMaxFileCount = 2;

  /// 当前日志文件名（备份依次为 app.log.1、app.log.2）
  static const String currentFileName = 'app.log';

  /// 缓冲区超过该大小时立即刷盘
  static const int _flushBufferThreshold = 8 * 1024;

  /// 定时刷盘间隔
  static const Duration _flushInterval = Duration(seconds: 2);

  bool _initialized = false;
  Directory? _logDir;
  IOSink? _sink;
  int _currentSize = 0;
  int _maxFileSize = defaultMaxFileSize;
  int _maxFileCount = defaultMaxFileCount;
  final StringBuffer _pending = StringBuffer();
  Timer? _flushTimer;
  Future<void>? _activeFlush;
  DebugPrintCallback? _originalDebugPrint;

  /// 日志目录（[init] 之后可用；未初始化或 Web 平台为 null）。
  Directory? get logDir => _logDir;

  /// 初始化：创建日志目录、打开当前日志文件、安装 debugPrint 重定向与错误钩子。
  ///
  /// [dir] 仅测试注入用；生产默认
  /// `getApplicationSupportDirectory()/diagnostic_logs`
  /// （Android 上等价于 Kotlin 的 filesDir，原生崩溃文件同目录，见计划文档 1.4）。
  /// [maxFileSize] / [maxFileCount] 仅测试注入小值用。
  Future<void> init({
    Directory? dir,
    int maxFileSize = defaultMaxFileSize,
    int maxFileCount = defaultMaxFileCount,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _maxFileSize = maxFileSize;
    _maxFileCount = maxFileCount;
    try {
      // Web 无本地文件系统，跳过（入口侧同样有守卫）
      if (kIsWeb) return;
      _logDir =
          dir ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}/diagnostic_logs',
          );
      _logDir!.createSync(recursive: true);
      _openCurrentFile();
      _installDebugPrintCapture();
      _installErrorHooks();
      _flushTimer = Timer.periodic(_flushInterval, (_) => flush());
      i('=== MD3Music 诊断日志已启用 ${DateTime.now()} ===');
    } catch (e, stack) {
      // 初始化失败只走原始 debugPrint，绝不影响启动流程
      _originalDebugPrint?.call('[DiagnosticLogger] 初始化失败: $e\n$stack');
    }
  }

  /// 记录 debug 级别日志
  void d(String message) => _append(DiagnosticLogLevel.debug, message);

  /// 记录 info 级别日志
  void i(String message) => _append(DiagnosticLogLevel.info, message);

  /// 记录 warning 级别日志
  void w(String message) => _append(DiagnosticLogLevel.warning, message);

  /// 记录 error 级别日志
  void e(String message) => _append(DiagnosticLogLevel.error, message);

  /// 语义清晰的完整方法名；短方法名保留以兼容现有调用。
  void debug(String message) => d(message);
  void info(String message) => i(message);
  void warning(String message) => w(message);
  void error(String message) => e(message);

  /// 格式化日志：`2026-08-31 09:05:03.012 [WARNING] hello`。
  /// 多行消息的每一行都带时间与级别，便于导出后按级别检索。
  static String formatLine(
    DateTime time,
    DiagnosticLogLevel level,
    String message,
  ) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    final ts =
        '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${three(time.millisecond)}';
    final prefix = '$ts [${level.tag}] ';
    final lines = message
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    return lines.map((line) => '$prefix$line').join('\n');
  }

  void _append(DiagnosticLogLevel level, String message) {
    if (!_initialized || _logDir == null) return;
    _pending.writeln(formatLine(DateTime.now(), level, message));
    if (_pending.length >= _flushBufferThreshold) {
      unawaited(flush());
    }
  }

  /// 强制把缓冲写入磁盘（导出前必须调用，保证内容完整）。
  Future<void> flush() async {
    // 串接到已有刷盘之后。这样导出与定时刷盘并发时，前一次写盘期间新追加的
    // 内容也会由本次操作落盘，不会遗漏最后几行日志。
    final previous = _activeFlush ?? Future<void>.value();
    final operation = previous.then((_) async {
      if (_pending.isEmpty || _sink == null) return;
      await _writePending();
    });
    _activeFlush = operation;
    try {
      await operation;
    } finally {
      if (identical(_activeFlush, operation)) {
        _activeFlush = null;
      }
    }
  }

  /// 关闭当前日志文件句柄（供清空日志流程使用）。
  ///
  /// 必须先关句柄再删除 app.log：否则后续写入会进已删除的 inode，
  /// app.log 在下次进程重启前永久消失（历轮诊断报告缺 app.log 的根因）。
  Future<void> closeSinkForClearing() async {
    try {
      await flush();
    } catch (_) {}
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }

  /// 重新打开当前日志文件（清空日志删除文件后调用）。
  void reopenSinkAfterClearing() {
    if (!_initialized || _logDir == null || _sink != null) return;
    try {
      _openCurrentFile();
    } catch (_) {}
  }

  Future<void> _writePending() async {
    final chunk = _pending.toString();
    _pending.clear();
    if (await _tryWrite(chunk)) return;
    // 写入失败自愈：句柄可能失效（文件被外部删除/占用）——重开一次再写；
    // 仍失败才静默放弃（诊断日志不得影响主流程）。
    try {
      await _sink?.flush();
    } catch (_) {}
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    try {
      _openCurrentFile();
      await _tryWrite(chunk);
    } catch (_) {}
  }

  /// 单次写盘（含滚动检查），成功返回 true。
  Future<bool> _tryWrite(String chunk) async {
    try {
      if (_sink == null) return false;
      final bytes = utf8.encode(chunk);
      if (_currentSize + bytes.length > _maxFileSize) {
        await _rotate();
      }
      _sink!.write(chunk);
      await _sink!.flush();
      _currentSize += bytes.length;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 文件滚动：app.log → app.log.1 → app.log.2 …… 最旧的一份删除。
  Future<void> _rotate() async {
    try {
      await _sink!.flush();
      await _sink!.close();
    } catch (_) {}
    _sink = null;
    final dir = _logDir!.path;
    // 删除最旧的备份
    final oldest = File('$dir/$currentFileName.$_maxFileCount');
    if (oldest.existsSync()) oldest.deleteSync();
    // 依次后移：N-1 → N …… 1 → 2
    for (var n = _maxFileCount - 1; n >= 1; n--) {
      final src = File('$dir/$currentFileName.$n');
      if (src.existsSync()) {
        src.renameSync('$dir/$currentFileName.${n + 1}');
      }
    }
    final current = File('$dir/$currentFileName');
    if (current.existsSync()) {
      current.renameSync('$dir/$currentFileName.1');
    }
    _openCurrentFile();
  }

  void _openCurrentFile() {
    final file = File('${_logDir!.path}/$currentFileName');
    _currentSize = file.existsSync() ? file.lengthSync() : 0;
    _sink = file.openWrite(mode: FileMode.append);
  }

  /// 重定向全局 debugPrint：存量 debugPrint 输出自动入库，
  /// 同时保留原始行为（节流打印到控制台）。
  void _installDebugPrintCapture() {
    _originalDebugPrint = debugPrint;
    final original = _originalDebugPrint!;
    debugPrint = (String? message, {int? wrapWidth}) {
      instance.d(message ?? '');
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// 安装框架级错误钩子：框架异常与 Isolate 未捕获异常都记入日志。
  void _installErrorHooks() {
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      instance.e(
        'FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}',
      );
      // 保留原有处理链（若有），否则走默认控制台呈现
      if (previousOnError != null) {
        previousOnError(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      instance.e('未捕获异常: $error\n$stack');
      // 返回 false：交给引擎默认处理（该崩溃仍会崩溃，只是先留痕）
      return false;
    };
  }

  /// 仅测试使用：恢复 debugPrint、关闭文件、清空状态。
  @visibleForTesting
  Future<void> resetForTesting() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      await flush();
    } catch (_) {}
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    if (_originalDebugPrint != null) {
      debugPrint = _originalDebugPrint!;
    }
    _originalDebugPrint = null;
    _pending.clear();
    _logDir = null;
    _currentSize = 0;
    _initialized = false;
  }
}
