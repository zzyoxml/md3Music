#Requires -Version 5.1
<#
.SYNOPSIS
  Android 一键打包：Rust 交叉编译（按需）+ Flutter 分包 APK。

.DESCRIPTION
  智能检测 Rust 代码是否有改动：
    - 有改动  -> 交叉编译 3 个 ABI 的 libkugou_server.so（arm64-v8a / armeabi-v7a / x86_64，不含 x86）
                并覆盖 android/app/src/main/jniLibs/
    - 无改动  -> 跳过 Rust 编译（避免无意义的全量重编），直接打包

  随后按 -BuildType / -Flavor / -Abi 组合调用 flutter 打包（默认 release + 两个 flavor + 全部 ABI）：
    - flavor standard：无 3D 封面（不含 onnxruntime so / 深度模型），v8a / v7a / x64
    - flavor depth3d ：3D 全量（内置 onnxruntime so + Depth Anything V2 模型）＋ 需 --dart-define=ENABLE_DEPTH_3D=true，
                       仅 arm64-v8a（ORT AAR 只含该 ABI）
    - Apple Music 兼容包（app-apple-music-arm64-v8a-*.apk）：Vivo 原子随身听按包名识别合作应用，
                       故基于 standard flavor 再出一份 applicationId=com.apple.android.music 的 arm64 包
                       （不含 3D；standard flavor 且 ABI 含 arm64 时自动产出，-NoAppleMusic 可跳过）

  打包后逐个自检产物内容（jniLibs / 3D 资产是否与 flavor 匹配、包名是否符合预期），
  再把产物命名与正式 CI 对齐（Gradle/Flutter 内部命名不动，见 common.ps1 的
  Get-ApkDisplayName），随后清理不符合发布命名的历史产物。
  依赖检测：rustup(GNU toolchain，仅在需要编 Rust 时校验；android target 缺失时自动补装)
  / Android NDK / Flutter，缺失时给出明确提示。

.PARAMETER ForceRust
  忽略改动检测，强制重新交叉编译 Rust 并覆盖 jniLibs。

.PARAMETER SkipFlutter
  只做 Rust 交叉编译 + 更新 jniLibs，不执行 flutter 打包。

.PARAMETER BuildType
  release（默认）/ debug。debug 走真机调试快路径（保留符号、logcat 可抓），单 flavor 单 ABI 约 1~2 分钟。

.PARAMETER Flavor
  both（默认）/ standard / depth3d。日常 3D 迭代用 -Flavor depth3d 只出 3D 包。
  tv（TV 版独立包体：遥控导航 + 排除 3D/USB/歌词推送，仅 arm64-v8a）

.PARAMETER Abi
  all（默认：arm64-v8a + armeabi-v7a + x86_64）/ 单个 ABI。
  depth3d flavor 只有 arm64-v8a，不随本参数缩小（传非 arm64 时会提示）。

.PARAMETER NoAppleMusic
  跳过 Apple Music（Vivo 原子随身听）兼容包。默认在 standard flavor 且 ABI 含 arm64-v8a 时自动产出，
  与 CI 发布产出一致；调试时可用它省下一次重复构建（每次约 +30~60s）。

.PARAMETER NdkPath
  手动指定 Android NDK 目录（默认按 ANDROID_NDK_HOME / ANDROID_NDK / ANDROID_SDK_ROOT / ANDROID_HOME
  / 常见 SDK 路径自动探测，
  取版本号最高者；注意 externalNativeBuild 的 CMake 构建同样需要它）。

.PARAMETER NoPause
  结束时不等待按键（CI/被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 android                                   # release：standard 3 ABI + depth3d arm64 + AM 兼容包（共 5 包）
  .\scripts\md3.ps1 android -BuildType debug -Flavor depth3d   # 3D 调试快路径（单包）
  .\scripts\md3.ps1 android -Flavor standard -Abi arm64-v8a    # 只出 standard arm64 + AM 兼容包
  .\scripts\md3.ps1 android -NoAppleMusic                      # 不要 AM 兼容包
  .\scripts\md3.ps1 android -ForceRust                         # 强制重编 Rust + 打包
  .\scripts\md3.ps1 android -SkipFlutter                       # 只更新 .so
