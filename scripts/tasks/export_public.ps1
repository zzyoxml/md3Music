#Requires -Version 5.1
<#
.SYNOPSIS
  公开版本导出：从私有单一源码仓库过滤出「公开版本」干净树，可选推送 / 开 PR。

.DESCRIPTION
  全程分步提示：
    1. 前置检查（仓库结构、否认清单、可选推送的 git）
    2. 清空旧导出目录
    3. 白名单拷贝公开文件（lib/android/assets/... 顶层项）
    4. 排除私有内容（lib/private/、pubspec.lock、私有侧工具链、编译临时产物）
    5. 剥离 pubspec.yaml 的私有依赖块与 README 私有功能条目
    6. 否认清单闸门（scripts/public_deny.txt，lib/ 与 pubspec 零命中才通过）
    7. 可选：推送导出树到公开仓库（force push 覆盖分支，或 -AsPr 开 PR 审阅）
    8. 完成总结（目录 / 体量 / 下一步建议）

  公开版本 = 本仓库过滤导出的干净树，不是独立代码库。
  任何一步失败都会在退出前打印明确的红色错误并暂停，便于双击运行时看到原因。

.PARAMETER OutDir
  导出目录（默认 .public_export，已在 .gitignore 中排除）。
  相对路径基于项目根解析，与当前工作目录无关。

.PARAMETER PublicRemote
  公开仓库 URL。提供时导出完成后推送。
  示例：https://github.com/zzyoxml/md3Music.git

.PARAMETER PublicBranch
  公开仓库的目标分支（默认 main）。force push 模式直接覆盖它；-AsPr 模式以它为 PR base。

.PARAMETER AsPr
  不直接覆盖目标分支：浅克隆公开仓库 → 用导出树替换工作区内容 → 推到新分支 → 开 PR。
  这样公开仓库保留历史，PR 里能逐文件审阅本次导出的差异。

.PARAMETER PrBranch
  -AsPr 模式的分支名（默认 public-export-<yyyyMMdd-HHmm>）。

.PARAMETER NoPause
  结束时不等待按键（CI/被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 export                                     # 只导出 + 闸门校验
  .\scripts\md3.ps1 export -PublicRemote <URL>                 # 导出 + force push 覆盖 main
  .\scripts\md3.ps1 export -PublicRemote <URL> -AsPr           # 导出 + 推分支 + 开 PR
  .\scripts\md3.ps1 export -PublicRemote <URL> -NoPause        # CI/非交互环境
#>
[CmdletBinding()]
param(
    [string]$OutDir = '.public_export',
    [string]$PublicRemote = '',
    [string]$PublicBranch = 'main',
    [switch]$AsPr,
    [string]$PrBranch = '',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Root = Get-RepoRoot
# 相对目录统一解析到项目根，避免脚本行为依赖当前工作目录
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $Root $OutDir }
$utf8NoBom = Get-Utf8NoBom
$exitCode = 0

