#Requires -Version 5.1
<#
.SYNOPSIS
  Windows 桌面一键打包：产出便携版 zip。

.DESCRIPTION
  完整流程：
    1. 检测 Visual Studio（Flutter Windows 桌面构建硬依赖 MSVC，缺则明确报错）
    2. 构建 Rust 桌面版 kugou_server.dll（走 kugou_api_server/rust/build_desktop.ps1，
       自动选 MSVC/GNU 工具链）
    3. flutter build windows --release
    4. 把 kugou_server.dll 复制到 exe 同目录
    5. 把 VC++ 运行库（Microsoft.VC*.CRT）复制到 exe 同目录
    6. 压缩整个 Release 输出为便携版 zip

  产出：build\windows\md3music-windows-<版本>.zip（拷到任意 Windows 机器解压即用）

.PARAMETER ForceRust
  强制重编 Rust，忽略"无改动"判断。

.PARAMETER SkipRust
  跳过 Rust 编译（若 dll 已存在且未改 Rust 代码）。

.PARAMETER OutDir
  zip 输出目录（默认 build\windows\）。

.PARAMETER NoPause
  结束时不等待按键（CI/被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 windows
#>
[CmdletBinding()]
param(
    [switch]$ForceRust,
    [switch]$SkipRust,
    [string]$OutDir = '',
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

# ---------- 3. Flutter Windows 构建 ----------
Write-Step 'flutter build windows --release'
Assert-Command flutter '请先安装并加入 PATH'
Push-Location $RepoRoot
try { Invoke-Native { flutter build windows --release } }
finally { Pop-Location }

# ---------- 4. 复制 dll 到 exe 同目录 ----------
Write-Step '复制 kugou_server.dll 到 Release 目录'
if (-not (Test-Path $DllPath)) { throw "未找到 kugou_server.dll：$DllPath" }
if (-not (Test-Path $ReleaseDir)) { throw "未找到 Release 目录：$ReleaseDir" }
Copy-Item $DllPath $ReleaseDir -Force
Write-Ok "kugou_server.dll -> $ReleaseDir"

# ---------- 5. 复制 VC++ 运行库到 Release 目录（app-local 部署） ----------
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

# ---------- 6. 压缩为便携 zip ----------
Write-Step '压缩便携版 zip'
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'build\windows' }
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $RepoRoot $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir "md3music-windows-$(Get-PubspecVersion).zip"
if (Test-Path $zip) { Remove-ItemBypass $zip }
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $zip -CompressionLevel Optimal
Write-Ok "$zip  $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB"

Write-Step '打包完成'
Write-Host "便携版：$zip" -ForegroundColor Green
if ($crtBundled) {
    Write-Host '把它拷贝到任意 Windows 机器解压，运行 md3music.exe 即可（无需安装）。'
} else {
    Write-Host '把它拷贝到 Windows 机器解压后运行 md3music.exe。' -ForegroundColor Yellow
    Write-Host '注意：本次未能随包 VC++ 运行库，目标机若未装「VC++ 2015-2022 可再发行组件包 (x64)」会启动失败。' -ForegroundColor Yellow
}

if (-not $NoPause) { Wait-Exit }