#>
[CmdletBinding()]
param(
    [switch]$ForceRust,
    [switch]$SkipFlutter,
    [string]$NdkPath,
    [ValidateSet('release', 'debug')][string]$BuildType = 'release',
    [ValidateSet('both', 'standard', 'depth3d', 'tv')][string]$Flavor = 'both',
    [ValidateSet('all', 'arm64-v8a', 'armeabi-v7a', 'x86_64')][string]$Abi = 'all',
    [switch]$NoAppleMusic,
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
    function Test-RustStaleLibrary { param([string]$JniDir, [string[]]$Abis = @('arm64-v8a','armeabi-v7a','x86_64')) $root = Get-RepoRoot; $rustDir = Join-Path $root 'kugou_api_server\rust'; if (-not $JniDir) { $JniDir = Join-Path $root 'android\app\src\main\jniLibs' }; $inputs = @(Get-ChildItem (Join-Path $rustDir 'src') -File -Recurse -ErrorAction SilentlyContinue); $inputs += @(Get-ChildItem (Join-Path $rustDir 'Cargo.*') -File -ErrorAction SilentlyContinue); if (-not $inputs.Count) { return $false }; $newest = ($inputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc; foreach ($abi in $Abis) { $dst = Join-Path $JniDir "$abi\libkugou_server.so"; if (-not (Test-Path $dst)) { return $true }; if ($newest -gt (Get-Item $dst).LastWriteTimeUtc) { return $true } }; return $false }
    function Remove-ItemBypass([string]$Path) { if (Test-Path -LiteralPath $Path) { $item = Get-Item -LiteralPath $Path -Force; if ($item -is [System.IO.DirectoryInfo]) { [System.IO.Directory]::Delete($item.FullName, $true) } else { [System.IO.File]::Delete($item.FullName) } } }
    function Get-PubspecVersion { $pub = Get-Content (Join-Path (Get-RepoRoot) 'pubspec.yaml') | Select-String '^version:'; if ($pub) { ($pub.ToString() -replace '^version:\s*', '' -split '\+')[0] } else { '0.0.0' } }
    function Get-ApkDisplayName { param([Parameter(Mandatory)][string]$Abi, [Parameter(Mandatory)][string]$Flavor, [Parameter(Mandatory)][ValidateSet('release','debug')][string]$BuildType, [string]$Version) if (-not $Version) { $Version = Get-PubspecVersion }; $s = if ($BuildType -eq 'debug') { '-debug' } else { '' }; "MD3Music-$Version-$Flavor-$Abi$s.apk" }
    function Get-ApkDisplayPattern { '^MD3Music-[0-9A-Za-z.+-]+-(standard|depth3d|apple-music|tv)-(arm64-v8a|armeabi-v7a|x86_64|universal)(-debug)?\.apk$' }
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
Assert-Command flutter '请先安装并加入 PATH'
# cargo 只在真正需要编 Rust 时才校验（见第 4 节）：纯 Flutter 重打包的机器不必装 rustup

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
    # 优先使用 Android SDK 标准环境变量；兼容未设置环境变量的常见默认目录。
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME) |
        Where-Object { $_ -and (Test-Path $_) } |
        Select-Object -Unique
    $sdkDirs = @(
        ($sdkRoots | ForEach-Object { Join-Path $_ 'ndk' }),
        "$env:LOCALAPPDATA\Android\Sdk\ndk",
        'C:\Android\Sdk\ndk',
        "$env:USERPROFILE\Android\Sdk\ndk"
    ) | Where-Object { $_ } | Select-Object -Unique
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
    # 已提交、工作区干净时 git 看不出改动；比"源码 vs 已入库 .so"的新鲜度（见 common.ps1 注释）。
    # 旧兜底比的是 target 产物 vs jniLibs，两者由同一次 Copy-Item 产生、时间戳恒等，永不触发。
    $needRust = Test-RustStaleLibrary -JniDir $JniDir -Abis @($ABIs.abi)
}

