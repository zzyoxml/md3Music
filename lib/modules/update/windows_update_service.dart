import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/repositories/settings_repository.dart';
import 'github_release_client.dart';
import 'release_info.dart';
import 'release_version.dart';

/// Windows 便携版 Release 检查与更新包下载。
class WindowsUpdateService {
  WindowsUpdateService({
    GithubReleaseClient? releases,
    SettingsRepository? settings,
    Dio? dio,
  }) : _releases = releases ?? GithubReleaseClient(),
       _settings = settings ?? SettingsRepository(),
       _dio = dio ?? Dio();

  static final WindowsUpdateService instance = WindowsUpdateService();
  static const List<String> downloadMirrorPrefixes = [
    'https://gh.monlor.com/',
    'https://gh-proxy.com/',
    'https://fastgit.cc/',
  ];

  static List<Uri> mirrorDownloadUris(String downloadUrl) {
    final uri = Uri.parse(downloadUrl);
    if (uri.scheme != 'https' || uri.host != 'github.com') {
      throw StateError('更新包下载地址无效');
    }
    return downloadMirrorPrefixes
        .map((prefix) => Uri.parse('$prefix$downloadUrl'))
        .toList(growable: false);
  }

  final GithubReleaseClient _releases;
  final SettingsRepository _settings;
  final Dio _dio;
  bool _checking = false;

  Future<ReleaseInfo?> checkForUpdate({bool manual = false}) async {
    if (_checking) return null;
    _checking = true;
    try {
      if (!manual && !await _settings.getUpdateReminderEnabled()) return null;

      final release = await _releases.fetchLatestDetails();
      if (release == null || release.windowsZipUrl == null) return null;

      final current = (await PackageInfo.fromPlatform()).version;
      if (!isNewerRelease(release.version, current)) return null;
      // Windows 每次启动都允许提示尚未安装的版本；不沿用 Android 的
      // 12 小时节流和跨启动「已提醒」标记，否则点过稍后就再也看不到弹窗。
      return release;
    } catch (error, stack) {
      debugPrint('[WindowsUpdate] 检查更新失败：$error\n$stack');
      return null;
    } finally {
      _checking = false;
    }
  }