try {
    # ---------- 1. 前置检查 ----------
    Write-Step '前置检查'
    if (-not (Test-Path (Join-Path $Root 'pubspec.yaml'))) {
        throw "未找到 pubspec.yaml（$Root），请确认脚本位于项目根 scripts/tasks/ 目录"
    }
    $denyFile = Join-Path $Root 'scripts\public_deny.txt'
    if (-not (Test-Path $denyFile)) { throw "未找到否认清单 $denyFile" }
    Write-Ok "仓库根：$Root"
    if ($PublicRemote) {
        Assert-Command git '-PublicRemote 推送模式需要 git 在 PATH 中'
        $mode = if ($AsPr) { "开 PR 到 $PublicBranch" } else { "force push 覆盖 $PublicBranch" }
        Write-Ok "目标仓库：$PublicRemote（$mode）"
    } else {
        Write-Warn '未指定 -PublicRemote，仅导出不推送'
        if ($AsPr) { Write-Warn '-AsPr 需要 -PublicRemote，本次忽略' }
    }
    # 工作区未提交改动提示（不阻断导出）
    if (Test-HasCommand git) {
        $st = & git -C $Root status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0 -and $st) {
            Write-Warn "检测到 $(@($st).Count) 个未提交改动——公开版按当前工作区内容导出（建议先提交再发布）"
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
    # 导出工具链自身不进公开树（导出 / 闸门 / 一键提交 / 否认清单均为私有侧工具；
    # md3.ps1 + lib/common.ps1 + android/windows 任务保留，公开树构建仍可复用）
    foreach ($tool in @('tasks\export_public.ps1', 'tasks\verify_public.ps1', 'tasks\commit.ps1', 'public_deny.txt')) {
        $toolPath = Join-Path (Join-Path $OutDir 'scripts') $tool
        if (Test-Path $toolPath) {
            Remove-ItemBypass $toolPath
            Write-Ok "已排除 scripts/$($tool -replace '\\','/')（导出工具链，不进公开树）"
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
    # third_party/just_audio fork 的 Gradle 缓存（fork 构建产生，不进公开树）
    $forkGradle = Get-ChildItem (Join-Path $OutDir 'third_party\just_audio') -Recurse -Directory -Filter '.gradle' -ErrorAction SilentlyContinue
    foreach ($d in $forkGradle) {
        Remove-ItemBypass $d.FullName
        Write-Ok "已排除 $($d.FullName.Substring($OutDir.Length + 1))（fork Gradle 缓存）"
    }
    # 下载元数据写入插件：Dart 端 metadata_writer 已隔离进 lib/private，
    # 原生端（Kotlin 插件 + MainActivity 注册）导出时一并移除
    $metaPlugin = Join-Path $OutDir 'android\app\src\main\kotlin\com\md3music\md3music\MetadataWriterPlugin.kt'
    if (Test-Path $metaPlugin) {
        Remove-ItemBypass $metaPlugin
        Write-Ok '已排除 MetadataWriterPlugin.kt（下载元数据写入插件）'
    }
    $mainAct = Join-Path $OutDir 'android\app\src\main\kotlin\com\md3music\md3music\MainActivity.kt'
    if (Test-Path $mainAct) {
        $maContent = [System.IO.File]::ReadAllText($mainAct, $utf8NoBom)
        $maPattern = '(?m)^\s*// 注册 MetadataWriterPlugin.*\r?\n\s*MetadataWriterPlugin\(\)\.register\(flutterEngine\)\r?\n'
        if ([System.Text.RegularExpressions.Regex]::IsMatch($maContent, $maPattern)) {
            $maContent = [System.Text.RegularExpressions.Regex]::Replace($maContent, $maPattern, '')
            [System.IO.File]::WriteAllText($mainAct, $maContent, $utf8NoBom)
            Write-Ok '已剥离 MainActivity 中 MetadataWriterPlugin 注册'
        }
    }
    # 防御：清理导出树内所有嵌套的 .public_export 目录
    # （历史版本曾因相对路径 + 工作目录漂移把旧导出树复制进 scripts/，此清理杜绝复发）
    foreach ($d in (Get-ChildItem $OutDir -Recurse -Directory -Filter '.public_export' -ErrorAction SilentlyContinue)) {
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
    if (Test-Path $readme) {
        $readmeContent = [System.IO.File]::ReadAllText($readme, $utf8NoBom)
        $readmePattern = '(?m)^- \*\*边听边存\*\*.*\r?\n'
        if ([System.Text.RegularExpressions.Regex]::IsMatch($readmeContent, $readmePattern)) {
            $readmeContent = [System.Text.RegularExpressions.Regex]::Replace($readmeContent, $readmePattern, '')
            [System.IO.File]::WriteAllText($readme, $readmeContent, $utf8NoBom)
            Write-Ok '已删除 README 中「边听边存」条目（公开版无此功能）'
        }
    }

    # ---------- 6. 否认清单闸门 ----------
    Write-Step '否认清单闸门'
    $gate = Invoke-DenyGate -TreeRoot $OutDir -DenyFile $denyFile
    Write-Note "deny 列表：$($gate.DenyCount) 条符号/短语"
    $allHits = @($gate.LibHits) + @($gate.PubspecHits)
    if ($allHits.Count -gt 0) {
        Write-Fail "闸门拦截：公开树包含 $($allHits.Count) 处私有内容，拒绝导出："
        Write-DenyHits -Hits $allHits
        throw '否认清单命中，导出终止'
    }
    Write-Ok '闸门通过：公开树零命中'
    # ---------- 7. 可选推送 ----------
    if ($PublicRemote -and -not $AsPr) {
        # 覆盖模式：导出树是全新 git init 的单提交仓库，force push 直接覆盖目标分支
        Write-Step "推送到公开仓库（force push 覆盖 $PublicBranch）"
        Invoke-Native { git -C $OutDir init -q }
        Invoke-Native { git -C $OutDir add -A }
        Invoke-Native { git -C $OutDir -c user.name="md3music" -c user.email="md3music@local" commit -q -m "public export" }
        & git -C $OutDir remote remove origin 2>$null | Out-Null
        Invoke-Native { git -C $OutDir remote add origin $PublicRemote }
        Invoke-Native { git -C $OutDir push -f origin HEAD:$PublicBranch }
        Write-Ok "已推送 $PublicRemote（分支 $PublicBranch）"
    }
    elseif ($PublicRemote -and $AsPr) {
        # PR 模式：必须保留公开仓库历史，否则「无关历史」的分支无法与 main 比较、开不了 PR。
        # 做法是浅克隆公开仓库 → 用导出树整体替换工作区 → 提交到新分支 → 开 PR。
        Write-Step "推送到公开仓库新分支并开 PR（base: $PublicBranch）"
        if (-not $PrBranch) { $PrBranch = "public-export-$(Get-Date -Format 'yyyyMMdd-HHmm')" }
        $clone = Join-Path $env:TEMP "md3music-public-pr-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Remove-ItemBypass $clone
        Invoke-Native { git clone --depth 1 --branch $PublicBranch $PublicRemote $clone }
        Invoke-Native { git -C $clone checkout -q -b $PrBranch }
        # 清空克隆工作区（保留 .git），再整体放入导出树：删除的文件才能体现在 PR 差异里
        foreach ($item in (Get-ChildItem $clone -Force | Where-Object { $_.Name -ne '.git' })) {
            Remove-ItemBypass $item.FullName
        }
        foreach ($item in (Get-ChildItem $OutDir -Force)) {
            Copy-Item $item.FullName (Join-Path $clone $item.Name) -Recurse -Force
        }
        Invoke-Native { git -C $clone add -A }
        $diff = & git -C $clone status --porcelain
        if (-not $diff) {
            Write-Warn '导出树与公开仓库当前内容一致，无差异可提交，跳过 PR'
            Write-Note "克隆目录：$clone"
        } else {
            $srcSha = (& git -C $Root rev-parse --short HEAD 2>$null)
            $title = "public export $(Get-Date -Format 'yyyy-MM-dd HH:mm')$(if ($srcSha) { " (private @$srcSha)" })"
            $body  = "由 scripts/md3.ps1 export -AsPr 生成的公开版本导出快照。`n`n"
            $body += "- 源：私有仓库 $(if ($srcSha) { "HEAD @$srcSha" } else { '工作区' })`n"
            $body += "- 否认清单闸门：通过（$($gate.DenyCount) 条规则零命中）`n"
            $body += "- 变更文件数：$(@($diff).Count)`n"
            Invoke-Native { git -C $clone -c user.name="md3music" -c user.email="md3music@local" commit -q -m $title }
            Invoke-Native { git -C $clone push -u origin $PrBranch }
            Write-Ok "已推送分支 $PrBranch（$(@($diff).Count) 个文件变更）"
            New-GitHubPr -RemoteUrl $PublicRemote -Base $PublicBranch -Head $PrBranch -Title $title -Body $body -RepoDir $clone
            Write-Note "克隆目录（如需人工补救）：$clone"
        }
    }

    # ---------- 8. 完成总结 ----------
    Write-Step '导出完成'
    $size = (Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Ok "导出目录：$OutDir"
    Write-Ok "导出体量：约 $([math]::Round($size / 1MB, 1)) MB"
    Write-Host ''
    Write-Host '  下一步：' -ForegroundColor Cyan
    Write-Host "    1) 抽查导出树：cd $OutDir && flutter pub get && flutter analyze"
    Write-Host '    2) 覆盖式发布：.\scripts\md3.ps1 export -PublicRemote <公开仓库URL>'
    Write-Host '    3) 走 PR 审阅：.\scripts\md3.ps1 export -PublicRemote <公开仓库URL> -AsPr'
    Write-Host '    4) 公开入口构建验证：flutter build apk --debug（默认 lib/main.dart）'
}
catch {
    Write-Host "`n[ERROR] 导出失败：$($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

if (-not $NoPause) { Wait-Exit }
exit $exitCode
