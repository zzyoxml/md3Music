#Requires -Version 5.1
<#
.SYNOPSIS
  Windows 桌面一键打包：产出便携版 zip。

.DESCRIPTION
  完整流程：
    1. 检测 Visual Studio（Flutter Windows 桌面构建硬依赖 MSVC，缺则明确报错）
    2. 构建 Rust 桌面版 kugou_server.dll（走 kugou_api_server/rust/build_desktop.ps1，
       自动选 MSVC/GNU 工具链）
    3. flutter build windows --release（默认不带 3D 封面编译期开关）
    4. 把 kugou_server.dll 复制到 exe 同目录
    5. 准备并复制 ONNX Runtime 与深度模型到 exe 同目录（仅 -With3D；缺失时按需下载）
    6. 把 VC++ 运行库（Microsoft.VC*.CRT）复制到 exe 同目录
    7. 将 Release 放入 App/，生成根目录启动器并压缩为便携版 zip

  产出：build\windows\md3music-windows-<版本>.zip（拷到任意 Windows 机器解压即用）

  默认打包**不含** 3D 封面版本：不下载/不复制 onnxruntime*.dll 与 depth_model\，
  且 Dart 侧不传编译期开关（kDepthCoverAvailable 恒 false，3D 入口与整条深度管线
  被树摇剔除）。需要 3D 封面时加 -With3D。

.PARAMETER ForceRust
  强制重编 Rust，忽略"无改动"判断。

.PARAMETER SkipRust
  跳过 Rust 编译（若 dll 已存在且未改 Rust 代码）。

.PARAMETER With3D
  打包含 3D 封面的版本：构建时传 ENABLE_DEPTH_3D / DEPTH_BACKEND 两个编译期开关，
  并把 ONNX Runtime 运行时与深度模型随包（缺失时自动下载）。默认不含。

.PARAMETER OutDir
  zip 输出目录（默认 build\windows\）。

.PARAMETER PackageOnly
  仅打包已有 Release（CI 已完成 Flutter/Rust 构建及运行库复制时使用）。

.PARAMETER PackageVersion
  覆盖 zip 文件名中的版本号（正式 CI 使用 tag 版本）；不修改 pubspec 或应用版本。

.PARAMETER NoPause
  结束时不等待按键（CI/被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 windows