# ---------- 4. 交叉编译 Rust（仅当有改动时） ----------
if ($needRust) {
    Write-Step "检测到 Rust 代码改动，开始交叉编译（$Toolchain）"
    Assert-Command cargo '请先安装 rustup（https://rustup.rs/）'
    # android target 是按 toolchain 分开安装的：$Toolchain 被 rustup update 重建后会丢掉它们，
    # 缺失时 rustc 只报 `can't find crate for core`（看不出真实原因），故先补齐
    # （与 build_android.sh 第 2 步同口径；注意不能用默认 toolchain 的 target 列表判断）
    if (Test-HasCommand rustup) {
        $installedTargets = @(& rustup target list --installed --toolchain $Toolchain 2>$null)
        foreach ($a in $ABIs) {
            if ($installedTargets -notcontains $a.target) {
                Write-Host "  安装 rustup target：$($a.target)" -ForegroundColor Yellow
                Invoke-Native { rustup target add --toolchain $Toolchain $a.target }
            }
        }
    } else {
        Write-Warn "未检测到 rustup：跳过 android target 检查（请确认 $Toolchain 已装 3 个 android target）"
    }
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
    Write-Host 'Rust 代码无改动且已入库 .so 比源码新，跳过交叉编译（如需强制重编，加 -ForceRust）' -ForegroundColor DarkYellow
}

# ---------- 5. Flutter 分包打包 ----------
# gradle/flutter 把构建进度与警告写到 stderr；PS 5.1 会把它们包装成 ErrorRecord，
# 控制台于是显示成一堆红色 RemoteException 块 —— 既吵，又与真正的失败混在一起难以分辨。
# 这里统一转成纯文本走 stdout：WARNING / 真实错误文本一条不丢（便于日志重定向），
# 同时丢掉无消息的进度条残留（它们只会退化成类型名）。
function Convert-NativeStream {
    process {
        $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
        if ($text -and $text -ne 'System.Management.Automation.RemoteException') { $text }
    }
}

$typeFlag = if ($BuildType -eq 'debug') { '--debug' } else { '--release' }
$suffix   = $BuildType   # flutter 产物名里的构建类型段：debug / release

if ($SkipFlutter) {
    Write-Host "`n完成（-SkipFlutter）。jniLibs 已就绪，可用 flutter build apk $typeFlag --flavor standard|depth3d --split-per-abi --target-platform android-arm64,android-arm,android-x64 手动打包" -ForegroundColor Green
    if (-not $NoPause) { Wait-Exit }
    exit 0
}

# ABI -> flutter --target-platform 目标（depth3d 恒为 arm64：ORT AAR 只含该 ABI）
$abiTargets = switch ($Abi) {
    'arm64-v8a'   { @('android-arm64') }
    'armeabi-v7a' { @('android-arm') }
    'x86_64'      { @('android-x64') }
    default       { @('android-arm64', 'android-arm', 'android-x64') }
}
$wantStandard = $Flavor -in @('both', 'standard')
$wantDepth3d  = $Flavor -in @('both', 'depth3d')
$wantTv       = $Flavor -eq 'tv'
# flutter --target-platform 目标名 -> APK 产物里的 ABI 段
$abiOf = @{ 'android-arm64' = 'arm64-v8a'; 'android-arm' = 'armeabi-v7a'; 'android-x64' = 'x86_64' }
# Apple Music 兼容包固定 standard flavor + arm64-v8a（与 CI 发布口径一致）
$wantAppleMusic = (-not $NoAppleMusic) -and $wantStandard -and ($abiTargets -contains 'android-arm64')
if ($wantDepth3d -and $Abi -notin @('all', 'arm64-v8a')) {
    Write-Warn "depth3d flavor 只有 arm64-v8a（ORT AAR 仅含该 ABI）：-Abi $Abi 只影响 standard 包"
}
if ($wantTv) {
    Write-Note 'tv 包恒为 arm64-v8a，与 -Abi 无关（TV 版仅此 ABI）'
}
if ($NoAppleMusic -and $wantStandard -and ($abiTargets -contains 'android-arm64')) {
    Write-Note '已按要求跳过 Apple Music 兼容包（-NoAppleMusic）'
}
elseif ($wantStandard -and -not ($abiTargets -contains 'android-arm64')) {
    Write-Note "-Abi $Abi 不含 arm64-v8a：跳过 Apple Music 兼容包（它只有 arm64 版本）"
}

