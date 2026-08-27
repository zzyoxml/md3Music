#Requires -Version 5.1
<#
.SYNOPSIS
  公开版本导出：从私有单一源码仓库过滤出「公开版本」干净树，可选推送 / 开 PR。

.DESCRIPTION
  全程分步提示：
    1. 前置检查（仓库结构、否认清单、可选推送的 git）
    2. 清空旧导出目录
    3. 白名单拷贝公开文件（lib/android/assets/... 顶层项，scripts/ 不在其中）
    4. 排除私有内容（lib/private/、pubspec.lock、scripts/ 残留、编译临时产物）
    5. 剥离 pubspec.yaml 的私有依赖块与 README 私有功能条目
    6. 否认清单闸门（scripts/public_deny.txt，lib/ 与 pubspec 零命中才通过）
    7. 可选：发布到公开仓库（默认开 PR 审阅；加 -ForcePush 才直推覆盖分支）
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
  公开仓库的目标分支（默认 main）。PR 模式以它为 base；-ForcePush 模式直接覆盖它。

.PARAMETER AsPr
  【兼容保留】旧参数。开 PR 现已是给了 -PublicRemote 后的默认行为，本开关不再产生差异。

.PARAMETER ForcePush
  例外路径：不走进 PR，导出树打包成全新单提交仓库 force push 直接覆盖目标分支。
  公开仓库历史会被整段替换，仅在明确需要重写公开树时使用；交互环境下会再确认一次。

.PARAMETER PrBranch
  PR 模式的分支名（默认 public-export-<yyyyMMdd-HHmm>）。

.PARAMETER Changelog
  导出前先更新 CHANGELOG.md：总结上次记录哈希之后的提交（LLM 生成，需用户确认后才写入，
  或配合 -ChangelogYes 自动确认），以指定/提示的新版本号写入私有仓库根 CHANGELOG.md 并记录状态。

.PARAMETER ChangelogVersion
  配合 -Changelog 的新版本号（如 v5.4.0）；不填且交互环境时在 changelog 任务里提示输入。

.PARAMETER ChangelogSince
  配合 -Changelog 的起始提交哈希；不填时自动使用上次记录的哈希（无记录则交互提示）。

.PARAMETER ChangelogYes
  配合 -Changelog 跳过生成结果的确认（非交互自动化用）。

.PARAMETER WithHistory
  配合 -ForcePush：把私有仓库提交记录以「空树提交」历史一并推送到目标分支，
  顶端再叠加本次公开树快照，形成「提交记录完整、文件内容只在顶端」的分支。
  历史不含任何文件内容（无 blob），下载/缓存代码零残留，可追溯但不可看代码。
  仅 force push 覆盖模式有效；PR 模式下本开关无效（被忽略）。

.PARAMETER NoPause
  结束时不等待按键（CI/被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 export                                     # 只导出 + 闸门校验
  .\scripts\md3.ps1 export -PublicRemote <URL>                 # 导出 + 推分支 + 开 PR（默认）
  .\scripts\md3.ps1 export -PublicRemote <URL> -ForcePush      # 导出 + force push 覆盖 main（例外）
  .\scripts\md3.ps1 export -PublicRemote <URL> -ForcePush -WithHistory  # 覆盖并携带提交记录历史（空树提交 + 顶端公开树）
  .\scripts\md3.ps1 export -Changelog -ChangelogVersion v5.4.0 # 更新 CHANGELOG 后随导出携带
  .\scripts\md3.ps1 export -PublicRemote <URL> -NoPause        # CI/非交互环境