#>
[CmdletBinding()]
param(
    [switch]$ForceRust,
    [switch]$SkipRust,
    [switch]$With3D,
    [string]$OutDir = '',
    [switch]$PackageOnly,
    [ValidatePattern('^[0-9][0-9A-Za-z.+-]*$')]
    [string]$PackageVersion = '',
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

$RepoRoot   = Get-RepoRoot
$RustDir    = Join-Path $RepoRoot 'kugou_api_server\rust'
$DllPath    = Join-Path $RustDir 'target\release\kugou_server.dll'
$StampPath  = Join-Path $RustDir 'target\release\kugou_server.toolchain'
$ReleaseDir = Join-Path $RepoRoot 'build\windows\x64\runner\Release'

# ---------- ONNX Runtime（3D 封面）版本常量 ----------
# 来源：https://github.com/microsoft/onnxruntime/releases/tag/v1.30.0 （官方发布页，
#   正式 release 非预发布，发布于 2026-09-10；下载 URL 与资产大小经 GitHub API
#   releases/tags/v1.30.0 于 2026-10-28 核对）。
# 版本口径：与 Android 侧自编裁剪 AAR（android/app/libs/onnxruntime-android-1.30.0-custom-v8a.aar，
#   见 android/app/libs/ort-ops/REBUILD.md）同为 ORT 1.30.0，保证两份深度模型
#   （DepthAnythingV2 ViT-S q4f16 / MI-GAN512 int8）在双端由同一 API 版本加载，
#   不引入「模型与运行时错配」这类跨端问题。
# 资产口径：onnxruntime-win-x64-<版本>.zip（CPU 版，82,645,522 B）。zip 顶层还有一层
#   onnxruntime-win-x64-1.30.0\，两个 dll 在其 lib\ 下（1.30.0 实测：include\ 是头文件、
#   lib\ 另有 .lib 导入库与约 420MB 的 .pdb 调试符号，全部不要）。我们只挑两个 dll：
#   onnxruntime.dll 16,462,648 B + onnxruntime_providers_shared.dll 21,816 B ≈ 15.7MB。
#   后者是 CPU EP 运行必需的配套 dll（execution provider bridge 的共享符号在其中），
#   漏带会让 CreateSession 直接失败，必须与主 dll 成对携带。
#   注意别按固定目录名硬编码：早期 ORT 版本 dll 在 bin\ 下，本脚本按【文件名】全树搜索。
# 校验：$OrtZipSha256 为本机 2026-10-28 实际下载后 Get-FileHash 算出的值，并与 GitHub
#   Releases API 的资产 digest 字段一致（GET /repos/microsoft/onnxruntime/releases/
#   assets/555413217 → digest=sha256:c6ba98…）；同一个 zip 内两份 dll 解压后 CRC 亦全通过。
#   CI/发布（.github/workflows/build-windows.yml、ci.yml、main.yml 的 Windows job）**不再**
#   打 3D 封面，也不下载本运行时；同一版本 + 哈希只服务本地 -With3D 构建。
# vendor 入库策略：dll 不入库（zip 约 79MB、dll 约 13MB），缺失时按需下载到
#   windows/vendor/onnxruntime/ 复用（仅 -With3D 会触发；PR 不得提交该目录）。
$OrtVersion       = '1.30.0'
$OrtZipName       = "onnxruntime-win-x64-$OrtVersion.zip"
$OrtZipBytes      = 82645522
$OrtZipSha256     = 'c6ba983baf5681af108599675d2a89c2d145512d02de28aed0bff177cd0ba949'
$OrtDownloadDir   = Join-Path $RepoRoot 'tmp\ort_download'
$OrtDownloadUrl   = "https://github.com/microsoft/onnxruntime/releases/download/v$OrtVersion/$OrtZipName"

# 3D 深度模型源目录（已入库，Windows 直接原样拷贝到 Release\depth_model\，
# 不进 flutter_assets —— 避免 Android standard/depth3d APK 被这 30MB 资产增重）。
$DepthModelSrcDir = Join-Path $RepoRoot 'android\app\src\depth3d\assets\models'
$DepthModelNames  = @('depth_anything_v2_vits_q4f16.onnx', 'migan512_pipeline_int8.onnx')

# ONNX Runtime 本地缓存目录（不进 git；flutter run 经 windows/CMakeLists.txt、
# 打包经本脚本共用同一目录）。
function Get-OrtVendorDir { Join-Path (Get-RepoRoot) 'windows\vendor\onnxruntime' }

# 确保 vendor 目录内有 onnxruntime.dll + onnxruntime_providers_shared.dll。
# 已存在直接复用（秒过）；缺失则下载官方 zip → SHA256 校验 → 解压挑 dll。
# 只在 -With3D 时被调用。失败一律 Write-Fail + throw：那次构建带了
# ENABLE_DEPTH_3D=true，缺 dll 等于 3D 封面永久不可用，不允许静默产出
# 「看着正常、点开 3D 就报错」的残包。
function Ensure-OnnxRuntimeVendor {
    $vendorDir = Get-OrtVendorDir
    $ortDll    = Join-Path $vendorDir 'onnxruntime.dll'
    $provDll   = Join-Path $vendorDir 'onnxruntime_providers_shared.dll'
    if ((Test-Path -LiteralPath $ortDll) -and (Test-Path -LiteralPath $provDll)) {
        Write-Ok "ONNX Runtime 已就位：$vendorDir（$((Get-Item $ortDll).Length + (Get-Item $provDll).Length) B，版本 $OrtVersion）"
        return
    }

    if (-not (Test-Path -LiteralPath $vendorDir)) {
        New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null
    }
    $zipPath = Join-Path $OrtDownloadDir $OrtZipName

    # 先认本地已有的 zip（tmp/ 下那份）：SHA256 命中就跳过下载。慢网络下这步很值钱，
    # 中断后重跑不该把 79MB 再拉一遍；哈希不匹配时【长度已等于官方值】的必须删掉重下
    #（-C - 对已满的文件无法修复内容），只删残档保留续传价值。
    $zipReady = $false
    if (Test-Path -LiteralPath $zipPath) {
        if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -eq $OrtZipSha256) {
            Write-Ok "复用本地已校验 zip：$zipPath（$((Get-Item -LiteralPath $zipPath).Length) B）"
            $zipReady = $true
        } else {
            $haveBytes = (Get-Item -LiteralPath $zipPath).Length
            Write-Warn "本地 zip SHA256 不匹配（$haveBytes B，期望 $OrtZipBytes B），重新下载。"
            if ($haveBytes -ge $OrtZipBytes) {
                # 已写满但内容不对：续传救不回来，删掉从零开始。
                Remove-ItemBypass $zipPath
            }
        }
    }
    if (-not $zipReady) {
        Write-Step "下载 ONNX Runtime $OrtVersion（win-x64 CPU 版，官方 zip 约 79MB）"
        Write-Note "URL ：$OrtDownloadUrl"
        Write-Note "缓存：$vendorDir（下载一次长期复用，不进 git）"
        try {
            New-Item -ItemType Directory -Force -Path $OrtDownloadDir | Out-Null
            # 用 curl.exe（Windows 10+ 内置，Git for Windows 亦自带）而不是
            # Invoke-WebRequest：后者在 PS 5.1 依赖 IE 解析、且不带断点续传，慢网络不可用。
            # 不预先删掉已有文件：-C - 续传【已有】内容，中断后重跑能接着下。
            # 注意不加 --retry-all-errors（curl 7.71 才有该选项，老版 Win10 内置 7.55 会直接
            # 报 unknown option 反而下不动），只用 --retry 覆盖可重试的传输错误。
            Assert-Command curl.exe '下载 ONNX Runtime 需要 curl.exe（Win10+ 内置，或随 Git for Windows 提供）'
            $curlArgs = @('-sS', '-L', '--fail', '--retry', '3',
                          '--speed-limit', '2000', '--speed-time', '120',
                          '-C', '-', '--output', $zipPath, $OrtDownloadUrl)
            Invoke-Native { & curl.exe @curlArgs }
            $zipItem = Get-Item -LiteralPath $zipPath
            # curl 成功退出后长度必须正好等于官方值；不符即错误页/截断（终判仍在哈希）。
            if ($zipItem.Length -ne $OrtZipBytes) {
                throw "zip 长度 $($zipItem.Length) B ≠ 官方 $OrtZipBytes B（$OrtZipName），疑似下到错误页或被截断"
            }
            Write-Ok "zip 已下载（$($zipItem.Length) B）"

            $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
            if ($hash -ne $OrtZipSha256) {
                throw ("SHA256 校验失败：实际 $hash`n期望 $OrtZipSha256（官方发布页核对值，见脚本头部注释）。" +
                       '可能是下到错误页/半截文件/上游内容变更；重跑仍失败时请核对官方发布页后同步更新脚本与 CI 两处哈希。')
            }
            Write-Ok 'SHA256 校验通过'
            $zipReady = $true
        } catch {
            Write-Fail "ONNX Runtime 下载/校验失败：$($_.Exception.Message)"
        }
    }

    # 解压挑 dll（本地已有 zip 或刚下好的都走这里）。
    if ($zipReady) {
        try {
            # 只挑需要的那两条 entry，不用 Expand-Archive 解全树：官方 zip 里还有个约
            # 420MB 的 onnxruntime.pdb，全解要占几百 MB 磁盘、白等几十秒。
            # Add-Type 包 try：PS 5.1 必须显式加载该程序集才有 ZipFile；PS 7 里这个
            # 程序集名是类型转发门面，可能报「找不到程序集」，但类型本来就已可用。
            try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { }
            $ortZip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                foreach ($name in @('onnxruntime.dll', 'onnxruntime_providers_shared.dll')) {
                    # 按【文件名】匹配、不硬编码目录：1.30.0 的 dll 在 lib\ 下，更早版本在 bin\。
                    # 同名歧义时优先 lib/bin 段那条。
                    $entry = @($ortZip.Entries | Where-Object { $_.Name -eq $name } |
                                  Sort-Object { if ($_.FullName -match '(^|/)(lib|bin)/') { 0 } else { 1 } }) |
                             Select-Object -First 1
                    if (-not $entry) { throw "zip 内未找到 $name（共 $($ortZip.Entries.Count) 条 entry）" }
                    $destFile = Join-Path $vendorDir $name
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destFile, $true)
                    Write-Ok "$name <- $($entry.FullName)（$((Get-Item -LiteralPath $destFile).Length) B）"
                }
            } finally {
                $ortZip.Dispose()
            }
        } catch {
            Write-Fail "ONNX Runtime 解压失败：$($_.Exception.Message)"
        }
    }

    # 终判看【结果】而不是 try 的标志位：上面任何一步失败都会落到这里。
    # 缺件即中止，绝不产出「带 ENABLE_DEPTH_3D=true 却没有运行时」的残包。
    if (-not (Test-Path -LiteralPath $ortDll) -or -not (Test-Path -LiteralPath $provDll)) {
        Write-Fail '本次构建带 ENABLE_DEPTH_3D=true，缺少 onnxruntime.dll 会让 3D 封面永久不可用，中止打包。'
        Write-Fail '处置任选其一：'
        Write-Fail '  a) 联网（必要时开代理）后重跑本脚本，自动下载并校验；'
        Write-Fail "  b) 手动下载 $OrtDownloadUrl"
        Write-Fail '   把 lib\onnxruntime.dll 与 lib\onnxruntime_providers_shared.dll 放到：'
        Write-Fail "     $vendorDir"
        Write-Fail '  c) 确实不需要 3D 封面：临时去掉第 3 步构建命令里的两个 --dart-define。'
        throw '缺少 ONNX Runtime，中止打包'
    }
}