# 产物目录 / 入口选择（入口不影响 Push-Location 之外的逻辑，先算好供 Apple Music 段复用）：
#   - 私有仓库：存在 lib/private/main_private.dart → 构建完整功能版（含下载/缓存）
#   - 公开树（md3.ps1 export 导出）：lib/private 已被排除 → 回退默认公开入口 lib/main.dart
$outDir      = Join-Path $RepoRoot 'build\app\outputs\flutter-apk'
$amBackupDir = Join-Path $outDir '.apple-music-backup'
$target = 'lib/main.dart'
if (Test-Path (Join-Path $RepoRoot 'lib\private\main_private.dart')) {
    $target = 'lib/private/main_private.dart'
}

Write-Step "Flutter 打包（$BuildType / flavor=$Flavor / abi=$Abi）"
Push-Location $RepoRoot
try {
    # standard flavor：不含 3D 封面（无 onnxruntime so / 深度模型）
    if ($wantStandard) {
        Invoke-Native { flutter build apk $typeFlag --flavor standard --split-per-abi --target-platform ($abiTargets -join ',') -t $target 2>&1 | Convert-NativeStream }
    }
    # depth3d flavor：3D 全量包（内置 onnxruntime so + 深度模型资产）；编译期开关必须显式打开
    if ($wantDepth3d) {
        Invoke-Native { flutter build apk $typeFlag --flavor depth3d --dart-define=ENABLE_DEPTH_3D=true --split-per-abi --target-platform android-arm64 -t $target 2>&1 | Convert-NativeStream }
    }
    # TV 版包体：MD3_TV 旗标启用 dpad 遥控导航；不传 ENABLE_DEPTH_3D（无 3D 封面）。
    # Dart 侧由 kTvBuild（lib/core/build_flags.dart）树摇：正常包剔除 TV 代码，
    # TV 包剔除 USB 独占/歌词推送。
    if ($wantTv) {
        Invoke-Native { flutter build apk $typeFlag --flavor tv --dart-define=MD3_TV=true --split-per-abi --target-platform android-arm64 -t $target 2>&1 | Convert-NativeStream }
    }
    # Apple Music（Vivo 原子随身听）兼容包：只覆盖 applicationId，namespace / Kotlin 包路径
    # / MethodChannel 名均不变（见 build.gradle.kts 的 md3ApplicationId 读取）。
    # flutter 会以「同名 standard 包」覆盖输出，故先备份 → 构建 → 改名为 AM 包 → 恢复备份。
    if ($wantAppleMusic) {
        $stdApk = Join-Path $outDir "app-arm64-v8a-standard-$suffix.apk"
        if (-not (Test-Path -LiteralPath $stdApk)) {
            Write-Warn "未找到 $(Split-Path -Leaf $stdApk)，跳过 Apple Music 兼容包"
        } else {
            New-Item -ItemType Directory -Force -Path $amBackupDir | Out-Null
            $backup = Join-Path $amBackupDir (Split-Path -Leaf $stdApk)
            Copy-Item -LiteralPath $stdApk -Destination $backup -Force
            Write-Host '==> Apple Music 兼容包（standard / arm64-v8a / applicationId=com.apple.android.music）' -ForegroundColor Yellow
            try {
                Invoke-Native { flutter build apk $typeFlag --flavor standard --split-per-abi --target-platform android-arm64 --android-project-arg=md3ApplicationId=com.apple.android.music -t $target 2>&1 | Convert-NativeStream }
                Move-Item -LiteralPath $stdApk -Destination (Join-Path $outDir "app-apple-music-arm64-v8a-$suffix.apk") -Force
            }
            finally { Copy-Item -LiteralPath $backup -Destination $stdApk -Force }
        }
    }
}
finally { Pop-Location }
if (Test-Path -LiteralPath $amBackupDir) { Remove-ItemBypass $amBackupDir }

