import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/diagnostic_exporter.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('diag_exporter_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('buildInfoText 只输出白名单字段', () {
    final text = DiagnosticExporter.buildInfoText(
      appVersion: '5.3.7+39',
      packageName: 'com.md3music.md3music',
      platform: 'android',
      osVersion: 'Android 15 (API 35)',
      deviceModel: 'Xiaomi 14',
      renderEngine: 'impeller',
      serverPort: 12345,
      serverRunning: true,
      exportTime: DateTime(2026, 8, 31, 10, 0, 0),
    );
    expect(text, contains('5.3.7+39'));
    expect(text, contains('com.md3music.md3music'));
    expect(text, contains('Xiaomi 14'));
    expect(text, contains('Android 15 (API 35)'));
    expect(text, contains('impeller'));
    expect(text, contains('12345'));
    // 白名单收集：报告不含任何账号/令牌类字段
    expect(text, isNot(contains('token')));
    expect(text, isNot(contains('cookie')));
  });

  test('packageZip 打包目录内全部文件', () async {
    File('${tempDir.path}/app.log').writeAsStringSync('log-content');
    File(
      '${tempDir.path}/diagnostic_info.txt',
    ).writeAsStringSync('info-content');
    final zip = await DiagnosticExporter.packageZip(
      sourceDir: tempDir,
      outputDir: tempDir,
      fileName: 'report.zip',
    );
    expect(zip.existsSync(), isTrue);
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, containsAll(['app.log', 'diagnostic_info.txt']));
  });

  test('buildLogSummary 汇总新版、旧版和 Android 日志级别', () {
    final summary = DiagnosticExporter.buildLogSummary(
      logFiles: {
        'app.log': [
          '2026-09-16 10:00:00.000 [DEBUG] debug',
          '2026-09-16 10:00:01.000 [INFO] info',
          '2026-09-16 10:00:02.000 [WARNING] warning',
          '2026-09-16 10:00:03.000 [ERROR] error',
          '2026-09-16 10:00:04.000 [W] legacy warning',
        ].join('\n'),
        'android.log': [
          '09-16 10:01:00.000  123  456 D MD3CarLyrics: debug',
          '09-16 10:01:01.000  123  456 E MD3CarLyrics: error',
        ].join('\n'),
      },
      exportTime: DateTime(2026, 9, 16, 10, 2),
    );

    expect(summary, contains('全部日志: DEBUG=2 INFO=1 WARNING=2 ERROR=2'));
    expect(summary, contains('[app.log]'));
    expect(summary, contains('legacy warning'));
    expect(summary, contains('[android.log]'));
  });
}