# 把 vendor dll + 两份深度模型复制到 Release 目录（exe 同目录 / depth_model 子目录）。
function Copy-Depth3DAssetsToRelease {
    param([string]$TargetDir)

    Write-Step '复制 ONNX Runtime 与深度模型到 Release 目录'
    if (-not (Test-Path -LiteralPath $TargetDir)) { throw "未找到 Release 目录：$TargetDir" }
    $vendorDir = Get-OrtVendorDir
    foreach ($name in @('onnxruntime.dll', 'onnxruntime_providers_shared.dll')) {
        $src = Join-Path $vendorDir $name
        if (-not (Test-Path -LiteralPath $src)) { throw "vendor 目录缺少 $name（$src）" }
        Copy-Item -LiteralPath $src -Destination $TargetDir -Force
    }
    Write-Ok "onnxruntime.dll + onnxruntime_providers_shared.dll -> $TargetDir"

    $modelDir = Join-Path $TargetDir 'depth_model'
    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
    foreach ($name in $DepthModelNames) {
        $src = Join-Path $DepthModelSrcDir $name
        if (-not (Test-Path -LiteralPath $src)) { throw "深度模型缺失：$src" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $modelDir $name) -Force
        Write-Ok "$name -> depth_model\（$((Get-Item $src).Length) B）"
    }
}

