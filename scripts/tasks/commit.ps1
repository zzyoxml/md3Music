#Requires -Version 5.1
<#
.SYNOPSIS
  一键提交：TUI 勾选改动 -> 否认清单闸门 -> 提交 -> 推送 -> 可选开 PR。

.DESCRIPTION
  面向本仓库「私有开发 + 公开导出」双仓库流程的提交入口，替代大部分 GitHub Desktop 操作：

    1. 列出工作区所有改动（含未跟踪文件），方向键 + 空格勾选本次要提交的文件
    2. 提交前跑否认清单闸门（scripts/public_deny.txt），命中私有符号即中止
    3. 自动生成 conventional commit 候选信息，回车接受或直接改写
    4. 提交并推送当前分支到 origin（首次推送自动 -u 建立跟踪）
    5. 可选：向 upstream 开 PR / 导出公开版本（覆盖推送或开 PR）

  未勾选的文件只是本次不提交，仍留在工作区，不写入任何忽略文件。
  注意：确认后脚本会按勾选结果重置暂存区（git reset + git add 勾选项），
  因此事先用 GitHub Desktop 做的部分行暂存会被本次选择覆盖。

.PARAMETER Message
  提交信息。不传则进入候选信息确认/编辑环节。

.PARAMETER All
  跳过勾选界面，直接提交全部改动。

.PARAMETER NoPush
  只提交，不推送。

.PARAMETER Pr
  推送后向 upstream 仓库开 PR（fork -> upstream 流程），不自动合并。

.PARAMETER PrMerge
  推送后向 upstream 开 PR **并直接合并**（merge commit 策略），合并后默认把结果拉回本地并同步 origin。
  走 GitHub REST API，需要对 upstream 有写权限的 PAT（用 md3.ps1 token 管理）。

.PARAMETER NoSyncBack
  -PrMerge 合并成功后不拉回 upstream 的合并结果（默认会 fetch + merge + 推 origin）。

.PARAMETER PrBase
  upstream PR 的 base 分支（默认与当前分支同名）。

.PARAMETER PublicExport
  提交后导出公开版本并覆盖推送公开仓库（force push）。

.PARAMETER PublicPr
  提交后导出公开版本并在公开仓库开 PR（推荐，可审阅导出差异）。

.PARAMETER PublicRemote
  公开仓库 URL（默认取 git remote 'public'，缺失则用 zzyoxml/md3Music）。

.PARAMETER SkipGate
  跳过否认清单闸门（仅在明知改动不涉及公开面时使用）。

.PARAMETER Yes
  非交互：不询问后续动作，只执行命令行显式指定的步骤。

.EXAMPLE
  .\scripts\md3.ps1 commit
  .\scripts\md3.ps1 commit -All -Message "fix(player): 修复切歌闪烁"
  .\scripts\md3.ps1 commit -Pr
  .\scripts\md3.ps1 commit -PublicPr