  Future<File> download(
    ReleaseInfo release, {
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final downloadUrl = release.windowsZipUrl;
    if (downloadUrl == null) throw StateError('Release 没有 Windows ZIP 资产');
    final mirrorUris = mirrorDownloadUris(downloadUrl);

    final tempDir = await getTemporaryDirectory();
    final updateDir = await Directory(
      '${tempDir.path}${Platform.pathSeparator}md3music-update-${release.version}',
    ).create(recursive: true);
    final archive = File(
      '${updateDir.path}${Platform.pathSeparator}md3music-windows-${release.version}.zip',
    );
    Object? lastError;
    for (final uri in mirrorUris) {
      final cancelError = cancelToken?.cancelError;
      if (cancelError != null) throw cancelError;
      if (await archive.exists()) await archive.delete();
      final stopwatch = Stopwatch()..start();
      debugPrint('[WindowsUpdate] 开始下载镜像 ${uri.host}');
      try {
        await _dio.download(
          uri.toString(),
          archive.path,
          cancelToken: cancelToken,
          onReceiveProgress: onProgress,
          options: Options(
            headers: const {'User-Agent': GithubReleaseClient.userAgent},
            receiveTimeout: const Duration(minutes: 10),
          ),
        );

        if (release.windowsZipSize != null &&
            await archive.length() != release.windowsZipSize) {
          throw StateError('更新包大小校验失败');
        }

        final expectedDigest = release.windowsZipDigest;
        if (expectedDigest != null && expectedDigest.startsWith('sha256:')) {
          final actual = await sha256.bind(archive.openRead()).first;
          if (actual.toString().toLowerCase() !=
              expectedDigest.substring('sha256:'.length).toLowerCase()) {
            throw StateError('更新包校验失败');
          }
        }
        final bytes = await archive.length();
        final seconds = stopwatch.elapsedMilliseconds / 1000;
        debugPrint(
          '[WindowsUpdate] 镜像 ${uri.host} 下载完成：$bytes bytes，'
          '${seconds.toStringAsFixed(1)}s，'
          '${(bytes / (seconds <= 0 ? 1 : seconds) / (1024 * 1024)).toStringAsFixed(2)} MB/s',
        );
        return archive;
      } catch (error) {
        if ((error is DioException && CancelToken.isCancel(error)) ||
            (cancelToken?.isCancelled ?? false)) {
          if (await archive.exists()) await archive.delete();
          rethrow;
        }
        lastError = error;
        debugPrint(
          '[WindowsUpdate] 镜像 ${uri.host} 失败（${stopwatch.elapsedMilliseconds}ms）：$error',
        );
        if (await archive.exists()) await archive.delete();
      }
    }
    throw StateError('所有更新镜像均下载失败或校验未通过：$lastError');
  }

  /// 启动独立 PowerShell 更新进程，并在其准备好后安全退出当前程序。
  Future<void> installAndExit(
    File archive, {
    required String expectedVersion,
  }) async {
    final executable = File(Platform.resolvedExecutable);
    final targetDir = executable.parent;
    final probe = File(
      '${targetDir.path}${Platform.pathSeparator}.md3-update-write-check',
    );
    try {
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      throw StateError('当前程序目录没有写入权限，请把程序移到用户可写目录后重试');
    }

    final tempDir = await getTemporaryDirectory();
    final statusFile = await _installStatusFile();
    final attempt = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final script = File(
      '${tempDir.path}${Platform.pathSeparator}md3music-updater-$attempt.ps1',
    );
    final ready = File('${script.path}.ready');
    final failed = File('${script.path}.failed');
    debugPrint(
      '[WindowsUpdate] 启动安装器；更新日志：'
      '${tempDir.path}${Platform.pathSeparator}md3music-updater-$pid.log',
    );
    await script.writeAsBytes(utf8.encode('\uFEFF$_updaterScript'), flush: true);
    final updater = await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-AppProcessId',
        '$pid',
        '-ArchivePath',
        archive.path,
        '-TargetPath',
        targetDir.path,
        '-ExpectedVersion',
        expectedVersion,
        '-StatusPath',
        statusFile.path,
        '-ReadyPath',
        ready.path,
      ],
      workingDirectory: tempDir.path,
      // Windows PowerShell 在 Dart detached 模式下会在执行脚本前退出。
      // 保留标准句柄，等脚本解压、校验并写回 ready 后才交接退出。
      mode: ProcessStartMode.normal,
    );
    final errors = StringBuffer();
    updater.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
      (message) => debugPrint('[WindowsUpdate] $message'),
    );
    updater.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
      errors.write,
    );
    await updater.stdin.close();
    int? exitCode;
    updater.exitCode.then((value) => exitCode = value);
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    try {
      while (DateTime.now().isBefore(deadline)) {
        // 就绪标记只创建一次，只检查存在性，不再反复读写同一个 JSON 文件。
        // Windows 上热读 + Move-Item 覆盖会互相争锁，导致错误 32。
        if (await failed.exists()) {
          throw StateError('更新包准备失败，当前版本未改动。日志：'
              '${tempDir.path}${Platform.pathSeparator}md3music-updater-$pid.log');
        }
        if (await ready.exists()) return;
        if (exitCode != null) {
          throw StateError('更新程序未能就绪（退出码 $exitCode）：$errors');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('更新包准备超时，当前版本未退出、未覆盖，请重试');
    } catch (_) {
      // 交接失败时取消该安装器，避免用户重试后残留多个等待退出的更新进程。
      updater.kill();
      rethrow;
    }
  }

  Future<File> _installStatusFile() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}windows-update-result.json');
  }

  /// 重启后核对实际版本再反馈，不将「已启动安装器」误报为更新成功。
  Future<String?> takeInstallResult() async {
    final file = await _installStatusFile();
    for (var attempt = 0; ; attempt++) {
      try {
        if (!await file.exists()) return null;
        final status = jsonDecode(
          (await file.readAsString()).replaceFirst('\uFEFF', ''),
        ) as Map;
        if (status['status'] != 'completed' && status['status'] != 'failed') {
          return null;
        }
        final current = (await PackageInfo.fromPlatform()).version;
        await file.delete();
        if (status['status'] == 'completed') {
          if (current == status['version']) return '更新成功，当前版本 v$current';
          return '更新未生效：当前仍为 v$current，目标为 v${status['version']}';
        }
        return '更新失败：${status['message']}；日志：${status['logPath']}';
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if ((code != 32 && code != 33) || attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  static const String _updaterScript = r'''
param(
  [Parameter(Mandatory=$true)][int]$AppProcessId,
  [Parameter(Mandatory=$true)][string]$ArchivePath,
  [Parameter(Mandatory=$true)][string]$TargetPath,
  [Parameter(Mandatory=$true)][string]$ExpectedVersion,
  [Parameter(Mandatory=$true)][string]$StatusPath,
  [Parameter(Mandatory=$true)][string]$ReadyPath
)
$ErrorActionPreference = 'Stop'
$TargetPath = [System.IO.Path]::GetFullPath($TargetPath)
$ParentPath = Split-Path -Parent $TargetPath
$Token = [Guid]::NewGuid().ToString('N')
$StagePath = Join-Path $ParentPath ".md3music-update-$Token"
$BackupPath = Join-Path $ParentPath ".md3music-backup-$Token"
$ScriptPath = $PSCommandPath
$LogPath = Join-Path $env:TEMP "md3music-updater-$AppProcessId.log"
function Write-UpdateLog([string]$Message) {
  Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}
function Write-UpdateStatus([string]$State, [string]$Message) {
  $Result = @{status=$State; message=$Message; version=$ExpectedVersion; logPath=$LogPath} | ConvertTo-Json -Compress
  for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
    try {
      $Result | Set-Content -LiteralPath "$StatusPath.$Token.tmp" -Encoding UTF8
      Move-Item -LiteralPath "$StatusPath.$Token.tmp" -Destination $StatusPath -Force
      return
    } catch { Start-Sleep -Milliseconds 100 }
  }
  # 结果记录失败不得使已经安装成功的程序被误回滚，详细结果仍在独立日志中。
  Write-UpdateLog "结果文件暂不可写：$StatusPath；状态：$State；$Message"
}
function Move-UpdateDirectory([string]$Source, [string]$Destination) {
  for ($Attempt = 0; ; $Attempt++) {
    try { Move-Item -LiteralPath $Source -Destination $Destination; return } catch {
      $Code = $_.Exception.HResult -band 0xFFFF
      if ($Code -notin 5, 32, 33 -or $Attempt -ge 49) { throw }
      if ($Attempt -eq 0) { Write-UpdateLog "应用目录暂被占用，等待句柄释放：$Source" }
      Start-Sleep -Milliseconds 200
    }
  }
}
function Show-UpdateResult([string]$Message, [bool]$Failed) {
  # 独立安装器没有 Flutter 引擎，使用 Windows 原生气泡通知，不弹阻塞式错误框。
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $Notice = New-Object System.Windows.Forms.NotifyIcon
    $Notice.Icon = if ($Failed) { [System.Drawing.SystemIcons]::Error } else { [System.Drawing.SystemIcons]::Information }
    $Notice.Visible = $true
    $Notice.ShowBalloonTip(5000, 'MD3Music 更新', $Message, [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 6
    $Notice.Dispose()
  } catch { Write-UpdateLog "系统通知不可用：$($_.Exception.Message)" }
}
try {
  Write-UpdateLog "开始更新；目标目录：$TargetPath；压缩包：$ArchivePath"
  if ($TargetPath -eq [System.IO.Path]::GetPathRoot($TargetPath) -or
      -not (Test-Path -LiteralPath (Join-Path $TargetPath 'md3Music.exe'))) { throw '目标应用目录无效' }
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $StagePath -Force
  $PayloadPath = if (Test-Path (Join-Path $StagePath 'App\md3Music.exe')) {
    Join-Path $StagePath 'App'
  } elseif (Test-Path (Join-Path $StagePath 'md3Music.exe')) {
    $StagePath
  } else {
    throw '更新包中找不到 md3Music.exe'
  }
  $NewPath = "$TargetPath.new-$Token"
  New-Item -ItemType Directory -Path $NewPath | Out-Null
  Copy-Item -Path (Join-Path $PayloadPath '*') -Destination $NewPath -Recurse -Force
  if (-not (Test-Path (Join-Path $NewPath 'md3Music.exe'))) { throw '更新文件复制不完整' }
  $ActualVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $NewPath 'md3Music.exe')).ProductVersion.Split('+')[0]
  if ($ActualVersion -ne $ExpectedVersion) { throw "更新包版本不匹配：预期 $ExpectedVersion，实际 $ActualVersion" }
  Write-UpdateLog "更新文件已暂存并校验为 v$ActualVersion，等待旧进程退出"
  [System.IO.File]::WriteAllText($ReadyPath, '')
  $ExitDeadline = (Get-Date).AddSeconds(45)
  while (Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue) {
    if ((Get-Date) -gt $ExitDeadline) { throw '当前程序未能退出，已取消覆盖安装' }
    Start-Sleep -Milliseconds 200
  }
  Write-UpdateLog '旧进程已退出，开始替换应用目录'
  Move-UpdateDirectory $TargetPath $BackupPath
  try {
    Move-UpdateDirectory $NewPath $TargetPath
  } catch {
    Move-UpdateDirectory $BackupPath $TargetPath
    throw
  }
  # 先落盘，重启后的应用可立即核对自身版本并提示结果；启动失败时覆盖为 failed。
  Write-UpdateStatus 'completed' "已安装 v$ActualVersion，正在启动应用"
  $UpdatedProcess = Start-Process -FilePath (Join-Path $TargetPath 'md3Music.exe') -WorkingDirectory $TargetPath -PassThru
  Start-Sleep -Seconds 2
  if ($UpdatedProcess.HasExited) {
    throw "更新后的程序启动失败（退出码 $($UpdatedProcess.ExitCode)）"
  }
  Write-UpdateLog "更新应用已启动；PID：$($UpdatedProcess.Id)"
  Remove-Item -LiteralPath $BackupPath -Recurse -Force -ErrorAction SilentlyContinue
  Show-UpdateResult "已成功更新至 v$ActualVersion，并重新打开应用。" $false
} catch {
  $FailureMessage = $_.Exception.Message
  Write-UpdateLog "更新失败：$($_ | Out-String)"
  if (Test-Path $BackupPath) {
    if (Test-Path $TargetPath) {
      Remove-Item -LiteralPath $TargetPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Move-UpdateDirectory $BackupPath $TargetPath
    Write-UpdateLog '已回滚到更新前版本'
  }
  $RollbackExe = Join-Path $TargetPath 'md3Music.exe'
  if ((Test-Path $RollbackExe) -and -not (Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue)) {
    try {
      Start-Process -FilePath $RollbackExe -WorkingDirectory $TargetPath | Out-Null
      Write-UpdateLog '已重新启动当前版本，避免更新失败后应用关闭'
    } catch {
      Write-UpdateLog "重新启动当前版本失败：$($_.Exception.Message)"
    }
  }
  Write-UpdateStatus 'failed' $FailureMessage
  [System.IO.File]::WriteAllText(($ScriptPath + '.failed'), '')
  Show-UpdateResult "更新失败：$FailureMessage。原版本已保留。日志：$LogPath" $true
  exit 1
} finally {
  Remove-Item -LiteralPath $StagePath -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath "$TargetPath.new-$Token" -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $BackupPath) { Write-UpdateLog "原版本备份保留于：$BackupPath" }
  Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
}
''';
}