if (-not $PackageOnly) {
Sync-SettingsSearchIndex          # 设置搜索索引：构建前静默同步（有变化才提示）
Add-CargoToPath

# 现存 dll 的工具链标记（build_desktop.ps1 写入），非 *-msvc 视为不可发布
function Get-DllToolchainStamp {
    if (Test-Path $StampPath) { (Get-Content $StampPath -Raw).Trim() } else { '' }
}

# ---------- 1. 检测 Visual Studio（硬前提） ----------
Write-Step '检测 Visual Studio（Flutter Windows 构建必需）'
$vsWhere = if ($env:MD3_VSWHERE) { $env:MD3_VSWHERE } else { 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' }
$vsInstalled = $false
if (Test-Path $vsWhere) {
    # 注意：必须带 `-products *`，否则 vswhere 默认只匹配 Visual Studio IDE 实例，
    # 只装了 Build Tools（无 IDE）时会返回空 → 误判"未安装 VS"导致打包中止。
    # 带上后 Community/Professional/Build Tools 都能识别，只要有「使用 C++ 的桌面开发」。
    $vsInstalled = (& $vsWhere -latest -products * -property installationPath 2>$null)
}
if (-not $vsInstalled) {
    Write-Host @"

[错误] 未检测到 Visual Studio。
Flutter Windows 桌面应用构建【强制依赖】Visual Studio 的「使用 C++ 的桌面开发」工作负载（MSVC），
GNU/MinGW 无法替代。请先安装：

    1. 打开 https://visualstudio.microsoft.com/downloads/
    2. 下载 "Visual Studio Build Tools 2022"（或 Community 版）
    3. 安装时勾选工作负载："使用 C++ 的桌面开发"（Desktop development with C++）
    4. 安装完成后重启终端，再运行本脚本

安装完成后可用 vswhere 验证：$vsWhere
"@ -ForegroundColor Yellow
    throw '缺少 Visual Studio，中止打包'
}
Write-Host "Visual Studio: $vsInstalled" -ForegroundColor Green

# ---------- 1.5 cp936 /utf-8 与 ATL / NuGet 前置 ----------
# 中文 Windows（代码页 936）下 MSVC 默认按 GBK 解码无 BOM 的 UTF-8 源文件，
# connectivity_plus 等插件会报 C4819；开了 /WX（含本仓 windows/CMakeLists.txt 的
# runner /W4 /WX）时升级为 C2220 直接编译失败。cl.exe 读取 CL 环境变量并置于
# 命令行最前，对 runner 与全部插件的编译统一生效（也覆盖 Rust MSVC 工具链里
# cc crate 触发的 cl.exe）：
if ($env:CL) { $env:CL = "$env:CL /utf-8" } else { $env:CL = '/utf-8' }
Write-Note '已注入 CL=/utf-8（规避 cp936 下 C4819 -> C2220）'

# flutter_secure_storage_windows 的插件源码 include <atlstr.h>（ATL）；
# 只装「使用 C++ 的桌面开发」工作负载不含 ATL，缺了会在插件编译阶段报 atlstr.h 找不到。
$atlOk = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.ATL -property installationPath 2>$null
if (-not $atlOk) {
    Write-Warn '未检测到 VS 组件 Microsoft.VisualStudio.Component.VC.ATL（ATL）。'
    Write-Warn 'flutter_secure_storage_windows 需要 atlstr.h，缺失时插件编译阶段会失败。建议安装：'
    Write-Warn "    vs_installer.exe modify --installPath `"$(@($vsInstalled)[0])`" --add Microsoft.VisualStudio.Component.VC.ATL --passive"
    Write-Warn '（或在 Visual Studio Installer 中勾选「C++ ATL for latest v143 build tools」后重试。）'
}

# permission_handler_windows 的 CMake 在 configure 阶段会从 dist.nuget.org 下载 nuget.exe
# 并安装 Microsoft.Windows.CppWinRT 包；网络受限时会卡在 configure。
Write-Note '提示：permission_handler_windows 在 configure 阶段需联网下载 NuGet（dist.nuget.org）；'
Write-Note '受限网络请自备 nuget.exe 并配置本地源，或开代理后再跑本脚本。'

# ---------- 2. 判断是否需要构建 Rust（逻辑与 android 任务一致） ----------
$needRust = [bool]$ForceRust
if (-not $needRust -and -not $SkipRust) {
    # a) dll 不存在就必须编（干净 checkout 且从未编过 dll 的情况）
    if (-not (Test-Path $DllPath)) { $needRust = $true }

    # b) Rust 工作区有未提交改动（含未跟踪文件）
    if (-not $needRust) { $needRust = Test-RustDirty }

    # c) 兜底：dll 比 Cargo.toml/src 旧说明 Rust 改过但未同步（a 已保证 dll 存在）
    if (-not $needRust) {
        $dllTime = (Get-Item $DllPath).LastWriteTime
        $anyNewer = Get-ChildItem (Join-Path $RustDir 'src'), (Join-Path $RustDir 'Cargo.toml') -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $dllTime }
        if ($anyNewer) { $needRust = $true }
    }

    # d) 现存 dll 不是 MSVC 编的（或来路不明）也必须重编。
    #    build_desktop.ps1 的 MSVC / MinGW 两条路线写同一个 target\release\kugou_server.dll，
    #    a)~c) 只看存在性与时间戳，因此一份先前用 GNU toolchain 产出的 MinGW dll 会被判定为
    #    "最新"直接打包。它依赖 libgcc_s_seh-1.dll / libwinpthread-1.dll，便携包里没有 →
    #    用户机上 DynamicLibrary.open 失败 → App 能开但完全不能联网。
    if (-not $needRust) {
        $stamp = Get-DllToolchainStamp
        if ($stamp -notlike '*-msvc') {
            $needRust = $true
            $why = if ($stamp) { "由 $stamp 编译" } else { '缺少工具链标记，来路不明' }
            Write-Host "    现存 kugou_server.dll $why，强制用 MSVC 重编" -ForegroundColor Yellow
        }
    }
}

if ($needRust) {
    Write-Step '构建 Rust 桌面 kugou_server.dll'
    Invoke-Native { & (Join-Path $RustDir 'build_desktop.ps1') }
} else {
    if ($SkipRust) { Write-Step '按 -SkipRust 跳过 Rust 构建' }
    else { Write-Step 'Rust 无改动且 dll 已最新，跳过构建（-ForceRust 强制重编）' }
    if (-not (Test-Path $DllPath)) {
        Write-Fail '未找到 kugou_server.dll，请去掉 -SkipRust 让脚本自行构建'
        throw '缺少 kugou_server.dll'
    }
    # -SkipRust 是显式指令，不强行覆盖；但 MinGW dll 会打出一个"能开、不能联网"的残包，
    # 必须把话说清楚（判据同上面的 d)）。
    if ($SkipRust) {
        $stamp = Get-DllToolchainStamp
        if ($stamp -notlike '*-msvc') {
            Write-Warn "现存 kugou_server.dll $(if ($stamp) { "由 $stamp 编译" } else { '来路不明' })。"
            Write-Warn '非 MSVC 版本依赖 MinGW 运行库（libgcc_s_seh-1.dll 等），便携包不含这些文件，'
            Write-Warn '目标机上会加载失败导致 App 完全不能联网。建议去掉 -SkipRust 重编。'
        }
    }
}

# ---------- 2.5 预取 ONNX Runtime（3D 封面运行时，仅 -With3D） ----------
# 放在 flutter build 之前：本仓 flutter build windows 要十几分钟，等构建跑完才发现
# 网络不可用 / 哈希不匹配纯属浪费。Ensure-OnnxRuntimeVendor 幂等，第 5 步再调一次
# 命中缓存秒过。默认包不含 3D 封面，这一步整体跳过（不联网、不占 vendor 目录）。
if ($With3D) {
    Ensure-OnnxRuntimeVendor
} else {
    Write-Note '默认不打包 3D 封面，跳过 ONNX Runtime 预取（需要时加 -With3D）'
}

# ---------- 3. Flutter Windows 构建 ----------
# 两个 3D 封面编译期开关（口径与 lib/core/services/depth_cover_feature.dart 一致），
# **仅 -With3D 时传**：
#   ENABLE_DEPTH_3D=true   —— Dart 侧 kDepthCoverAvailable 才为 true（设置项/生成请求可见）
#   DEPTH_BACKEND=dart_ffi —— Windows 走纯 Dart ONNX Runtime FFI（third_party/ort_dart，
#                             动态加载 exe 同目录的 onnxruntime.dll），而不是 MethodChannel
# 默认（不带 -With3D）不传：kDepthCoverAvailable 恒 false，const false 分支连同整条
# Dart 管线（ort_dart + 算法）会被树摇剔除，产物是「零 3D 产物」的常规包。
# Android/TV 的构建命令同样**不带**这两个 define：kDepthBackend 默认 channel。
Write-Step "flutter build windows --release$(if ($With3D) { '（含 3D 封面）' } else { '（默认，不含 3D 封面）' })"
Assert-Command flutter '请先安装并加入 PATH'
Push-Location $RepoRoot
try {
    if ($With3D) {
        Invoke-Native {
            flutter build windows --release `
                --dart-define=ENABLE_DEPTH_3D=true `
                --dart-define=DEPTH_BACKEND=dart_ffi
        }
    } else {
        Invoke-Native { flutter build windows --release }
    }
}
catch {
    # 典型坑：早期 configure 失败会在 build\windows 留下 CMAKE_INSTALL_PREFIX 已被写成
    # 默认值的 CMakeCache.txt，之后每次构建都死在 INSTALL（cannot create directory: C:/Program Files）。
    Write-Warn 'flutter build windows 失败。若错误信息含 INSTALL "cannot create directory: C:/Program Files..."，'
    Write-Warn '删除整个 build\windows 目录后重跑本脚本即可（残留的 CMakeCache.txt 里 CMAKE_INSTALL_PREFIX 已是默认值）。'
    throw
}
finally { Pop-Location }

# ---------- 4. 复制 dll 到 exe 同目录 ----------
Write-Step '复制 kugou_server.dll 到 Release 目录'
if (-not (Test-Path $DllPath)) { throw "未找到 kugou_server.dll：$DllPath" }
if (-not (Test-Path $ReleaseDir)) { throw "未找到 Release 目录：$ReleaseDir" }
Copy-Item $DllPath $ReleaseDir -Force
Write-Ok "kugou_server.dll -> $ReleaseDir"

# ---------- 5. 准备并复制 ONNX Runtime 与深度模型到 Release 目录（仅 -With3D） ----------
# 3D 封面（DEPTH_BACKEND=dart_ffi）运行时依赖：
#   exe 同目录 onnxruntime.dll / onnxruntime_providers_shared.dll（ort_dart 动态加载）
#   exe 同目录 depth_model\<两份 onnx>（推理用的深度 + 修补模型）
# 模型源文件已在仓库（android/app/src/depth3d/assets/models/，Android 走 flavor 内的
# assets），这里只原样拷贝、**不进 flutter_assets**：否则 Android standard/depth3d APK
# 会被这约 30MB 资产增重，而 Android 端本来就从 assets 路径读它们。
if ($With3D) {
    Ensure-OnnxRuntimeVendor
    Copy-Depth3DAssetsToRelease -TargetDir $ReleaseDir
} else {
    Write-Step '跳过 ONNX Runtime 与深度模型（默认不含 3D 封面；需要时加 -With3D 重打）'
}

# ---------- 6. 复制 VC++ 运行库到 Release 目录（app-local 部署） ----------
# md3music.exe / flutter_windows.dll / 各插件 dll 都是 /MD 动态链接 MSVC 运行库，
# 目标机没装「VC++ 2015-2022 可再发行组件包」时 exe 直接起不来（缺 VCRUNTIME140.dll）。
# Microsoft.VC*.CRT 允许 app-local 部署，直接放到 exe 同目录即可。
Write-Step '复制 VC++ 运行库到 Release 目录'
$crtBundled = $false
$vsRoot = @($vsInstalled)[0]
$crtDir = Get-ChildItem (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
    Sort-Object Name -Descending | Select-Object -First 1
if ($crtDir) {
    $crtDlls = @(Get-ChildItem (Join-Path $crtDir.FullName '*.dll') -ErrorAction SilentlyContinue)
    if ($crtDlls.Count) {
        Copy-Item $crtDlls.FullName $ReleaseDir -Force
        $crtBundled = $true
        Write-Ok "$($crtDlls.Count) 个运行库 dll <- $($crtDir.FullName)"
        Write-Note ($crtDlls.Name -join ', ')
    }
}
if (-not $crtBundled) {
    Write-Warn '未在 VS 安装目录下找到 Microsoft.VC*.CRT，运行库未随包。'
    Write-Warn "查找路径：$(Join-Path $vsRoot 'VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT')"
    Write-Warn '目标机需自行安装「Microsoft Visual C++ 2015-2022 可再发行组件包 (x64)」。'
}

} else {
    # CI 已把 Rust DLL / VC++ 运行库复制好，打包阶段不再访问 Flutter、Cargo 或重建索引。
    # CI/发布产物不带 3D 封面（-With3D 仅本地开发用），因此这里也不期望有 ORT/模型；
    # 万一 Release 里有残留，下面的暂存步骤会把它们剔除。
    $crtBundled = Test-Path -LiteralPath (Join-Path $ReleaseDir 'vcruntime140.dll')
}

# ---------- 7. 整理便携目录并压缩（本地与 CI 共用） ----------
# Flutter runner 的插件 / 引擎 DLL 必须与真正的 md3Music.exe 同目录，
# 所以把完整 Release 放到「App」中；zip 根目录放一个同名启动器，
# 用户解压后第一眼就能看到并双击 md3Music.exe。
Write-Step '整理目录并压缩便携版 zip'
# onnxruntime.dll 与 depth_model\*.onnx 只在 -With3D 时才进必检项：那种构建带了
# ENABLE_DEPTH_3D=true，缺任何一件都会打出一个「3D 封面能开但一按就报错」的残包，
# 宁可在压缩前就失败。
$requiredFiles = @('md3Music.exe', 'flutter_windows.dll', 'kugou_server.dll', 'data\flutter_assets')
if ($With3D) {
    $requiredFiles += @('onnxruntime.dll', 'depth_model\depth_anything_v2_vits_q4f16.onnx')
}
foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir $required))) {
        throw "Release 产物缺失：$required（$ReleaseDir）"
    }
}
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'build\windows' }
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $RepoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$version = if ($PackageVersion) { $PackageVersion } else { Get-PubspecVersion }
if ($version -notmatch '^[0-9][0-9A-Za-z.+-]*$') { throw "无效打包版本号：$version" }
$zip = Join-Path $OutDir "md3music-windows-$version.zip"
$stageRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'tmp'))
$stageDir = [System.IO.Path]::GetFullPath((Join-Path $stageRoot "md3music-portable-$version-$PID"))
if (-not $stageDir.StartsWith($stageRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "临时打包目录越界：$stageDir"
}
$appDir = Join-Path $stageDir 'App'
if (Test-Path -LiteralPath $stageDir) { throw "临时打包目录已存在，为避免覆盖已停止：$stageDir" }
if (Test-Path $zip) { Remove-ItemBypass $zip }
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
try {
    Copy-Item -Path (Join-Path $ReleaseDir '*') -Destination $appDir -Recurse -Force
    # 默认不打 3D：Release 里可能残留上一次 3D 构建的运行时/模型 —— windows/CMakeLists.txt
    # 的 depth_runtime_copy / depth_model_copy 都是 ALL 目标，只要 windows/vendor 与模型
    # 就位，每次 flutter build windows 都会把它们复制进 Release。这里在**暂存副本**上
    # 剔除（不动 build 目录本身），保证默认 zip 真正是「零 3D 产物」。
    if (-not $With3D) {
        foreach ($stale in @(Get-ChildItem -Path (Join-Path $appDir 'onnxruntime*.dll') -File -ErrorAction SilentlyContinue)) {
            Remove-ItemBypass $stale.FullName
        }
        Remove-ItemBypass (Join-Path $appDir 'depth_model')
    }
    $launcherPath = Join-Path $stageDir 'md3Music.exe'
    $launcherNamespace = 'Md3Portable' + [Guid]::NewGuid().ToString('N')
    $launcherSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
namespace $launcherNamespace {
  internal static class EntryPoint {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr owner, string text, string caption, uint type);
    public static int Main(string[] args) {
      string root = AppDomain.CurrentDomain.BaseDirectory;
      string appDir = Path.Combine(root, "App");
      string appPath = Path.Combine(appDir, "md3Music.exe");
      if (args.Length == 1 && args[0] == "--md3-portable-check") return File.Exists(appPath) ? 0 : 2;
      if (!File.Exists(appPath)) {
        MessageBox(IntPtr.Zero, "App\\md3Music.exe was not found. Please check the portable package.", "MD3Music", 0x10);
        return 2;
      }
      var start = new ProcessStartInfo(appPath);
      start.WorkingDirectory = appDir;
      start.UseShellExecute = false;
      string path = Environment.GetEnvironmentVariable("PATH") ?? String.Empty;
      start.EnvironmentVariables["PATH"] = appDir + Path.PathSeparator + path;
      Process.Start(start);
      return 0;
    }
  }
}
"@
    # PowerShell 7 的 Add-Type 只支持生成程序集库，传 WindowsApplication 会失败；
    # 使用 Windows 自带的 .NET Framework C# 编译器生成无控制台窗口的启动器。
    $cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $cscPath)) { throw "未找到 C# 编译器：$cscPath" }
    $launcherSourcePath = Join-Path $stageDir 'launcher.cs'
    Set-Content -LiteralPath $launcherSourcePath -Value $launcherSource -Encoding UTF8
    & $cscPath /nologo /target:winexe "/out:$launcherPath" $launcherSourcePath
    if ($LASTEXITCODE -ne 0) { throw "便携版启动器编译失败，csc 退出码 $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $launcherPath)) { throw '便携版根目录启动器生成失败' }

    # 将正式应用的多尺寸图标写入根目录启动器，Explorer 和任务栏可直接显示品牌图标。
    $iconPath = Join-Path $RepoRoot 'windows\runner\resources\app_icon.ico'
    if (-not (Test-Path -LiteralPath $iconPath)) { throw "应用图标不存在：$iconPath" }
    $iconNamespace = 'Md3IconResource' + [Guid]::NewGuid().ToString('N')
    $iconApi = @"
using System;
using System.Runtime.InteropServices;
namespace $iconNamespace {
  public static class ResourceWriter {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool EndUpdateResource(IntPtr update, bool discard);
    static IntPtr Id(int value) { return new IntPtr(value); }
    public static void Apply(string exe, string ico) {
      byte[] bytes = System.IO.File.ReadAllBytes(ico);
      if (bytes.Length < 6 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 1) throw new InvalidOperationException("Invalid ICO file");
      int count = bytes[4] | (bytes[5] << 8);
      if (count < 1) throw new InvalidOperationException("Invalid ICO file");
      IntPtr update = BeginUpdateResource(exe, false);
      if (update == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      try {
        byte[] group = new byte[6 + 14 * count];
        Buffer.BlockCopy(bytes, 0, group, 0, 6);
        for (int i = 0; i < count; i++) {
          int entry = 6 + 16 * i;
          int size = bytes[entry + 8] | (bytes[entry + 9] << 8) | (bytes[entry + 10] << 16) | (bytes[entry + 11] << 24);
          int offset = bytes[entry + 12] | (bytes[entry + 13] << 8) | (bytes[entry + 14] << 16) | (bytes[entry + 15] << 24);
          if (size < 1 || offset < 0 || offset + size > bytes.Length) throw new InvalidOperationException("Invalid ICO image entry");
          byte[] image = new byte[size]; Buffer.BlockCopy(bytes, offset, image, 0, size);
          if (!UpdateResource(update, Id(3), Id(i + 1), 0, image, (uint)image.Length)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
          Buffer.BlockCopy(bytes, entry, group, 6 + 14 * i, 12);
          group[6 + 14 * i + 12] = (byte)(i + 1); group[6 + 14 * i + 13] = 0;
        }
        if (!UpdateResource(update, Id(14), Id(1), 0, group, (uint)group.Length)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        if (!EndUpdateResource(update, false)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      } catch { EndUpdateResource(update, true); throw; }
    }
  }
}
"@
    Add-Type -TypeDefinition $iconApi -Language CSharp
    $iconWriter = "$iconNamespace.ResourceWriter" -as [type]
    $iconArgs = New-Object object[] 2
    $iconArgs[0] = [string]$launcherPath
    $iconArgs[1] = [string]$iconPath
    $null = $iconWriter.GetMethod('Apply').Invoke($null, $iconArgs)
    if (Test-Path $zip) { Remove-ItemBypass $zip }
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zip -CompressionLevel Optimal
} finally {
    Remove-ItemBypass $stageDir
}
Write-Ok "$zip  $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB"

Write-Step '打包完成'
Write-Host "便携版：$zip" -ForegroundColor Green
Write-Host '解压后根目录直接双击 md3Music.exe；App 文件夹包含实际应用与全部运行依赖。' -ForegroundColor Green
if (-not $crtBundled) {
    Write-Host '注意：本次未能随包 VC++ 运行库，目标机若未装「VC++ 2015-2022 可再发行组件包 (x64)」会启动失败。' -ForegroundColor Yellow
}

if (-not $NoPause) { Wait-Exit }