#>
[CmdletBinding()]
param(
    [string]$Message = '',
    [switch]$All,
    [switch]$NoPush,
    [switch]$Pr,
    [switch]$PrMerge,
    [switch]$NoSyncBack,
    [string]$PrBase = '',
    [switch]$PublicExport,
    [switch]$PublicPr,
    [string]$PublicRemote = '',
    [switch]$SkipGate,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Root = Get-RepoRoot
Assert-Command git '一键提交需要 git 在 PATH 中'

# git 输出含中文路径：关掉 quotepath 的八进制转义，并把控制台读取编码切到 UTF-8
$script:PrevOutEnc = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$GitArgs, [switch]$Quiet)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Root -c core.quotepath=false @GitArgs 2>&1
        if (-not $Quiet -and $LASTEXITCODE -ne 0) {
            throw "git $($GitArgs -join ' ') 失败（退出码 $LASTEXITCODE）：`n$($out -join "`n")"
        }
        $out
    }
    finally { $ErrorActionPreference = $prev }
}

# ---------- 改动清单 ----------
# 返回 [pscustomobject]{ Code; Path; Orig; Staged; Untracked; Deleted; Add; Del; Checked }
function Get-ChangeList {
    $lines = @(Invoke-Git @('status', '--porcelain', '-uall'))
    Invoke-Git @('rev-parse', '--verify', '-q', 'HEAD') -Quiet | Out-Null
    $hasHead = ($LASTEXITCODE -eq 0)

    # 行数统计：一次拿全（工作区+暂存区 相对 HEAD），未跟踪文件单独数行
    $stat = @{}
    if ($hasHead) {
        foreach ($l in @(Invoke-Git @('diff', '--numstat', 'HEAD'))) {
            $p = $l -split "`t"
            if ($p.Count -ge 3) { $stat[$p[2]] = @{ Add = $p[0]; Del = $p[1] } }
        }
    }

    $items = @()
    foreach ($line in $lines) {
        if ($line.Length -lt 4) { continue }
        $idx = $line.Substring(0, 1)
        $wt  = $line.Substring(1, 1)
        $rest = $line.Substring(3)
        $orig = $null
        if ($rest -match '^(.*?) -> (.*)$') { $orig = $Matches[1]; $rest = $Matches[2] }
        $path = $rest.Trim('"')
        $untracked = ($idx -eq '?')
        $deleted = ($idx -eq 'D' -or $wt -eq 'D')

        $add = ''; $del = ''
        if ($untracked) {
            $full = Join-Path $Root $path
            if (Test-Path -LiteralPath $full) {
                try { $add = @(Get-Content -LiteralPath $full -ErrorAction Stop).Count } catch { $add = '?' }
            }
            $del = 0
        }
        elseif ($stat.ContainsKey($path)) { $add = $stat[$path].Add; $del = $stat[$path].Del }

        $items += [pscustomobject]@{
            Code      = ($idx + $wt)
            Path      = $path
            Orig      = $orig
            Staged    = ($idx -ne ' ' -and $idx -ne '?')
            Untracked = $untracked
            Deleted   = $deleted
            Add       = $add
            Del       = $del
            Checked   = $true
        }
    }
    $items
}

function Format-ChangeLabel([object]$It) {
    $code = if ($It.Untracked) { '??' } else { $It.Code.Trim().PadRight(2) }
    $info = if ($It.Untracked) { "新文件 +$($It.Add)" }
            elseif ($It.Deleted) { '已删除' }
            elseif ($It.Add -ne '' ) { "+$($It.Add) -$($It.Del)" }
            else { '' }
    $name = if ($It.Orig) { "$($It.Orig) -> $($It.Path)" } else { $It.Path }
    [pscustomobject]@{ Code = $code; Name = $name; Info = $info }
}
# ---------- 改动挑选界面 ----------
# 列表/按钮/滚动统一走 lib/ui.ps1 的 Show-CheckList（鼠标 + 键盘），这里只提供
# 行格式化、统计行与 diff 详情三个回调。
$script:KeyHint = '请在 PowerShell 窗口中运行，或改用非交互方式：md3.ps1 commit -All -Message "..." -Yes'

function Show-FileDiff([object]$It) {
    Clear-Host
    Write-Host "diff: $($It.Path)" -ForegroundColor Cyan
    Write-Host ''
    if ($It.Untracked) {
        $full = Join-Path $Root $It.Path
        Write-Host '（未跟踪的新文件，显示前 200 行）' -ForegroundColor DarkGray
        Get-Content -LiteralPath $full -TotalCount 200 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "+$_" -ForegroundColor Green }
    } else {
        foreach ($l in @(Invoke-Git @('--no-pager', 'diff', 'HEAD', '--', $It.Path) -Quiet)) {
            $c = if ($l -like '+++*' -or $l -like '---*') { 'DarkGray' }
                 elseif ($l -like '+*') { 'Green' }
                 elseif ($l -like '-*') { 'Red' }
                 elseif ($l -like '@@*') { 'Cyan' }
                 else { 'Gray' }
            Write-Host $l -ForegroundColor $c
        }
    }
    Wait-AnyKey '按任意键 / 点击窗口返回列表...'
}