# 无需重命名：flutter 产出 app-<abi>-<flavor>-<构建类型>.apk（实测 abi 在前）。
# 本次期望产出清单：自检与「本次构建」标记都以它为准（而非目录里现存的任意包）
$expectNames = @()
if ($wantStandard)   { foreach ($t in $abiTargets) { $expectNames += "app-$($abiOf[$t])-standard-$suffix.apk" } }
if ($wantDepth3d)    { $expectNames += "app-arm64-v8a-depth3d-$suffix.apk" }
if ($wantTv)         { $expectNames += "app-arm64-v8a-tv-$suffix.apk" }
if ($wantAppleMusic) { $expectNames += "app-apple-music-arm64-v8a-$suffix.apk" }

# ---------- 6. 产物自检：flavor 与包内容必须匹配 ----------
# 用 .NET 的 zip 读取（不依赖本机 unzip）逐个断言 jniLibs 与 3D 资产：
# depth3d 必须含 onnxruntime so + 两个深度模型，standard 必须一个都没有（flavor 隔离）。
# 另用 aapt2 校验包名（Apple Music 兼容包 = com.apple.android.music，其余 = 默认包名）；
# 找不到 aapt2 时降级为「仅内容校验」并给出提示，不阻断打包。
Write-Step '产物自检'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-ApkEntries([string]$Path) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try { @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
}
# 在 APK 的 lib/arm64-v8a/libapp.so 里找 Dart 符号名（AOT 快照保留 ASCII 标识符；
# 未开 --obfuscate，类/函数名可检索）。用于校验 TV 代码双向不编入。
function Test-ApkDartSymbol {
    param([Parameter(Mandatory)][string]$Apk, [Parameter(Mandatory)][string]$Symbol, [Parameter(Mandatory)][bool]$ExpectPresent)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
    try {
        $entry = $zip.GetEntry('lib/arm64-v8a/libapp.so')
        if (-not $entry) { return (-not $ExpectPresent) }
        $ms = New-Object System.IO.MemoryStream
        $entry.Open().CopyTo($ms)
        $text = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
        $ms.Dispose()
        return ($text.Contains($Symbol) -eq $ExpectPresent)
    } finally { $zip.Dispose() }
}
function Find-Aapt2 {
    $cands = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, 'C:\Android\Sdk') | Where-Object { $_ }
    $lp = Join-Path $RepoRoot 'android\local.properties'
    if (Test-Path -LiteralPath $lp) {
        $line = Select-String -Path $lp -Pattern '^sdk\.dir=' | Select-Object -First 1
        if ($line) { $cands += ($line.Line.Substring(8) -replace '\\\\', '\') }
    }
    foreach ($sdk in ($cands | Select-Object -Unique)) {
        $btDir = Join-Path $sdk 'build-tools'
        if (-not (Test-Path -LiteralPath $btDir)) { continue }
        $exe = Get-ChildItem $btDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'aapt2.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($exe) { return $exe }
    }
    return $null
}
$Aapt2 = Find-Aapt2
$produced = @(Get-ChildItem "$outDir\app-*-$suffix.apk" -ErrorAction SilentlyContinue |
    Where-Object { $expectNames -contains $_.Name } | Sort-Object Name)
if (-not $produced.Count) { throw "未找到本次打包产物（$outDir\app-*-$suffix.apk）" }
$checkFailed = $false
foreach ($apk in $produced) {
    $names = Get-ApkEntries $apk.FullName
    $abi = if ($apk.Name -match '-(arm64-v8a|armeabi-v7a|x86_64)-') { $Matches[1] } else { '' }
    $is3d = $apk.Name -like '*-depth3d-*'
    $isAm = $apk.Name -like 'app-apple-music-*'
    $isTv = $apk.Name -like 'app-*-tv-*'
    $problems = @()
    if ($names -notcontains "lib/$abi/libkugou_server.so") { $problems += "缺 lib/$abi/libkugou_server.so" }
    $hasOrt = $names -contains "lib/$abi/libonnxruntime.so"
    $hasModels = @($names | Where-Object { $_ -match '^assets/models/(depth_anything_v2_vits_q4f16|migan512_pipeline_int8)\.onnx$' }).Count -eq 2
    if ($is3d) {
        if (-not $hasOrt) { $problems += '缺 libonnxruntime.so' }
        if (-not $hasModels) { $problems += '缺深度模型资产 assets/models/*.onnx' }
    } elseif ($hasOrt -or $hasModels) {
        $problems += 'standard flavor 混入 3D 资产（flavor 隔离失效）'
    }
    if ($Aapt2) {
        # 先收全量输出再取首行：`| Select-Object -First 1` 会在读到首行后关闭管道，
        # 让 aapt2 提前终止并以非 0 收场，进而污染 $LASTEXITCODE（调用方会误判构建失败）。
        $badging = @(& $Aapt2 dump badging $apk.FullName 2>$null) | Select-Object -First 1
        if ($badging -match "^package: name='([^']+)'") {
            $wantPkg = if ($isAm) { 'com.apple.android.music' } elseif ($isTv) { 'com.md3music.md3music.tv' } else { 'com.md3music.md3music' }
            if ($Matches[1] -ne $wantPkg) { $problems += "包名 $($Matches[1])（应为 $wantPkg）" }
        } else { $problems += 'aapt2 未能读出包名' }
    }
    if ($problems.Count) { $checkFailed = $true; Write-Fail "$($apk.Name)：$($problems -join '；')" }
    else { Write-Ok "$($apk.Name)  $([math]::Round($apk.Length / 1MB, 1)) MB" }
}
if (-not $Aapt2) { Write-Warn '未找到 aapt2：已跳过包名校验（内容校验仍已执行）' }

# TV 包：无 USB 驱动 so、无 ONNX so、Dart 含 TV 焦点符号、不含被排除功能符号
$problems = @()
if ($wantTv) {
    $tvApk = Get-ChildItem "$outDir\app-*-tv-$($BuildType).apk" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tvApk) {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tvApk.FullName)
        $names = $zip.Entries.FullName; $zip.Dispose()
        if ($names -match 'libusb_audio_driver') { $problems += 'TV 包混入 libusb_audio_driver.so（USB 驱动未排除）' }
        if ($names -match 'onnxruntime')         { $problems += 'TV 包混入 onnxruntime so（3D 未排除）' }
        if (-not (Test-ApkDartSymbol -Apk $tvApk.FullName -Symbol 'DpadFocusable' -ExpectPresent $true))        { $problems += 'TV 包缺少 dpad 焦点符号（MD3_TV 旗标未生效）' }
        if (-not (Test-ApkDartSymbol -Apk $tvApk.FullName -Symbol 'UsbExclusiveSection' -ExpectPresent $false)) { $problems += 'TV 包混入 USB 独占设置 UI（kTvBuild 门控缺失）' }
        if (-not (Test-ApkDartSymbol -Apk $tvApk.FullName -Symbol '_buildLyricPushSubpage' -ExpectPresent $false)) { $problems += 'TV 包混入歌词推送设置子页（kTvBuild 门控缺失）' }
    }
}
# 正常包：不得含 TV 焦点符号
if ($wantStandard -or $wantDepth3d) {
    foreach ($apk in Get-ChildItem "$outDir\app-*-standard-$($BuildType).apk", "$outDir\app-*-depth3d-$($BuildType).apk" -ErrorAction SilentlyContinue) {
        if (-not (Test-ApkDartSymbol -Apk $apk.FullName -Symbol 'DpadFocusable' -ExpectPresent $false)) { $problems += "正常包混入 TV 焦点符号：$($apk.Name)" }
    }
}
if ($problems.Count) { $checkFailed = $true; Write-Fail "TV/符号自检：$($problems -join '；')" }
if ($checkFailed) { throw '产物自检未通过（见上）' }

