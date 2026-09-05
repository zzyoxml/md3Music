import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/diagnostic_logger.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('diag_logger_test_');
  });

  tearDown(() async {
    // 恢复 debugPrint 与单例状态，避免用例间串扰
    await DiagnosticLogger.instance.resetForTesting();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('formatLine 输出时间戳、级别与消息', () {
    final line = DiagnosticLogger.formatLine(
      DateTime(2026, 8, 31, 9, 5, 3, 12),
      DiagnosticLogLevel.warn,
      'hello',
    );
    expect(line, '2026-08-31 09:05:03.012 [W] hello');
  });

  test('init 后日志写入文件', () async {
    await DiagnosticLogger.instance.init(dir: tempDir);
    DiagnosticLogger.instance.i('hello world');
    await DiagnosticLogger.instance.flush();
    final content = await File('${tempDir.path}/app.log').readAsString();
    expect(content, contains('hello world'));
  });

  test('单文件超限滚动到备份文件', () async {
    await DiagnosticLogger.instance.init(dir: tempDir, maxFileSize: 64);
    for (var i = 0; i < 40; i++) {
      DiagnosticLogger.instance.i('line $i padding padding padding');
    }
    await DiagnosticLogger.instance.flush();
    expect(File('${tempDir.path}/app.log').existsSync(), isTrue);
    expect(File('${tempDir.path}/app.log.1').existsSync(), isTrue);
  });

  test('备份文件数不超过上限', () async {
    await DiagnosticLogger.instance.init(
      dir: tempDir,
      maxFileSize: 64,
      maxFileCount: 1,
    );
    for (var i = 0; i < 200; i++) {
      DiagnosticLogger.instance.i('line $i padding padding padding');
    }
    await DiagnosticLogger.instance.flush();
    expect(File('${tempDir.path}/app.log').existsSync(), isTrue);
    expect(File('${tempDir.path}/app.log.1').existsSync(), isTrue);
    expect(File('${tempDir.path}/app.log.2').existsSync(), isFalse);
  });

  test('捕获 debugPrint 输出', () async {
    await DiagnosticLogger.instance.init(dir: tempDir);
    debugPrint('captured-by-logger');
    await DiagnosticLogger.instance.flush();
    final content = await File('${tempDir.path}/app.log').readAsString();
    expect(content, contains('captured-by-logger'));
  });
}