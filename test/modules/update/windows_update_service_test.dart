import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/update/release_info.dart';
import 'package:md3music/modules/update/github_release_client.dart';
import 'package:md3music/modules/update/windows_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TemporaryPathProvider extends PathProviderPlatform {
  _TemporaryPathProvider(this.path);

  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _ReleaseClient extends GithubReleaseClient {
  int calls = 0;

  @override
  Future<ReleaseInfo?> fetchLatestDetails() async {
    calls++;
    return ReleaseInfo.fromTag(
      tagName: 'v6.1.0',
      htmlUrl: 'https://github.com/zzyoxml/md3Music/releases/tag/v6.1.0',
      windowsZipUrl: 'https://github.com/zzyoxml/md3Music/update.zip',
    );
  }
}

void _mockVersion(String version) => PackageInfo.setMockInitialValues(
  appName: 'md3Music',
  packageName: 'com.md3music',
  version: version,
  buildNumber: '1',
  buildSignature: '',
);

class _MirrorAdapter implements HttpClientAdapter {
  _MirrorAdapter(this.payload);

  final List<int> payload;
  final requestedUrls = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUrls.add(options.uri.toString());
    if (requestedUrls.length == 1) {
      return ResponseBody.fromString('mirror unavailable', 503);
    }
    return ResponseBody.fromBytes(
      payload,
      200,
      headers: {
        Headers.contentLengthHeader: [payload.length.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockVersion('5.5.0');
  });

  test('Windows 启动不被检查时间及已提醒版本挡住，未安装时每次启动仍提示', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': DateTime.now().millisecondsSinceEpoch,
      'update_last_notified_version': '6.1.0',
    });
    final client = _ReleaseClient();
    expect((await WindowsUpdateService(releases: client).checkForUpdate())?.version, '6.1.0');
    expect((await WindowsUpdateService(releases: client).checkForUpdate())?.version, '6.1.0');
    expect(client.calls, 2);
  });

  test('启动提醒关闭仍可手动检查，已安装版本不重复提示', () async {
    SharedPreferences.setMockInitialValues({'settings_update_reminder_enabled': false});
    final client = _ReleaseClient();
    final service = WindowsUpdateService(releases: client);
    expect(await service.checkForUpdate(), isNull);
    expect(client.calls, 0);
    expect((await service.checkForUpdate(manual: true))?.version, '6.1.0');
    _mockVersion('6.1.0');
    expect(await service.checkForUpdate(manual: true), isNull);
  });

  test('重启结果兼容 PowerShell UTF-8 BOM，并核对实际版本，只消费一次', () async {
    final temp = await Directory.systemTemp.createTemp('md3-update-result-');
    final oldPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPathProvider(temp.path);
    addTearDown(() async {
      PathProviderPlatform.instance = oldPathProvider;
      await temp.delete(recursive: true);
    });
    final result = File('${temp.path}/windows-update-result.json');
    final service = WindowsUpdateService();
    await result.writeAsString('\uFEFF${jsonEncode({'status': 'completed', 'version': '6.1.0'})}');
    expect(await service.takeInstallResult(), contains('当前仍为 v5.5.0'));
    _mockVersion('6.1.0');
    await result.writeAsString(jsonEncode({'status': 'completed', 'version': '6.1.0'}));
    expect(await service.takeInstallResult(), '更新成功，当前版本 v6.1.0');
    expect(await service.takeInstallResult(), isNull);
    await result.writeAsString(jsonEncode({'status': 'failed', 'message': '文件被占用', 'logPath': 'update.log'}));
    expect(await service.takeInstallResult(), '更新失败：文件被占用；日志：update.log');
    await result.writeAsString(jsonEncode({'status': 'ready'}));
    expect(await service.takeInstallResult(), isNull);
    expect(await result.exists(), isTrue);
  });

  test('结果文件被独占时等待句柄释放，不再抛出 Windows 错误 32', () async {
    final temp = await Directory.systemTemp.createTemp('md3-update-lock-');
    final oldPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPathProvider(temp.path);
    final result = File('${temp.path}/windows-update-result.json');
    final locked = File('${temp.path}/locked');
    await result.writeAsString(jsonEncode({'status': 'completed', 'version': '5.5.0'}));
    String quote(String path) => path.replaceAll("'", "''");
    final process = await Process.start('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command',
      "\$f=[IO.File]::Open('${quote(result.path)}','Open','ReadWrite','None'); "
          "try { [IO.File]::WriteAllText('${quote(locked.path)}',''); "
          'Start-Sleep -Milliseconds 1000 } finally { \$f.Dispose() }',
    ]);
    process.stdout.drain<void>();
    final helperErrors = StringBuffer();
    process.stderr.listen((bytes) => helperErrors.write(systemEncoding.decode(bytes)));
    await process.stdin.close();
    addTearDown(() async {
      process.kill();
      await process.exitCode;
      PathProviderPlatform.instance = oldPathProvider;
      await temp.delete(recursive: true);
    });
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await locked.exists() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await locked.exists(), isTrue, reason: '独占锁测试进程必须先成功持有文件：$helperErrors');
    expect(await WindowsUpdateService().takeInstallResult(), '更新成功，当前版本 v5.5.0');
    expect(await process.exitCode, 0);
  }, skip: !Platform.isWindows);

  test('更新下载按自动镜像和两个快速备用源顺序构造 URL', () {
    expect(
      WindowsUpdateService.mirrorDownloadUris(
        'https://github.com/zzyoxml/md3Music/releases/download/v6.1.0/'
        'md3music-windows-6.1.0.zip',
      ).map((uri) => uri.host),
      ['gh.monlor.com', 'gh-proxy.com', 'fastgit.cc'],
    );
  });

  test('镜像不可用时切换备用源并校验文件大小和 SHA-256', () async {
    final temp = await Directory.systemTemp.createTemp('md3-update-test-');
    final oldPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPathProvider(temp.path);
    addTearDown(() async {
      PathProviderPlatform.instance = oldPathProvider;
      await temp.delete(recursive: true);
    });

    final payload = [1, 2, 3, 4, 5];
    final adapter = _MirrorAdapter(payload);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final service = WindowsUpdateService(dio: dio);
    final digest = sha256.convert(payload).toString();
    final release = ReleaseInfo.fromTag(
      tagName: 'v6.1.0',
      htmlUrl: 'https://github.com/zzyoxml/md3Music/releases/tag/v6.1.0',
      windowsZipUrl:
          'https://github.com/zzyoxml/md3Music/releases/download/v6.1.0/'
          'md3music-windows-6.1.0.zip',
      windowsZipSize: payload.length,
      windowsZipDigest: 'sha256:$digest',
    );

    final archive = await service.download(release, onProgress: (_, _) {});

    expect(adapter.requestedUrls, [
      'https://gh.monlor.com/https://github.com/zzyoxml/md3Music/'
          'releases/download/v6.1.0/md3music-windows-6.1.0.zip',
      'https://gh-proxy.com/https://github.com/zzyoxml/md3Music/'
          'releases/download/v6.1.0/md3music-windows-6.1.0.zip',
    ]);
    expect(await archive.readAsBytes(), payload);
  });

  test('拒绝非 GitHub HTTPS 下载地址', () {
    expect(
      () => WindowsUpdateService.mirrorDownloadUris(
        'https://example.com/update.zip',
      ),
      throwsStateError,
    );
  });
}
