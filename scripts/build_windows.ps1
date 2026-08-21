#Requires -Version 5.1
<#
.SYNOPSIS
  MD3Music Windows 桌面一键打包脚本：产出便携版 zip。

.DESCRIPTION
  完整流程：
    1. 检测 Visual Studio（Flutter Windows 桌面构建硬依赖 MSVC，缺则明确报错）
    2. 构建 Rust 桌面版 kugou_server.dll（走 build_desktop.ps1，自动选 MSVC/GNU 工具链）
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
$DllPath    = Join-Path $RustDir 'target\release\kugou_server.dll'
$StampPath  = Join-Path $RustDir 'target\release\kugou_server.toolchain'
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

# ---------- 2. 判断是否需要构建 Rust（智能检测，逻辑同 build_android.ps1） ----------
$needRust = $ForceRust
if (-not $needRust -and -not $SkipRust) {
    # a) dll 不存在就必须编。此前缺这一条：干净 checkout（Rust 无改动）且没编过
    #    dll 时，下面三个条件全不成立 → 落到 else 分支直接 throw，还提示"去掉
    #    -SkipRust 或加 -ForceRust"，而用户并没传 -SkipRust，照提示做也没有出路。
    if (-not (Test-Path $DllPath)) { $needRust = $true }

    # b) Rust 工作区有未提交改动（含未跟踪文件）
    if (-not $needRust -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $st = & git -C $RepoRoot status --porcelain -- kugou_api_server/rust/ 2>$null
        if ($LASTEXITCODE -eq 0 -and $st) { $needRust = $true }
    }

    # c) 兜底：dll 比 Cargo.toml/src 旧说明 Rust 改过但未同步
    #    （a) 已保证走到这里时 dll 必然存在）
    if (-not $needRust) {
        $dllTime = (Get-Item $DllPath).LastWriteTime
        $anyNewer = Get-ChildItem (Join-Path $RustDir 'src'), (Join-Path $RustDir 'Cargo.toml') -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $dllTime }
        if ($anyNewer) { $needRust = $true }
    }

    # d) 现存 dll 不是 MSVC 编的（或来路不明）也必须重编。
    #    build_desktop.ps1 的 MSVC / MinGW 两条路线写同一个
    #    target\release\kugou_server.dll，a)~c) 只看存在性与时间戳，
    #    因此一份先前用 `cargo +stable-x86_64-pc-windows-gnu build --release`
    #    （AGENTS.md 3.2 的开发命令）产出的 MinGW dll 会被判定为"最新"直接打包。
    #    它依赖 libgcc_s_seh-1.dll / libwinpthread-1.dll，便携包里没有 →
    #    用户机上 DynamicLibrary.open 失败 → App 能开但完全不能联网。
    if (-not $needRust) {
        $stamp = if (Test-Path $StampPath) { (Get-Content $StampPath -Raw).Trim() } else { '' }
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
    # 整块检测包在 -not $SkipRust 里：此前 c) 漏判 $SkipRust，传了 -SkipRust
    # 但源码比 dll 新时照样会去编译。
    if ($SkipRust) { Write-Step '按 -SkipRust 跳过 Rust 构建' }
    else { Write-Step 'Rust 无改动且 dll 已最新，跳过构建（-ForceRust 强制重编）' }
    if (-not (Test-Path $DllPath)) {
        Write-Host '[错误] 未找到 kugou_server.dll，请去掉 -SkipRust 让脚本自行构建' -ForegroundColor Yellow
        throw '缺少 kugou_server.dll'
    }
    # -SkipRust 是显式指令，不强行覆盖；但 MinGW dll 会打出一个"能开、不能联网"
    # 的残包，必须把话说清楚（判据同上面的 d)）。
    if ($SkipRust) {
        $stamp = if (Test-Path $StampPath) { (Get-Content $StampPath -Raw).Trim() } else { '' }
        if ($stamp -notlike '*-msvc') {
            Write-Host "[警告] 现存 kugou_server.dll $(if ($stamp) { "由 $stamp 编译" } else { '来路不明' })。" -ForegroundColor Yellow
            Write-Host "        非 MSVC 版本依赖 MinGW 运行库（libgcc_s_seh-1.dll 等），便携包不含这些文件，" -ForegroundColor Yellow
            Write-Host "        目标机上会加载失败导致 App 完全不能联网。建议去掉 -SkipRust 重编。" -ForegroundColor Yellow
        }
    }
}

# ---------- 3. Flutter Windows 构建 ----------
Write-Step 'flutter build windows --release'
Push-Location $RepoRoot
try { Invoke-Native { flutter build windows --release } }
finally { Pop-Location }

# ---------- 4. 复制 dll 到 exe 同目录 ----------
Write-Step '复制 kugou_server.dll 到 Release 目录'
if (-not (Test-Path $DllPath)) { throw "未找到 kugou_server.dll：$DllPath（请先用 build_desktop.ps1 或去掉 -SkipRust）" }
if (-not (Test-Path $ReleaseDir)) { throw "未找到 Release 目录：$ReleaseDir" }
Copy-Item $DllPath $ReleaseDir -Force
Write-Host "    kugou_server.dll -> $ReleaseDir" -ForegroundColor Green

# ---------- 5. 复制 VC++ 运行库到 Release 目录（app-local 部署） ----------
# md3music.exe / flutter_windows.dll / 各插件 dll 都是 /MD 动态链接 MSVC 运行库，
# 目标机没装「VC++ 2015-2022 可再发行组件包」时 exe 直接起不来（缺 VCRUNTIME140.dll）。
# 之前脚本自称"自包含"但并不带这些文件——在装过其他 MSVC 程序的机器上碰巧能跑，
# 干净系统上必挂。Microsoft.VC*.CRT 允许 app-local 部署，直接放到 exe 同目录即可。
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
        Write-Host "    $($crtDlls.Count) 个运行库 dll <- $($crtDir.FullName)" -ForegroundColor Green
        Write-Host "    $($crtDlls.Name -join ', ')" -ForegroundColor DarkGray
    }
}
if (-not $crtBundled) {
    Write-Host '[警告] 未在 VS 安装目录下找到 Microsoft.VC*.CRT，运行库未随包。' -ForegroundColor Yellow
    Write-Host "        查找路径：$(Join-Path $vsRoot 'VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT')" -ForegroundColor Yellow
    Write-Host '        目标机需自行安装「Microsoft Visual C++ 2015-2022 可再发行组件包 (x64)」。' -ForegroundColor Yellow
}

# ---------- 6. 压缩为便携 zip ----------
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
if ($crtBundled) {
    Write-Host "把它拷贝到任意 Windows 机器解压，运行 md3music.exe 即可（无需安装）。"
} else {
    Write-Host "把它拷贝到 Windows 机器解压后运行 md3music.exe。" -ForegroundColor Yellow
    Write-Host "注意：本次未能随包 VC++ 运行库，目标机若未装「VC++ 2015-2022 可再发行组件包 (x64)」会启动失败。" -ForegroundColor Yellow
}

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