# 就地修改 $Items 的 Checked，返回 $true=确认 / $false=取消
function Show-ChangePicker {
    param([Parameter(Mandatory)][object[]]$Items, [string]$Branch = '')
    $fmt = {
        param($It)
        $f = Format-ChangeLabel $It
        $color = if ($It.Untracked) { 'Green' } elseif ($It.Deleted) { 'Red' } else { 'White' }
        @{ Code = $f.Code; Name = $f.Name; Info = $f.Info; Color = $color }
    }
    $sum = {
        param($Its)
        $sel = @($Its | Where-Object Checked)
        $add = ($sel | Where-Object { $_.Add -match '^\d+$' } | Measure-Object -Property Add -Sum).Sum
        $del = ($sel | Where-Object { $_.Del -match '^\d+$' } | Measure-Object -Property Del -Sum).Sum
        "已选 $($sel.Count) / $($Its.Count)  •  待提交 +$([int]$add) -$([int]$del)　　未勾选的只是本次不提交，仍留在工作区"
    }
    $detail = { param($It) Show-FileDiff $It }
    $title = '选择本次提交的改动' + $(if ($Branch) { "（分支 $Branch）" })
    $mouse = Enable-ConsoleMouse
    try {
        Show-CheckList -Items $Items -Format $fmt -Summary $sum -OnDetail $detail `
            -Title $title -ConfirmText '提交所选'
    }
    finally { if ($mouse) { Disable-ConsoleMouse } }
}

# ---------- 提交信息候选 ----------
# 仓库沿用 conventional commit + 中文描述（如 feat(settings, android): ...）。
# 这里只能从路径推断 type/scope，描述必须人工确认，因此候选只作为起草。
function Get-PathScope([string]$Path) {
    $p = $Path -replace '\\', '/'
    switch -Regex ($p) {
        '^lib/modules/([^/]+)/' { return $Matches[1] }
        '^lib/private/'         { return 'private' }
        '^lib/widgets/'         { return 'widgets' }
        '^lib/services/'        { return 'service' }
        '^lib/providers/'       { return 'provider' }
        '^lib/core/'            { return 'core' }
        '^lib/data/'            { return 'data' }
        '^lib/utils/'           { return 'utils' }
        '^lib/'                 { return 'app' }
        '^android/'             { return 'android' }
        '^windows/'             { return 'windows' }
        '^scripts/'             { return 'scripts' }
        '^\.github/'            { return 'ci' }
        '^test/'                { return 'test' }
        '^docs/'                { return 'docs' }
        '^packages/([^/]+)/'    { return $Matches[1] }
        '^third_party/'         { return 'third_party' }
        '^kugou_api_server/rust/' { return 'rust' }
        '^kugou_api_server/'    { return 'api' }
        '^assets/'              { return 'assets' }
        '^pubspec\.'            { return 'deps' }
        '\.md$'                 { return 'docs' }
        default                 { return 'misc' }
    }
}

function New-CommitMessageCandidate {
    param([Parameter(Mandatory)][object[]]$Items)
    $scopes = @($Items | ForEach-Object { Get-PathScope $_.Path } | Group-Object |
        Sort-Object Count -Descending | Select-Object -First 3 -ExpandProperty Name)
    $allDocs    = @($Items | Where-Object { (Get-PathScope $_.Path) -ne 'docs' }).Count -eq 0
    $allScripts = @($Items | Where-Object { (Get-PathScope $_.Path) -notin @('scripts', 'ci') }).Count -eq 0
    $allTest    = @($Items | Where-Object { (Get-PathScope $_.Path) -ne 'test' }).Count -eq 0
    $hasNew     = @($Items | Where-Object Untracked).Count -gt 0
    $allDeleted = @($Items | Where-Object { -not $_.Deleted }).Count -eq 0

    $type = if ($allDocs) { 'docs' }
            elseif ($allTest) { 'test' }
            elseif ($allScripts) { 'chore' }
            elseif ($allDeleted) { 'chore' }
            elseif ($hasNew) { 'feat' }
            else { 'fix' }

    $main = ($Items | Sort-Object { if ($_.Add -match '^\d+$') { -[int]$_.Add } else { 0 } } |
        Select-Object -First 1).Path
    $mainName = Split-Path $main -Leaf
    $desc = if ($Items.Count -eq 1) { "更新 $mainName" } else { "更新 $mainName 等 $($Items.Count) 个文件" }
    # scope 与 type 同名时（如 docs(docs)）省掉 scope
    if ($scopes.Count -eq 1 -and $scopes[0] -eq $type) { "$($type): $desc" }
    else { "$type($($scopes -join ', ')): $desc" }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    $a.Trim().ToLowerInvariant() -in @('y', 'yes', '是')
}
# ---------- 主流程 ----------
$exitCode = 0
try {
    Write-Step '收集工作区改动'
    $branch = "$(Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD'))".Trim()
    $items = @(Get-ChangeList)
    if (-not $items.Count) {
        Write-Ok '工作区干净，没有可提交的改动'
        exit 0
    }
    Write-Ok "当前分支：$branch  •  $($items.Count) 个改动"

    if (-not $All) {
        if (-not (Show-ChangePicker -Items $items -Branch $branch)) {
            Clear-Host
            Write-Warn '已取消，未做任何改动'
            exit 130
        }
        Clear-Host
    }
    $sel = @($items | Where-Object Checked)
    if (-not $sel.Count) {
        Write-Warn '未勾选任何文件，取消提交'
        exit 130
    }

    Write-Step "本次提交 $($sel.Count) 个文件"
    foreach ($s in $sel) {
        $f = Format-ChangeLabel $s
        Write-Host ("    {0,-3} {1}  {2}" -f $f.Code, $f.Name, $f.Info) -ForegroundColor Green
    }
    $skipped = @($items | Where-Object { -not $_.Checked })
    if ($skipped.Count) {
        Write-Note "本次跳过 $($skipped.Count) 个改动（仍留在工作区，未写入任何忽略文件）："
        foreach ($s in $skipped) { Write-Note "    $($s.Path)" }
    }

    # ---------- 否认清单闸门 ----------
    if ($SkipGate) {
        Write-Warn '按 -SkipGate 跳过否认清单闸门'
    } else {
        Write-Step '否认清单闸门'
        $gate = Invoke-DenyGate -TreeRoot $Root -SkipPrivateDir
        if ($gate.LibHits.Count -gt 0) {
            Write-Fail "公开面命中私有符号 $($gate.LibHits.Count) 处，中止提交："
            Write-DenyHits -Hits $gate.LibHits
            throw '否认清单命中：请把私有逻辑移入 lib/private/ 后重试（确认无误可加 -SkipGate）'
        }
        Write-Ok "闸门通过（$($gate.DenyCount) 条规则零命中）"
    }
    # ---------- 提交信息 ----------
    if (-not $Message) {
        Write-Step '提交信息'
        $cand = New-CommitMessageCandidate -Items $sel
        Write-Host "  候选：$cand" -ForegroundColor Yellow
        if ($Yes) {
            $Message = $cand
            Write-Ok '按 -Yes 直接采用候选信息'
        } else {
            Write-Note '  （候选只按文件路径推断 type/scope，描述请按实际改动改写）'
            $in = Read-Host '  回车接受候选，或直接输入提交信息'
            $Message = if ([string]::IsNullOrWhiteSpace($in)) { $cand } else { $in.Trim() }
        }
    }

    # ---------- 暂存 + 提交 ----------
    Write-Step '暂存所选改动'
    $preStaged = @($items | Where-Object Staged)
    if ($preStaged.Count) {
        Write-Note "重置暂存区：原有 $($preStaged.Count) 个已暂存文件按本次勾选重新暂存"
    }
    Invoke-Git @('reset', '-q') -Quiet | Out-Null
    $paths = @()
    foreach ($s in $sel) {
        $paths += $s.Path
        if ($s.Orig) { $paths += $s.Orig }   # 重命名：旧路径的删除也要一并暂存
    }
    # 分批 add，避免超长命令行
    for ($i = 0; $i -lt $paths.Count; $i += 50) {
        $chunk = $paths[$i..([Math]::Min($i + 49, $paths.Count - 1))]
        Invoke-Git (@('add', '--') + $chunk) | Out-Null
    }
    $stagedNow = @(Invoke-Git @('diff', '--cached', '--name-only'))
    if (-not $stagedNow.Count) { throw '暂存区为空（所选文件可能被 .gitignore 排除），中止提交' }
    Write-Ok "已暂存 $($stagedNow.Count) 个文件"

    Write-Step '提交'
    Invoke-Git @('commit', '-q', '-m', $Message) | Out-Null
    $sha = "$(Invoke-Git @('rev-parse', '--short', 'HEAD'))".Trim()
    Write-Ok "$sha  $Message"

    # ---------- 推送 ----------
    $pushed = $false
    if ($NoPush) {
        Write-Warn '按 -NoPush 跳过推送'
    } else {
        Write-Step "推送到 origin/$branch"
        [void](Enable-AutoProxy)
        Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -Quiet | Out-Null
        $hasUpstream = ($LASTEXITCODE -eq 0)
        $out = Invoke-WithRetry -What "推送 origin/$branch" -Action {
            if ($hasUpstream) { Invoke-Git @('push', 'origin', "HEAD:$branch") }
            else { Invoke-Git @('push', '-u', 'origin', $branch) }
        }
        foreach ($l in @($out)) { Write-Note "  $l" }
        $pushed = $true
        Write-Ok "已推送 origin/$branch"
    }
    # ---------- 后续动作：upstream PR ----------
    function Get-RemoteUrl([string]$Name) {
        $u = Invoke-Git @('remote', 'get-url', $Name) -Quiet
        if ($LASTEXITCODE -eq 0) { "$u".Trim() } else { $null }
    }

    $doPr = [bool]$Pr -or [bool]$PrMerge
    $doMerge = [bool]$PrMerge
    if (-not $Yes -and -not $doPr -and $pushed -and (Get-RemoteUrl 'upstream')) {
        $doPr = Read-YesNo '  向 upstream 开 PR？'
        if ($doPr) { $doMerge = Read-YesNo '    开完直接合并到 upstream？' $true }
    }
    if ($doPr) {
        Write-Step $(if ($doMerge) { '向 upstream 开 PR 并合并' } else { '向 upstream 开 PR' })
        [void](Enable-AutoProxy)
        $upstreamUrl = Get-RemoteUrl 'upstream'
        if (-not $upstreamUrl) { throw '未配置 upstream 远端，无法开 PR（git remote add upstream <URL>）' }
        if (-not $pushed) { throw '未推送分支，无法开 PR（去掉 -NoPush 后重试）' }
        $originUrl = Get-RemoteUrl 'origin'
        $originSlug = ConvertTo-GitHubSlug $originUrl
        $upstreamSlug = ConvertTo-GitHubSlug $upstreamUrl
        # 跨 fork 的 head 必须带 owner 前缀；同仓库则直接用分支名
        $head = if ($originSlug -and $upstreamSlug -and $originSlug -ne $upstreamSlug) {
            "$(($originSlug -split '/')[0]):$branch"
        } else { $branch }
        $base = if ($PrBase) { $PrBase } else { $branch }
        $prBody = "由 scripts/md3.ps1 commit 创建。`n`n- 提交：$sha`n- 分支：$head"

        if (-not $doMerge) {
            New-GitHubPr -RemoteUrl $upstreamUrl -Base $base -Head $head -Title $Message -Body $prBody -RepoDir $Root
        }
        else {
            if (-not $upstreamSlug) { throw "无法从 upstream 地址解析 owner/repo：$upstreamUrl" }
            # -Yes 或非控制台环境下不能交互要 token（Read-Host 会直接阻塞）
            $noPrompt = $Yes -or -not (Test-InteractiveConsole)
            $token = Get-GitHubToken -NoPrompt:$noPrompt
            if (-not $token) { throw '没有可用的 GitHub token，无法自动合并（md3.ps1 token -Set 设置，或改用 -Pr 只开 PR）' }
            $r = Invoke-WithRetry -What '开 PR 并合并' -Action {
                Invoke-GitHubPrMerge -RepoSlug $upstreamSlug -Base $base -Head $head -Token $token `
                    -Title $Message -Body $prBody -MergeMethod 'merge'
            }
            if ($r.Merged) {
                Write-Ok "PR #$($r.Number) 已合并到 $upstreamSlug/$base（合并提交 $($r.Message.Substring(0, [Math]::Min(8, $r.Message.Length)))）"
                if ($r.Url) { Write-Note "  $($r.Url)" }
                # 合并结果只在 upstream 上，不拉回来本地就会立刻落后一个提交
                if ($NoSyncBack) {
                    Write-Warn '按 -NoSyncBack 跳过拉回；本地当前落后 upstream 一个合并提交'
                } else {
                    Write-Step "拉回 upstream/$base 并同步 origin"
                    Invoke-WithRetry -What "拉取 upstream/$base" -Action { Invoke-Git @('fetch', 'upstream', $base) | Out-Null }
                    $mergeOut = Invoke-Git @('merge', '--no-edit', 'FETCH_HEAD') -Quiet
                    if ($LASTEXITCODE -ne 0) {
                        Write-Fail "拉回时发生冲突，请手动解决后再推 origin："
                        foreach ($l in @($mergeOut)) { Write-Note "  $l" }
                    } else {
                        foreach ($l in @($mergeOut)) { Write-Note "  $l" }
                        Invoke-WithRetry -What '同步 origin' -Action { Invoke-Git @('push', 'origin', "HEAD:$branch") | Out-Null }
                        Write-Ok "已同步：本地 = upstream/$base = origin/$branch"
                    }
                }
            } else {
                Write-Fail "未合并：$($r.Message)"
                if ($r.Url) { Write-Note "  PR 地址：$($r.Url)" }
                $exitCode = 1   # 提交推送成功但合并没成，退出码要能反映出来
            }
        }
    }

    # ---------- 后续动作：公开版导出 ----------
    $doPublicPr = [bool]$PublicPr
    $doPublicPush = [bool]$PublicExport
    if (-not $Yes -and -not $doPublicPr -and -not $doPublicPush) {
        if (Read-YesNo '  导出公开版本并发布到公开仓库？') {
            $doPublicPr = Read-YesNo '    走 PR 审阅（否则 force push 直接覆盖 main）？' $true
            $doPublicPush = -not $doPublicPr
        }
    }
    if ($doPublicPr -or $doPublicPush) {
        Write-Step '导出公开版本'
        $pubUrl = $PublicRemote
        if (-not $pubUrl) { $pubUrl = Get-RemoteUrl 'public' }
        if (-not $pubUrl) { $pubUrl = 'https://github.com/zzyoxml/md3Music.git' }
        Write-Note "公开仓库：$pubUrl"
        $exportArgs = @('-PublicRemote', $pubUrl, '-NoPause')
        if ($doPublicPr) { $exportArgs += '-AsPr' }
        & (Join-Path $PSScriptRoot 'export_public.ps1') @exportArgs
        if ($LASTEXITCODE -ne 0) { throw "公开版导出失败（退出码 $LASTEXITCODE）" }
    }

    Write-Step '完成'
    Write-Ok "提交 $sha 已$(if ($pushed) { "推送到 origin/$branch" } else { '本地提交（未推送）' })"
    if ($skipped.Count) { Write-Note "$($skipped.Count) 个改动仍留在工作区，未提交" }
}
catch {
    Write-Host "`n[ERROR] 提交流程失败：$($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    try { [Console]::OutputEncoding = $script:PrevOutEnc } catch { }
}
exit $exitCode