# ---------- 7. 产物命名与正式 CI 对齐 ----------
# Flutter CLI 按固定名 app-<abi>-<flavor>-<type>.apk 查找产物（flutter_tools 的
# gradle.dart listApkPaths），**不能在 Gradle 层改名**，故在此于构建完成后重命名。
# 命名规则见 common.ps1 的 Get-ApkDisplayName，与 main.yml / ci.yml 保持一致。
Write-Step '整理产物文件名（与正式 CI 一致）'
$displayNames = @()
foreach ($apk in $produced) {
    $flavorKey = if ($apk.Name -like 'app-apple-music-*') { 'apple-music' }
                 elseif ($apk.Name -like '*-depth3d-*') { 'depth3d' }
                 elseif ($apk.Name -like 'app-*-tv-*') { 'tv' }
                 else { 'standard' }
    $abiKey = if ($apk.Name -match '-(arm64-v8a|armeabi-v7a|x86_64)-') { $Matches[1] } else { '' }
    $newName = Get-ApkDisplayName -Abi $abiKey -Flavor $flavorKey -BuildType $BuildType
    $dest = Join-Path $outDir $newName
    if (Test-Path -LiteralPath $dest) { Remove-ItemBypass $dest }
    Move-Item -LiteralPath $apk.FullName -Destination $dest
    # AGP 会为每个 APK 生成同名 .sha1，改名时让它跟随，避免留下对不上号的孤儿
    $shaSrc = "$($apk.FullName).sha1"
    if (Test-Path -LiteralPath $shaSrc) { Move-Item -LiteralPath $shaSrc -Destination "$dest.sha1" -Force }
    $displayNames += $newName
    Write-Ok "$($apk.Name)  →  $newName"
}

