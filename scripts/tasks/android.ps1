#Requires -Version 5.1
<#
.SYNOPSIS
  Android 一键打包：Rust 交叉编译（按需）+ Flutter 分包 APK。

.DESCRIPTION
  智能检测 Rust 代码是否有改动：
    - 有改动  -> 交叉编译 3 个 ABI 的 libkugou_server.so（arm64-v8a / armeabi-v7a / x86_64，不含 x86）
                并覆盖 android/app/src/main/jniLibs/
    - 无改动  -> 跳过 Rust 编译（避免无意义的全量重编），直接打包
  最后统一执行 flutter 分包打包（--split-per-abi，排除 x86）。

  依赖检测：rustup(GNU toolchain) / Android NDK / Flutter，缺失时给出明确提示。

.PARAMETER ForceRust
  忽略改动检测，强制重新交叉编译 Rust 并覆盖 jniLibs。

.PARAMETER SkipFlutter
  只做 Rust 交叉编译 + 更新 jniLibs，不执行 flutter 打包。

.PARAMETER NdkPath
  手动指定 Android NDK 目录（默认按 ANDROID_NDK_HOME / ANDROID_NDK / 常见 SDK 路径自动探测，
  取版本号最高者）。

.PARAMETER NoPause
  结束时不等待按键（CI/被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 android                # 智能检测 + 打包
  .\scripts\md3.ps1 android -ForceRust     # 强制重编 Rust + 打包
  .\scripts\md3.ps1 android -SkipFlutter   # 只更新 .so
