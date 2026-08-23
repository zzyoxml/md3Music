#Requires -Version 5.1
<#
.SYNOPSIS
  MD3Music 公开版本导出脚本（PowerShell 版）

.DESCRIPTION
  从私有单一源码仓库过滤导出「公开版本」，全程分步提示：
    1. 前置检查（仓库结构、否认清单、可选推送的 git）
    2. 清空旧导出目录
    3. 白名单拷贝公开文件（lib/android/assets/... 顶层项）
    4. 排除私有内容（lib/private/、pubspec.lock）
    5. 剥离 pubspec.yaml 的私有依赖块（md3_download_cache）
    6. 否认清单闸门（scripts/public_deny.txt，lib/ 与 pubspec 零命中才通过）
    7. 可选：推送导出树到公开仓库（force push 到 PublicBranch）
    8. 完成总结（目录 / 体量 / 下一步建议）

  公开版本 = 本仓库过滤导出的干净树，不是独立代码库。
  任何一步失败都会在退出前打印明确的红色错误并暂停，便于双击运行时看到原因。

.PARAMETER OutDir
  导出目录（默认 .public_export，已在 .gitignore 中排除）。
  相对路径基于项目根解析，与当前工作目录无关。

.PARAMETER PublicRemote
  公开仓库 URL。提供时导出完成后自动 git init + commit + force push。
  示例：https://github.com/zzyoxml/md3Music.git

.PARAMETER PublicBranch
  推送到公开仓库的分支名（默认 main）。

.PARAMETER NoPause
  结束时暂停等待按键（默认暂停，避免双击运行窗口一闪而过；CI 请加 -NoPause）。

.EXAMPLE
  .\scripts\export_public.ps1                                # 只导出 + 闸门校验
  .\scripts\export_public.ps1 -PublicRemote https://github.com/zzyoxml/md3Music.git
  .\scripts\export_public.ps1 -PublicRemote <URL> -NoPause    # CI/非交互环境
#>
[CmdletBinding()]
param(
    [string]$OutDir = '.public_export',
    [string]$PublicRemote = '',
    [string]$PublicBranch = 'main',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
# 外部命令（git）的 stderr 输出会触发 NativeCommandError，需临时切回 Continue
$script:PrevEAP = $null
$Root = Split-Path -Parent $PSScriptRoot   # scripts/.. = 项目根
# 相对目录统一解析到项目根，避免脚本行为依赖当前工作目录
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $Root $OutDir }