#>
[CmdletBinding()]
param(
    [string]$OutDir = '.public_export',
    [string]$PublicRemote = '',
    [string]$PublicBranch = 'main',
    [switch]$AsPr,
    [switch]$ForcePush,
    [string]$PrBranch = '',
    [switch]$Changelog,
    [string]$ChangelogVersion = '',
    [string]$ChangelogSince = '',
    [switch]$ChangelogYes,
    [switch]$WithHistory,
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
    if ($AsPr -and $ForcePush) { throw '-AsPr 与 -ForcePush 不能同时使用（开 PR 已是默认行为，-AsPr 仅为兼容保留）' }
    if ($PublicRemote) {
        Assert-Command git '-PublicRemote 推送模式需要 git 在 PATH 中'
        if ($AsPr) { Write-Note '-AsPr 已为默认行为，无需显式指定（参数兼容保留）' }
        if ($WithHistory -and -not $ForcePush) {
            Write-Warn '-WithHistory 仅在 -ForcePush 覆盖模式下有效，本次忽略（PR 模式基于公开仓库现有历史，无法携带独立重建的提交记录）'
        }
        $mode = if ($ForcePush) { "-ForcePush：直接覆盖 $PublicBranch$(if ($WithHistory) { '（含提交记录历史）' } else { '' })" } else { "默认：开 PR 到 $PublicBranch" }
        Write-Ok "目标仓库：$PublicRemote（$mode）"
        if ($ForcePush -and (Test-InteractiveConsole)) {
            if (-not (Read-YesNo "确认要 force push 直接覆盖 $PublicRemote 的 $PublicBranch 分支吗？公开仓库历史将被整段替换")) {
                Write-Warn '已取消发布，仅导出到本地目录'
                $PublicRemote = ''
            }
        }
    } else {
        Write-Warn '未指定 -PublicRemote，仅导出不推送'
        if ($AsPr -or $ForcePush) { Write-Warn '-AsPr / -ForcePush 需要 -PublicRemote，本次忽略' }
    }
    # 工作区未提交改动提示（不阻断导出）
    if (Test-HasCommand git) {
        $st = & git -C $Root status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0 -and $st) {
            Write-Warn "检测到 $(@($st).Count) 个未提交改动——公开版按当前工作区内容导出（建议先提交再发布）"
        }
    }

    # ---------- 1.5 可选：更新 CHANGELOG（在清空导出目录之前，避免失败时白清） ----------
    if ($Changelog) {
        Write-Step '更新 CHANGELOG（可选）'
        # 哈希表 splat 才能按命名参数绑定（数组 splat 会按位置传参，开关会被当普通值）
        $chgArgs = @{ NoPause = $true }
        if ($ChangelogVersion) { $chgArgs.Version = $ChangelogVersion }
        if ($ChangelogSince)   { $chgArgs.SinceHash = $ChangelogSince }
        if ($ChangelogYes)     { $chgArgs.Yes = $true }
        & (Join-Path $PSScriptRoot 'changelog.ps1') @chgArgs
        if ($LASTEXITCODE -ne 0) { throw "CHANGELOG 更新失败（退出码 $LASTEXITCODE），中止导出" }
        Write-Ok 'CHANGELOG 步骤结束（如选择放弃，则 CHANGELOG.md 维持原状）'
        Write-Note '注意：CHANGELOG.md 与 scripts/changelog_state.json 可能已改动，请随本次发布一并提交'
    }

    # ---------- 2. 清空旧导出目录 ----------
    Write-Step '清空旧导出目录'
    Remove-ItemBypass $OutDir
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Write-Ok "已重置 $OutDir"

    # ---------- 3. 白名单拷贝 ----------
    Write-Step '白名单拷贝公开文件'
    # scripts/ 不作为整目录进白名单：只在「导出部分脚本」步骤里拷贝 android/windows 两个
    # 构建脚本（自带对 lib/common.ps1 缺失的兜底，可独立运行）；其余全部是私有侧工具链。
    $whitelist = @(
        'lib', 'android', 'assets', 'web', 'test',
        'third_party', 'img', '.github',
        'kugou_api_server/rust',
        'pubspec.yaml', 'analysis_options.yaml', 'README.md',
        'CHANGELOG.md', 'LICENSE', 'DISCLAIMER.md',
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
    # scripts/：只导出 android / windows 两个构建脚本（脚本内已带「公共库缺失时自包含」
    # 兜底，可脱离 lib/common.ps1 独立运行）。其余脚本（export/verify/commit/token/
    # changelog 任务、lib/、tools/、public_deny.txt 等）都是私有侧工具链，一律不进公开树。
    $scriptAllow = @('tasks\android.ps1', 'tasks\windows.ps1')
    $outScripts = Join-Path $OutDir 'scripts'
    New-Item -ItemType Directory -Force -Path (Join-Path $outScripts 'tasks') | Out-Null
    foreach ($rel in $scriptAllow) {
        $src = Join-Path $Root ('scripts\' + $rel)
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $outScripts $rel) -Force
            Write-Ok "已导出 scripts/$rel（公开侧构建脚本）"
        }
    }
    # 防御：scripts/ 内不在允许清单的文件一律清掉（防止未来新任务脚本被误带进公开树）
    foreach ($f in (Get-ChildItem $outScripts -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($outScripts.Length + 1)
        if ($rel -notin $scriptAllow) {
            Remove-ItemBypass $f.FullName
            Write-Warn "已清理 scripts/$rel（不在构建脚本允许清单内）"
        }
    }
    # .trae/：AI 工具计划/工作产物。白名单本就不含（不会复制进来），这里再防御性删除，
    # 杜绝未来白名单误加或历史导出树残留（.trae/ 下即使有内容也绝不进公开树）
    $traeDir = Join-Path $OutDir '.trae'
    if (Test-Path $traeDir) {
        Remove-ItemBypass $traeDir
        Write-Ok '已排除 .trae/（AI 计划/工作产物，绝不进公开树）'
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
    # Rust API 服务器源码（kugou_api_server/rust）随公开导出，但本地构建/工具链临时物不进公开树：
    # target* 系列（target/、target-native/、target-wsl/ 等）是 cargo 交叉编译产物，名称不定，
    # 且 Copy-Item 不认 .gitignore 会一并复制；.cargo/ 是本地 linker/CC 工具链配置。均须显式排除。
    $rustSrc = Join-Path $OutDir 'kugou_api_server\rust'
    if (Test-Path $rustSrc) {
        foreach ($d in @(Get-ChildItem $rustSrc -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'target*' -or $_.Name -eq '.cargo' })) {
            Remove-ItemBypass $d.FullName
            Write-Ok "已排除 kugou_api_server/rust/$($d.Name)（本地构建/工具链临时物）"
        }
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

    # AndroidManifest 与 main.dart：公开版不请求「所有文件访问」权限（MANAGE_EXTERNAL_STORAGE）。
    # 该权限供私有版下载/边听边存写公共目录文件元数据（封面/歌词）使用；公开版无下载功能，
    # 导出时一并剔除（与公开库 4fc6c43 移除 MANAGE_EXTERNAL_STORAGE 保持一致），
    # 避免公开版在无该权限的 Manifest 前提下仍向上发权限申请。
    $manifest = Join-Path $OutDir 'android\app\src\main\AndroidManifest.xml'
    if (Test-Path $manifest) {
        $mfContent = [System.IO.File]::ReadAllText($manifest, $utf8NoBom)
        $mfPattern = '(?m)^\s*<!-- Android 11\+ 修改外部存储文件元数据.*\r?\n\s*<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />\r?\n'
        if ([System.Text.RegularExpressions.Regex]::IsMatch($mfContent, $mfPattern)) {
            $mfContent = [System.Text.RegularExpressions.Regex]::Replace($mfContent, $mfPattern, '')
            # 兜底：权限行可能无注释，仅剩单行时再清一次
            $mfContent = $mfContent -replace '(?m)^\s*<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />\r?\n', ''
            [System.IO.File]::WriteAllText($manifest, $mfContent, $utf8NoBom)
            Write-Ok '已移除 AndroidManifest 中 MANAGE_EXTERNAL_STORAGE（所有文件访问）权限'
        } else {
            Write-Warn 'AndroidManifest 未匹配到 MANAGE_EXTERNAL_STORAGE 权限，跳过（请人工确认公开版权限已收敛）'
        }
    }
    $outMain = Join-Path $OutDir 'lib\main.dart'
    if (Test-Path $outMain) {
        $mmContent = [System.IO.File]::ReadAllText($outMain, $utf8NoBom)
        $mmPattern = '(?s)  // Android 11\+ 管理外部存储权限.*?\r?\n  }\r?\n'
        if ([System.Text.RegularExpressions.Regex]::IsMatch($mmContent, $mmPattern)) {
            $mmContent = [System.Text.RegularExpressions.Regex]::Replace($mmContent, $mmPattern, '')
            [System.IO.File]::WriteAllText($outMain, $mmContent, $utf8NoBom)
            Write-Ok '已剥离 main.dart 中 manageExternalStorage 权限请求'
        } else {
            Write-Warn 'main.dart 未匹配到 manageExternalStorage 请求块，跳过（请人工确认已剥离）'
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
    # ---------- 7. 可选发布（默认开 PR；-ForcePush 才直推覆盖） ----------
    if ($PublicRemote -and $ForcePush) {
        if ($WithHistory) {
            # 带提交记录模式：私有提交历史重建为空树提交 → 公开树叠加为顶端提交 → force push。
            # 生成「消息完整、diff 全空」的历史，可追溯提交记录但看不到任何文件内容（无 blob）。
            Write-Step "推送到公开仓库（force push 覆盖 $PublicBranch，含提交记录历史）"
            $histDir = Join-Path $env:TEMP "md3music-public-messages-$(Get-Date -Format 'yyyyMMddHHmmss')"
            $histArgs = @{ OutDir = $histDir; PublicBranch = $PublicBranch; NoPause = $true }
            [void](Enable-AutoProxy)
            & (Join-Path $PSScriptRoot 'export_messages_history.ps1') @histArgs
            if ($LASTEXITCODE -ne 0) { throw "提交记录历史重建失败（退出码 $LASTEXITCODE），中止发布" }
            # 公开树（排除残留 .git）整体放入历史仓库，叠加为顶端提交
            foreach ($item in (Get-ChildItem $OutDir -Force | Where-Object { $_.Name -ne '.git' })) {
                Copy-Item $item.FullName (Join-Path $histDir $item.Name) -Recurse -Force
            }
            Invoke-Native { git -C $histDir add -A }
            Invoke-Native { git -C $histDir -c user.name="md3music" -c user.email="md3music@local" commit -q -m "public export" }
            Invoke-Native { git -C $histDir remote add origin $PublicRemote }
            Invoke-WithRetry -What '推送公开仓库' -Action { Invoke-Native { git -C $histDir push -f origin HEAD:$PublicBranch } }
            Write-Ok "已推送 $PublicRemote（分支 $PublicBranch，含提交记录历史）"
            Write-Note "历史仓库（如需人工补救）：$histDir"
        } else {
            # 覆盖模式：导出树是全新 git init 的单提交仓库，force push 直接覆盖目标分支
            Write-Step "推送到公开仓库（force push 覆盖 $PublicBranch）"
            [void](Enable-AutoProxy)
            Invoke-Native { git -C $OutDir init -q }
            Invoke-Native { git -C $OutDir add -A }
            Invoke-Native { git -C $OutDir -c user.name="md3music" -c user.email="md3music@local" commit -q -m "public export" }
            # 全新 init 的导出树本无 origin；remove 仅作幂等清理（可能残留自上次 force push）。
            # 注意：git 在无 origin 时报 "error: No such remote: 'origin'"，会被 $ErrorActionPreference='Stop'
            # 误判为 NativeCommandError 并中断脚本（此前正是卡在这里，导致 remote add 与 push 未执行）。
            # 因此这里临时放宽 ErrorActionPreference，仅让清理静默完成。
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & git -C $OutDir remote remove origin 2>&1 | Out-Null
            $ErrorActionPreference = $prevEAP
            Invoke-Native { git -C $OutDir remote add origin $PublicRemote }
            Invoke-WithRetry -What '推送公开仓库' -Action { Invoke-Native { git -C $OutDir push -f origin HEAD:$PublicBranch } }
            Write-Ok "已推送 $PublicRemote（分支 $PublicBranch）"
        }
    }
    elseif ($PublicRemote) {
        # PR 模式（默认）：必须保留公开仓库历史，否则「无关历史」的分支无法与 main 比较、开不了 PR。
        # 做法是浅克隆公开仓库 → 用导出树整体替换工作区 → 提交到新分支 → 开 PR。
        Write-Step "推送到公开仓库新分支并开 PR（base: $PublicBranch）"
        [void](Enable-AutoProxy)
        if (-not $PrBranch) { $PrBranch = "public-export-$(Get-Date -Format 'yyyyMMdd-HHmm')" }
        $clone = Join-Path $env:TEMP "md3music-public-pr-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Invoke-WithRetry -What '克隆公开仓库' -Action {
            Remove-ItemBypass $clone
            Invoke-Native { git clone --depth 1 --branch $PublicBranch $PublicRemote $clone }
        }
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
            $body  = "由 scripts/md3.ps1 export 生成的公开版本导出快照（PR 审阅模式）。`n`n"
            $body += "- 源：私有仓库 $(if ($srcSha) { "HEAD @$srcSha" } else { '工作区' })`n"
            $body += "- 否认清单闸门：通过（$($gate.DenyCount) 条规则零命中）`n"
            $body += "- 变更文件数：$(@($diff).Count)`n"
            Invoke-Native { git -C $clone -c user.name="md3music" -c user.email="md3music@local" commit -q -m $title }
            Invoke-WithRetry -What '推送 PR 分支' -Action { Invoke-Native { git -C $clone push -u origin $PrBranch } }
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
    Write-Host '    2) 发布到公开仓库（默认开 PR 审阅）：.\scripts\md3.ps1 export -PublicRemote <公开仓库URL>'
    Write-Host '    3) 覆盖式直推（例外，需确认）：.\scripts\md3.ps1 export -PublicRemote <公开仓库URL> -ForcePush'
    Write-Host '    4) 公开入口构建验证：flutter build apk --debug（默认 lib/main.dart）'
    Write-Host '    5) 更新发布日志：.\scripts\md3.ps1 changelog（总结提交并写入 CHANGELOG.md）'
}
catch {
    Write-Host "`n[ERROR] 导出失败：$($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

if (-not $NoPause) { Wait-Exit }
exit $exitCode
