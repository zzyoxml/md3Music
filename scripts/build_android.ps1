#Requires -Version 5.1
<#
.SYNOPSIS
  MD3Music Windows 一键打包脚本（PowerShell 版）

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

.EXAMPLE
  .\scripts\build_android.ps1                # 智能检测 + 打包
  .\scripts\build_android.ps1 -ForceRust     # 强制重编 Rust + 打包
  .\scripts\build_android.ps1 -SkipFlutter   # 只更新 .so
#>
[CmdletBinding()]
param(
    [switch]$ForceRust,
    [switch]$SkipFlutter,
    [string]$NdkPath
)

$ErrorActionPreference = 'Stop'
# 外部命令（cargo/flutter）的 stderr 输出会触发 NativeCommandError，需临时切回 Continue
$script:PrevEAP = $null

# ---------- 常量 ----------
$RepoRoot = Split-Path -Parent $PSScriptRoot              # scripts/.. = 项目根
$RustDir  = Join-Path $RepoRoot 'kugou_api_server\rust'
$JniDir   = Join-Path $RepoRoot 'android\app\src\main\jniLibs'
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
$Toolchain = 'stable-x86_64-pc-windows-gnu'               # msvc 缺 link.exe，用 GNU toolchain 交叉编译
# host 侧 C 编译器（编译 build-script 用，如 ring 的 cc-rs）
$HostGcc = 'C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\gcc.exe'
$HostAr  = 'C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\ar.exe'

# target -> @{abi; clang 前缀; 链接时 --target（带 API 级别，否则 clang 找不到 crt 文件）}
$ABIs = @(
    @{ target='aarch64-linux-android';   abi='arm64-v8a';   clang='aarch64-linux-android21-clang';   triple='aarch64-linux-android21' }
    @{ target='armv7-linux-androideabi'; abi='armeabi-v7a'; clang='armv7a-linux-androideabi21-clang'; triple='armv7a-linux-androideabi21' }
    @{ target='x86_64-linux-android';    abi='x86_64';      clang='x86_64-linux-android21-clang';    triple='x86_64-linux-android21' }
)

function Write-Step([string]$Msg) { Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }

# 运行外部命令：cargo/flutter 正常进度输出走 stderr，PowerShell 会视为 NativeCommandError，
# 这里临时把 ErrorActionPreference 切回 Continue 并检查退出码，真正失败再 throw。
function Invoke-Native {
    param([scriptblock]$Command)
    $script:PrevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command
        if ($LASTEXITCODE -ne 0) { throw "命令失败，退出码 $LASTEXITCODE" }
    }
    finally { $ErrorActionPreference = $script:PrevEAP }
}

# ---------- 1. 工具检测 ----------
Write-Step '检查构建工具'
$env:Path = "$CargoBin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw '未找到 cargo，请先安装 rustup（https://rustup.rs/）' }
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw '未找到 flutter，请先安装并加入 PATH' }

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
$needRust = $ForceRust
if (-not $needRust -and (Get-Command git -ErrorAction SilentlyContinue)) {
    # 工作区未提交改动（含未跟踪文件）
    $st = & git -C $RepoRoot status --porcelain -- kugou_api_server/rust/ 2>$null
    if ($LASTEXITCODE -eq 0 -and $st) { $needRust = $true }
}
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
        $ccVar  = "CC_"  + ($a.target -replace '-', '_')
        $arVar  = "AR_"  + ($a.target -replace '-', '_')
        $lnVar  = 'CARGO_TARGET_' + ($a.target -replace '-', '_').ToUpper() + '_LINKER'
        Set-Item -Path "Env:$ccVar" -Value "$NDKBin\$($a.clang).cmd"
        Set-Item -Path "Env:$arVar" -Value "$NDKBin\llvm-ar.exe"
        Set-Item -Path "Env:$lnVar" -Value "$NDKBin\clang.exe"
        # 链接时显式指定 target（带 API 级别）+ lld，clang 才能定位 sysroot 里的 crt 文件
        $env:RUSTFLAGS = "-C link-arg=--target=$($a.triple) -C link-arg=-fuse-ld=lld"
        Push-Location $RustDir
        try {
            Invoke-Native { cargo "+$Toolchain" build --target $a.target --release }
            if ($LASTEXITCODE -ne 0) { throw "cargo build 失败：$($a.target)" }
        }
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
    exit 0
}

Write-Step 'Flutter 分包打包（排除 x86）'
Push-Location $RepoRoot
try {
    Invoke-Native { flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm,android-x64 }
}
finally { Pop-Location }

Write-Step '打包完成'
$outDir = Join-Path $RepoRoot 'build\app\outputs\flutter-apk'
Get-ChildItem "$outDir\*release.apk" | ForEach-Object {
    Write-Host "    $($_.Name)  $([math]::Round($_.Length / 1MB, 1)) MB" -ForegroundColor Green
}