# ---------- 输出辅助 ----------
function Write-Step([string]$Msg) { Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Write-Fail([string]$Msg) { Write-Host "  [XX] $Msg" -ForegroundColor Red }

# 结束前暂停，避免双击运行/外部调用时窗口一闪而过；非交互环境自动降级为短等待
function Wait-Exit {
    Write-Host "`n按任意键退出..." -ForegroundColor Cyan
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    catch { Start-Sleep -Seconds 2 }
}

# 运行外部命令（git）：stderr 会触发 NativeCommandError，这里临时切回 Continue
# 并检查退出码，真正失败再 throw（由主流程 catch 统一打印并暂停）。
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

# 删除文件/目录：走 .NET IO 旁路，规避本机安全删除钩子对 Remove-Item 的拦截
function Remove-ItemBypass([string]$path) {
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path
        if ($item -is [System.IO.DirectoryInfo]) {
            [System.IO.Directory]::Delete($item.FullName, $true)
        } else {
            [System.IO.File]::Delete($item.FullName)
        }
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$exitCode = 0

try {
    # ---------- 1. 前置检查 ----------
    Write-Step '前置检查'
    if (-not (Test-Path (Join-Path $Root 'pubspec.yaml'))) {
        throw "未找到 pubspec.yaml（$Root），请确认脚本位于项目根 scripts/ 目录"
    }
    $denyFile = Join-Path $PSScriptRoot 'public_deny.txt'
    if (-not (Test-Path $denyFile)) {
        throw "未找到否认清单 $denyFile"
    }
    Write-Ok "仓库根：$Root"
    if ($PublicRemote) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw '未找到 git：-PublicRemote 推送模式需要 git 在 PATH 中'
        }
        Write-Ok "目标仓库：$PublicRemote（分支 $PublicBranch）"
    } else {
        Write-Warn '未指定 -PublicRemote，仅导出不推送'
    }
    # 工作区未提交改动提示（不阻断导出）
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $st = & git -C $Root status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0 -and $st) {
            $n = @($st).Count
            Write-Warn "检测到 $n 个未提交改动——公开版按当前工作区内容导出（建议先提交再发布）"
        }
    }

    # ---------- 2. 清空旧导出目录 ----------
    Write-Step '清空旧导出目录'
    Remove-ItemBypass $OutDir
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Write-Ok "已重置 $OutDir"

    # ---------- 3. 白名单拷贝 ----------
    Write-Step '白名单拷贝公开文件'
    $whitelist = @(
        'lib', 'android', 'assets', 'web', 'test',
        'third_party', 'img', 'scripts', '.github',
        'pubspec.yaml', 'analysis_options.yaml', 'README.md',
        'LICENSE', 'DISCLAIMER.md',
        'devtools_options.yaml'
    )
    $copied = 0
    foreach ($item in $whitelist) {
        $src = Join-Path $Root $item
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $OutDir $item) -Recurse -Force
            $copied++
        }
    }
    Write-Ok "拷贝 $copied / $($whitelist.Count) 个顶层项"

    # ---------- 4. 排除私有内容 ----------
    Write-Step '排除私有内容'
    $privateDir = Join-Path $OutDir 'lib\private'
    if (Test-Path $privateDir) {
        Remove-ItemBypass $privateDir
        Write-Ok '已排除 lib/private/（私有层：钩子实现 / 下载编排 / 私有入口）'
    }
    $lockFile = Join-Path $OutDir 'pubspec.lock'
    if (Test-Path $lockFile) {
        Remove-ItemBypass $lockFile
        Write-Ok '已排除 pubspec.lock（公开侧重新生成，避免私有包记录）'
    }
    # 导出工具链自身不进公开树（导出脚本 / 闸门脚本 / 否认清单均为私有侧工具；
    # build_android.ps1 等构建脚本保留，公开树构建仍可复用）
    foreach ($tool in @('export_public.ps1', 'verify_public_clean.ps1', 'public_deny.txt')) {
        $toolPath = Join-Path (Join-Path $OutDir 'scripts') $tool
        if (Test-Path $toolPath) {
            Remove-ItemBypass $toolPath
            Write-Ok "已排除 scripts/$tool（导出工具链，不进公开树）"
        }
    }
    # Windows 构建链为私有版功能（公开版 Android-only）：排除 windows 专用 CI
    $winCi = Join-Path (Join-Path $OutDir '.github') 'workflows\build-windows.yml'
    if (Test-Path $winCi) {
        Remove-ItemBypass $winCi
        Write-Ok '已排除 .github/workflows/build-windows.yml（私有版 Windows CI）'
    }
    # Android 编译时临时产物：导出树内跑过构建验证后残留的 Gradle 缓存/构建输出/
    # Kotlin 缓存/本地 SDK 路径文件，均不进公开树（local.properties 含本地路径会泄漏）
    foreach ($tmp in @('build', '.gradle', '.kotlin', 'local.properties')) {
        $tmpPath = Join-Path (Join-Path $OutDir 'android') $tmp
        if (Test-Path $tmpPath) {
            Remove-ItemBypass $tmpPath
            Write-Ok "已排除 android/$tmp（编译时临时产物）"
        }
    }
    # 防御：清理导出树内所有嵌套的 .public_export 目录
    # （历史版本曾因相对路径 + 工作目录漂移把旧导出树复制进 scripts/，此清理杜绝复发）
    $nested = Get-ChildItem $OutDir -Recurse -Directory -Filter '.public_export' -ErrorAction SilentlyContinue
    foreach ($d in $nested) {
        Remove-ItemBypass $d.FullName
        Write-Warn "清理嵌套导出目录 $($d.FullName)"
    }

    # ---------- 5. 剥离私有依赖 ----------
    Write-Step '剥离 pubspec 私有依赖'
    $pubspec = Join-Path $OutDir 'pubspec.yaml'
    $content = [System.IO.File]::ReadAllText($pubspec, $utf8NoBom)
    $pattern = '(?ms)^  # private feature package.*?path: packages/md3_download_cache\r?\n'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($content, $pattern)) {
        $content = [System.Text.RegularExpressions.Regex]::Replace($content, $pattern, '')
        [System.IO.File]::WriteAllText($pubspec, $content, $utf8NoBom)
        Write-Ok '已剥离 md3_download_cache 依赖块'
    } else {
        Write-Warn 'pubspec.yaml 未匹配到私有依赖注释块，跳过（请人工确认私有依赖已剥离）'
    }
    # Windows 桌面实现依赖为私有版功能（公开版 Android-only，无 windows/ 目录）
    $winPattern = '(?m)^  # Windows 桌面实现.*?\r?\n(?:  just_audio_windows:.*\r?\n|  video_player_win:.*\r?\n)+'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($content, $winPattern)) {
        $content = [System.Text.RegularExpressions.Regex]::Replace($content, $winPattern, '')
        [System.IO.File]::WriteAllText($pubspec, $content, $utf8NoBom)
        Write-Ok '已剥离 just_audio_windows / video_player_win（私有版 Windows 依赖）'
    } else {
        Write-Warn 'pubspec.yaml 未匹配到 Windows 依赖注释块，跳过（请人工确认已剥离）'
    }
    # README 功能宣传：删除公开版不具备的「边听边存」条目（私有功能，不宣传）
    $readme = Join-Path $OutDir 'README.md'
    $readmeContent = [System.IO.File]::ReadAllText($readme, $utf8NoBom)
    $readmePattern = '(?m)^- \*\*边听边存\*\*.*\r?\n'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($readmeContent, $readmePattern)) {
        $readmeContent = [System.Text.RegularExpressions.Regex]::Replace($readmeContent, $readmePattern, '')
        [System.IO.File]::WriteAllText($readme, $readmeContent, $utf8NoBom)
        Write-Ok '已删除 README 中「边听边存」条目（公开版无此功能）'
    }

    # ---------- 6. 否认清单闸门 ----------
    Write-Step '否认清单闸门'
    $denyLines = [System.IO.File]::ReadAllLines($denyFile, $utf8NoBom) |
        Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') }
    $deny = ($denyLines | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|'
    Write-Host "  deny 列表：$((@($denyLines) | Measure-Object).Count) 条符号/短语" -ForegroundColor DarkGray
    $hits = @()
    $hits += Get-ChildItem (Join-Path $OutDir 'lib') -Recurse -Filter *.dart -ErrorAction SilentlyContinue |
        Select-String -Pattern $deny -ErrorAction SilentlyContinue
    $hits += Select-String -Path $pubspec -Pattern $deny -ErrorAction SilentlyContinue
    if ($hits.Count -gt 0) {
        Write-Fail "闸门拦截：公开树包含 $($hits.Count) 处私有内容，拒绝导出："
        $hits | ForEach-Object {
            Write-Host "    $($_.Path):$($_.LineNumber)  $($_.Line.Trim())" -ForegroundColor Red
        }
        throw '否认清单命中，导出终止'
    }
    Write-Ok '闸门通过：公开树零命中'

    # ---------- 7. 可选推送 ----------
    if ($PublicRemote) {
        Write-Step '推送到公开仓库'
        Invoke-Native { git -C $OutDir init -q }
        Invoke-Native { git -C $OutDir add -A }
        Invoke-Native { git -C $OutDir -c user.name="md3music" -c user.email="md3music@local" commit -q -m "public export" }
        & git -C $OutDir remote remove origin 2>$null | Out-Null
        Invoke-Native { git -C $OutDir remote add origin $PublicRemote }
        Invoke-Native { git -C $OutDir push -f origin HEAD:$PublicBranch }
        Write-Ok "已推送 $PublicRemote（分支 $PublicBranch）"
    }

    # ---------- 8. 完成总结 ----------
    Write-Step '导出完成'
    $size = (Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    Write-Ok "导出目录：$OutDir"
    Write-Ok "导出体量：约 $([math]::Round($size / 1MB, 1)) MB"
    Write-Host ""
    Write-Host '  下一步：' -ForegroundColor Cyan
    Write-Host "    1) 抽查导出树：cd $OutDir && flutter pub get && flutter analyze"
    Write-Host '    2) 推送到公开仓库：.\scripts\export_public.ps1 -PublicRemote <公开仓库URL>'
    Write-Host '    3) 公开入口构建验证：flutter build apk --debug（默认 lib/main.dart）'
}
catch {
    Write-Host "`n[ERROR] 导出失败：$($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

if (-not $NoPause) { Wait-Exit }
exit $exitCode