# ---------- 8. 清理历史产物 ----------
# 只保留与正式 CI 一致的发布名（含 Apple Music 兼容包）；中文名 / 无 flavor 的历史产物清理，
# 避免目录里两套命名混在一起分不清（连同同名 .sha1 一并清理）
$validName = Get-ApkDisplayPattern
$stale = @(Get-ChildItem $outDir -Filter '*.apk' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch $validName })
if ($stale.Count) {
    Write-Step "清理历史产物（$($stale.Count) 个）"
    foreach ($f in $stale) {
        Write-Note "  移除 $($f.Name)"
        Remove-ItemBypass $f.FullName
        $sha = "$($f.FullName).sha1"
        if (Test-Path -LiteralPath $sha) { Remove-ItemBypass $sha }
    }
}
# 孤儿 .sha1（对应 APK 已改名或删除，仅早期构建留下的）一并清掉
$orphanSha = @(Get-ChildItem $outDir -Filter '*.apk.sha1' -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-Path -LiteralPath ($_.FullName -replace '\.sha1$', '')) })
if ($orphanSha.Count) {
    Write-Step "清理孤儿 .sha1（$($orphanSha.Count) 个）"
    foreach ($f in $orphanSha) {
        Write-Note "  移除 $($f.Name)"
        Remove-ItemBypass $f.FullName
    }
}

Write-Step '打包完成'
Get-ChildItem "$outDir\*.apk" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $validName } | Sort-Object Name | ForEach-Object {
        $mark = if ($displayNames -contains $_.Name) { ' ' } else { '·' }
        Write-Host "  $mark $($_.Name)  $([math]::Round($_.Length / 1MB, 1)) MB" -ForegroundColor Green
    }
Write-Note '（带 · 的是本次未重新构建、但仍在保留清单内的包）'

if (-not $NoPause) { Wait-Exit }