#>
[CmdletBinding()]
param(
    [switch]$ForceRust,
    [switch]$SkipFlutter,
    [string]$NdkPath,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
# 公开导出树只携带本任务脚本（不含 lib/common.ps1）：有公共库则照常点源；
# 缺失时内联所需的最小辅助函数，保证脚本在公开树里也能独立运行。
$script:Md3CommonPath = Join-Path $PSScriptRoot '..\lib\common.ps1'
if (Test-Path $script:Md3CommonPath) {
    . $script:Md3CommonPath
} else {
    $script:Md3RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    function Get-RepoRoot { $script:Md3RepoRoot }
    function Get-Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }
    function Write-Step([string]$M) { Write-Host "`n=== $M ===" -ForegroundColor Cyan }
    function Write-Ok([string]$M)   { Write-Host "  [OK] $M" -ForegroundColor Green }
    function Write-Warn([string]$M) { Write-Host "  [!!] $M" -ForegroundColor Yellow }
    function Write-Fail([string]$M) { Write-Host "  [XX] $M" -ForegroundColor Red }
    function Write-Note([string]$M) { Write-Host "  $M" -ForegroundColor DarkGray }
    function Wait-Exit { Write-Host "`n按任意键退出..." -ForegroundColor Cyan; try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 } }
    function Invoke-Native { param([Parameter(Mandatory)][scriptblock]$Command) $p = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & $Command; if ($LASTEXITCODE -ne 0) { throw "命令失败，退出码 $LASTEXITCODE" } } finally { $ErrorActionPreference = $p } }
    function Assert-Command { param([Parameter(Mandatory)][string]$Name, [string]$Hint) if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "未找到 $Name$(if ($Hint) { "：$Hint" })" } }
    function Test-HasCommand([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
    function Add-CargoToPath { $b = Join-Path $env:USERPROFILE '.cargo\bin'; if ((Test-Path $b) -and ($env:Path -notlike "*$b*")) { $env:Path = "$b;$env:Path" } }
    function Test-RustDirty { $root = Get-RepoRoot; if (-not (Test-HasCommand git)) { return $false }; $st = & git -C $root status --porcelain -- kugou_api_server/rust/ 2>$null; ($LASTEXITCODE -eq 0) -and [bool]$st }
    function Get-PubspecVersion { $pub = Get-Content (Join-Path (Get-RepoRoot) 'pubspec.yaml') | Select-String '^version:'; if ($pub) { ($pub.ToString() -replace '^version:\s*', '' -split '\+')[0] } else { '0.0.0' } }
    function Remove-ItemBypass([string]$Path) { if (Test-Path -LiteralPath $Path) { $item = Get-Item -LiteralPath $Path -Force; if ($item -is [System.IO.DirectoryInfo]) { [System.IO.Directory]::Delete($item.FullName, $true) } else { [System.IO.File]::Delete($item.FullName) } } }
    function Sync-SettingsSearchIndex { }   # 公开树无 scripts/tools，设置为搜索索引同步为空操作
}

$RepoRoot  = Get-RepoRoot
$RustDir   = Join-Path $RepoRoot 'kugou_api_server\rust'
$JniDir    = Join-Path $RepoRoot 'android\app\src\main\jniLibs'
$Toolchain = 'stable-x86_64-pc-windows-gnu'               # msvc 缺 link.exe，用 GNU toolchain 交叉编译
# host 侧 C 编译器（编译 build-script 用，如 ring 的 cc-rs）
# 允许用环境变量覆盖；否则在常见 Dev-Cpp 安装位自动探测（文档路径优先，实际机器可能在别处）
$HostDir = $null
if ($env:MD3_DEVCPP_BIN -and (Test-Path (Join-Path $env:MD3_DEVCPP_BIN 'gcc.exe'))) {
    $HostDir = $env:MD3_DEVCPP_BIN
} else {
    $pathGcc = Get-Command gcc -ErrorAction SilentlyContinue
    if ($pathGcc -and (Test-Path (Join-Path (Split-Path -Parent $pathGcc.Source) 'ar.exe'))) {
        $HostDir = Split-Path -Parent $pathGcc.Source
    } else {
        foreach ($p in @(
            'C:\Program Files (x86)\Dev-Cpp\MinGW64\bin',
            'E:\Dev-Cpp\MinGW64\bin',
            'C:\Program Files\Dev-Cpp\MinGW64\bin',
            'C:\Dev-Cpp\MinGW64\bin'
        )) {
            if ((Test-Path $p) -and (Test-Path (Join-Path $p 'gcc.exe'))) { $HostDir = $p; break }
        }
    }
}
if (-not $HostDir) {
    $HostDir = 'C:\Program Files (x86)\Dev-Cpp\MinGW64\bin'
    Write-Host "  [!!] 未探测到 host gcc，退回默认路径 $HostDir（可用 MD3_DEVCPP_BIN 环境变量或 PATH 覆盖）" -ForegroundColor Yellow
}
$HostGcc = Join-Path $HostDir 'gcc.exe'
$HostAr  = Join-Path $HostDir 'ar.exe'

# target -> @{abi; clang 前缀; 链接时 --target（带 API 级别，否则 clang 找不到 crt 文件）}
$ABIs = @(
    @{ target='aarch64-linux-android';   abi='arm64-v8a';   clang='aarch64-linux-android21-clang';   triple='aarch64-linux-android21' }
    @{ target='armv7-linux-androideabi'; abi='armeabi-v7a'; clang='armv7a-linux-androideabi21-clang'; triple='armv7a-linux-androideabi21' }
    @{ target='x86_64-linux-android';    abi='x86_64';      clang='x86_64-linux-android21-clang';    triple='x86_64-linux-android21' }
)

# ---------- 1. 工具检测 ----------
Write-Step '检查构建工具'
Sync-SettingsSearchIndex          # 设置搜索索引：构建前静默同步（有变化才提示）
Add-CargoToPath
Assert-Command cargo   '请先安装 rustup（https://rustup.rs/）'
Assert-Command flutter '请先安装并加入 PATH'

# ---------- 2. NDK 探测 ----------
if ($NdkPath) {
    $NDK = $NdkPath
}
elseif ($env:ANDROID_NDK_HOME -and (Test-Path $env:ANDROID_NDK_HOME)) {
    $NDK = $env:ANDROID_NDK_HOME
}
elseif ($env:ANDROID_NDK -and (Test-Path $env:ANDROID_NDK)) {
    $NDK = $env:ANDROID_NDK
}
else {
    $sdkDirs = @("$env:LOCALAPPDATA\Android\Sdk\ndk", 'C:\Android\Sdk\ndk', "$env:USERPROFILE\Android\Sdk\ndk")
    $found = $null
    foreach ($d in $sdkDirs) {
        if (Test-Path $d) {
            # 优先匹配项目 build.gradle.kts 声明的 ndkVersion，避免误用更高版本导致行为漂移
            $pref = Get-ChildItem $d -Directory -ErrorAction SilentlyContinue | Where-Object Name -eq '28.2.13676358'
            $v = if ($pref) { $pref | Select-Object -First 1 }
                 else { Get-ChildItem $d -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 }
            if ($v) { $found = $v.FullName; break }
        }
    }
    if (-not $found) { throw '未找到 Android NDK，请通过 -NdkPath 指定，或安装到默认 SDK 目录' }
    $NDK = $found
}
$NDKBin = Join-Path $NDK 'toolchains\llvm\prebuilt\windows-x86_64\bin'
if (-not (Test-Path (Join-Path $NDKBin 'clang.exe'))) { throw "NDK LLVM 工具链缺失：$NDKBin" }
Write-Host "NDK: $NDK"

# ---------- 3. 判断是否需要编译 Rust ----------
$needRust = [bool]$ForceRust
if (-not $needRust) { $needRust = Test-RustDirty }
if (-not $needRust) {
    # 兜底：比较 target 产物与 jniLibs 的修改时间，.so 比 jniLibs 新说明 Rust 编译过但未同步
    foreach ($a in $ABIs) {
        $src = Join-Path $RustDir "target\$($a.target)\release\libkugou_server.so"
        $dst = Join-Path $JniDir "$($a.abi)\libkugou_server.so"
        if ((Test-Path $src) -and (Test-Path $dst) -and
            (Get-Item $src).LastWriteTime -gt (Get-Item $dst).LastWriteTime) { $needRust = $true }
    }
}

# ---------- 4. 交叉编译 Rust（仅当有改动时） ----------
if ($needRust) {
    Write-Step "检测到 Rust 代码改动，开始交叉编译（$Toolchain）"
    if (-not (Test-Path $HostGcc)) { throw "host gcc 缺失（build-script 需要）：$HostGcc" }
    $env:CC_x86_64_pc_windows_gnu = $HostGcc
    $env:AR_x86_64_pc_windows_gnu = $HostAr

    foreach ($a in $ABIs) {
        Write-Host "==> 构建 $($a.abi) ($($a.target))" -ForegroundColor Yellow
        # cc-rs / cargo 读取的环境变量：CC_/AR_ 用小写 target（- 转 _），linker 必须大写
        $ccVar = 'CC_' + ($a.target -replace '-', '_')
        $arVar = 'AR_' + ($a.target -replace '-', '_')
        $lnVar = 'CARGO_TARGET_' + ($a.target -replace '-', '_').ToUpper() + '_LINKER'
        Set-Item -Path "Env:$ccVar" -Value "$NDKBin\$($a.clang).cmd"
        Set-Item -Path "Env:$arVar" -Value "$NDKBin\llvm-ar.exe"
        Set-Item -Path "Env:$lnVar" -Value "$NDKBin\clang.exe"
        # 链接时显式指定 target（带 API 级别）+ lld，clang 才能定位 sysroot 里的 crt 文件
        $env:RUSTFLAGS = "-C link-arg=--target=$($a.triple) -C link-arg=-fuse-ld=lld"
        Push-Location $RustDir
        try { Invoke-Native { cargo "+$Toolchain" build --target $a.target --release } }
        finally { Pop-Location }
    }
    Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue

    # 复制 .so 到 jniLibs（x86 按需求跳过）
    Write-Step '更新 jniLibs'
    foreach ($a in $ABIs) {
        $src = Join-Path $RustDir "target\$($a.target)\release\libkugou_server.so"
        $dstDir = Join-Path $JniDir $a.abi
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Copy-Item $src (Join-Path $dstDir 'libkugou_server.so') -Force
        Write-Host "    $($a.abi): $([math]::Round((Get-Item $src).Length / 1MB, 1)) MB" -ForegroundColor Green
    }
}
else {
    Write-Host 'Rust 代码无改动，跳过交叉编译（如需强制重编，加 -ForceRust）' -ForegroundColor DarkYellow
}

# ---------- 5. Flutter 分包打包（排除 x86） ----------
if ($SkipFlutter) {
    Write-Host "`n完成（-SkipFlutter）。jniLibs 已就绪，可用 flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm,android-x64 手动打包" -ForegroundColor Green
    if (-not $NoPause) { Wait-Exit }
    exit 0
}

Write-Step 'Flutter 分包打包（排除 x86）'
Push-Location $RepoRoot
try {
    # 入口自动选择：
    #   - 私有仓库：存在 lib/private/main_private.dart → 构建完整功能版（含下载/缓存）
    #   - 公开树（md3.ps1 export 导出）：lib/private 已被排除 → 回退默认公开入口 lib/main.dart
    $target = 'lib/main.dart'
    if (Test-Path (Join-Path $RepoRoot 'lib\private\main_private.dart')) {
        $target = 'lib/private/main_private.dart'
    }
    Invoke-Native { flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm,android-x64 -t $target }
}
finally { Pop-Location }

Write-Step '打包完成'
$outDir = Join-Path $RepoRoot 'build\app\outputs\flutter-apk'
Get-ChildItem "$outDir\*release.apk" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "    $($_.Name)  $([math]::Round($_.Length / 1MB, 1)) MB" -ForegroundColor Green
}

if (-not $NoPause) { Wait-Exit }
