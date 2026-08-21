#Requires -Version 5.1
<#
.SYNOPSIS
  MD3Music Windows 桌面一键打包脚本：产出便携版 zip。

.DESCRIPTION
  完整流程：
    1. 检测 Visual Studio（Flutter Windows 桌面构建硬依赖 MSVC，缺则明确报错）
    2. 构建 Rust 桌面版 kugou_server.dll（走 build_desktop.ps1，GNU toolchain）
    3. flutter build windows --release
    4. 把 kugou_server.dll 复制到 exe 同目录
    5. 压缩整个 Release 输出为便携版 zip

  产出：build\windows\md3music-windows-<版本>.zip（自包含，考到任意机器即可运行）

.PARAMETER SkipRust
  跳过 Rust 编译（若 dll 已存在且未改 Rust 代码）。

.PARAMETER OutDir
  zip 输出目录（默认 build\windows\）。

.EXAMPLE
  .\scripts\build_windows.ps1
#>
param(
    [switch]$ForceRust,
    [switch]$SkipRust,
    [string]$OutDir = ""
)
$ErrorActionPreference = 'Stop'
$RepoRoot   = Split-Path -Parent $PSScriptRoot          # scripts/.. = 项目根
$RustDir    = Join-Path $RepoRoot 'kugou_api_server\rust'
$ReleaseDir = Join-Path $RepoRoot 'build\windows\x64\runner\Release'
$CargoBin   = Join-Path $env:USERPROFILE '.cargo\bin'
$env:Path   = "$CargoBin;$env:Path"

function Write-Step([string]$Msg) { Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Invoke-Native {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command; if ($LASTEXITCODE -ne 0) { throw "命令失败，退出码 $LASTEXITCODE" } }
    finally { $ErrorActionPreference = $prev }
}

# ---------- 1. 检测 Visual Studio（硬前提） ----------
Write-Step '检测 Visual Studio（Flutter Windows 构建必需）'
$vsWhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstalled = $false
if (Test-Path $vsWhere) {
    # 注意：必须带 `-products *`，否则 vswhere 默认只匹配 Visual Studio IDE 实例，
    # 只装了 Build Tools（无 IDE）时会返回空 → 误判"未安装 VS"导致打包中止。
    # 本机即只装了 VS 2022 Build Tools，无 -products * 一定失败。
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

# ---------- 2. 判断是否需要构建 Rust（智能检测，逻辑同 build_android.ps1） ----------
$needRust = $ForceRust
if (-not $needRust -and -not $SkipRust -and (Get-Command git -ErrorAction SilentlyContinue)) {
    # 工作区未提交改动（含未跟踪文件）
    $st = & git -C $RepoRoot status --porcelain -- kugou_api_server/rust/ 2>$null
    if ($LASTEXITCODE -eq 0 -and $st) { $needRust = $true }
}
if (-not $needRust -and (Test-Path (Join-Path $RustDir 'target\release\kugou_server.dll'))) {
    # 兜底：dll 比 Cargo.toml/src 旧说明 Rust 改过但未同步
    $dllTime = (Get-Item (Join-Path $RustDir 'target\release\kugou_server.dll')).LastWriteTime
    $anyNewer = Get-ChildItem (Join-Path $RustDir 'src'), (Join-Path $RustDir 'Cargo.toml') -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $dllTime }
    if ($anyNewer) { $needRust = $true }
}

if ($needRust) {
    Write-Step '构建 Rust 桌面 kugou_server.dll'
    Invoke-Native { & (Join-Path $RustDir 'build_desktop.ps1') }
} else {
    Write-Step 'Rust 无改动，跳过交叉编译（-ForceRust 强制，-SkipRust 手动跳过）'
    if (-not (Test-Path (Join-Path $RustDir 'target\release\kugou_server.dll'))) {
        Write-Host '[错误] 未找到 kugou_server.dll，且 Rust 无改动可跳过；请去掉 -SkipRust 或加 -ForceRust' -ForegroundColor Yellow
        throw '缺少 kugou_server.dll'
    }
}

# ---------- 3. Flutter Windows 构建 ----------
Write-Step 'flutter build windows --release'
Push-Location $RepoRoot
try { Invoke-Native { flutter build windows --release } }
finally { Pop-Location }

# ---------- 4. 复制 dll 到 exe 同目录 ----------
Write-Step '复制 kugou_server.dll 到 Release 目录'
$dll = Join-Path $RustDir 'target\release\kugou_server.dll'
if (-not (Test-Path $dll)) { throw "未找到 kugou_server.dll：$dll（请先用 build_desktop.ps1 或去掉 -SkipRust）" }
if (-not (Test-Path $ReleaseDir)) { throw "未找到 Release 目录：$ReleaseDir" }
Copy-Item $dll $ReleaseDir -Force
Write-Host "    kugou_server.dll -> $ReleaseDir" -ForegroundColor Green

# ---------- 5. 压缩为便携 zip ----------
Write-Step '压缩便携版 zip'
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'build\windows' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# 读取版本号（pubspec version 前缀）
$version = '0.0.0'
$pub = Get-Content (Join-Path $RepoRoot 'pubspec.yaml') | Select-String '^version:'
if ($pub) { $version = ($pub.ToString() -replace '^version:\s*', '' -split '\+')[0] }
$zip = Join-Path $OutDir "md3music-windows-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $zip -CompressionLevel Optimal
Write-Host "    $zip  $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB" -ForegroundColor Green

Write-Step '打包完成'
Write-Host "便携版：$zip" -ForegroundColor Green
Write-Host "把它拷贝到任意 Windows 机器解压，运行 md3music.exe 即可（无需安装）。"

# 打包完成后停留，窗口不自动关闭，方便查看结果
Write-Host ""
Write-Host "构建结束。按任意键关闭窗口..." -ForegroundColor Cyan
try {
    # 交互控制台：等待按键，窗口保持打开
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
} catch {
    # 非交互宿主（如某些工具/CI 调用）：ReadKey 不可用，改为延时停留，避免闪退
    Start-Sleep -Seconds 10
}