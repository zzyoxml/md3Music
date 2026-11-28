import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/diagnostic_logger.dart';

void main() {
  // init() 会把自身挂到 WidgetsBinding 上收口生命周期（后台不排盘）。
  TestWidgetsFlutterBinding.ensureInitialized();

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
      DiagnosticLogLevel.warning,
      'hello',
    );
    expect(line, '2026-08-31 09:05:03.012 [WARNING] hello');
  });

  test('多行日志的每一行都带相同级别', () {
    final line = DiagnosticLogger.formatLine(
      DateTime(2026, 8, 31, 9, 5, 3, 12),
      DiagnosticLogLevel.error,
      'boom\nstack line',
    );
    expect(
      line,
      '2026-08-31 09:05:03.012 [ERROR] boom\n'
      '2026-08-31 09:05:03.012 [ERROR] stack line',
    );
  });

  test('诊断文本保留上下文并清理 URI 与凭证字段', () {
    final sanitized = DiagnosticLogger.sanitizeDiagnosticText(
      'load failed url=https://media.example/song.mp3?token=abc '
      'Authorization: Bearer secret cookie="sid=private" '
      'content://media/external/audio/123',
    );

    expect(sanitized, contains('load failed'));
    expect(sanitized, contains('[URI_REDACTED]'));
    expect(sanitized, contains('Authorization: [REDACTED]'));
    expect(sanitized, contains('cookie="[REDACTED]"'));
    expect(sanitized, contains('https://media.example/[URI_REDACTED]'));
    expect(sanitized, isNot(contains('/song.mp3')));
    expect(sanitized, isNot(contains('secret')));
    expect(sanitized, isNot(contains('sid=private')));
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
    expect(content, contains('[DEBUG] captured-by-logger'));
  });

  test('四种日志级别写入完整标签', () async {
    await DiagnosticLogger.instance.init(dir: tempDir);
    DiagnosticLogger.instance.debug('debug-line');
    DiagnosticLogger.instance.info('info-line');
    DiagnosticLogger.instance.warning('warning-line');
    DiagnosticLogger.instance.error('error-line');
    await DiagnosticLogger.instance.flush();
    final content = await File('${tempDir.path}/app.log').readAsString();
    expect(content, contains('[DEBUG] debug-line'));
    expect(content, contains('[INFO] info-line'));
    expect(content, contains('[WARNING] warning-line'));
    expect(content, contains('[ERROR] error-line'));
  });

  test('后台不排盘，回到前台补刷一次', () async {
    await DiagnosticLogger.instance.init(dir: tempDir);
    // 清掉 init 自身那条日志，让后续断言只针对本次新增
    await DiagnosticLogger.instance.flush();
    final file = File('${tempDir.path}/app.log');

    DiagnosticLogger.instance
        .didChangeAppLifecycleState(AppLifecycleState.paused);
    DiagnosticLogger.instance.i('held-while-paused');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      await file.readAsString(),
      isNot(contains('held-while-paused')),
      reason: '后台期间不得排盘写入',
    );

    DiagnosticLogger.instance
        .didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      await file.readAsString(),
      contains('held-while-paused'),
      reason: '回到前台必须补刷，后台攒下的日志不能丢',
    );
  });
}
