#Requires -Version 5.1
<#
.SYNOPSIS
  一键提交：TUI 勾选改动 -> 否认清单闸门 -> 提交 -> 同步 upstream/origin -> 推送 -> 可选开 PR。

.DESCRIPTION
  面向本仓库「私有开发 + 公开导出」双仓库流程的提交入口，替代大部分 GitHub Desktop 操作：

    1. 列出工作区所有改动（含未跟踪文件），方向键 + 空格勾选本次要提交的文件
    2. 提交前跑否认清单闸门（scripts/public_deny.txt），命中私有符号即中止
    3. 默认由 LLM 读 diff 一次起草提交标题、正文与 PR 描述，随后在终端内嵌编辑器里
       直接改（Ctrl+S 保存 / Esc 放弃 / Ctrl+E 转外部编辑器）；-NoLlm 退回模板候选
    4. 同步当前分支：先合并 upstream/<分支> 的新提交，再合并 origin/<分支>，最后推送 origin
       （首次推送自动 -u 建立跟踪；upstream 的提交因此经本地带到 origin，fork 不会越落越远）
    5. 可选：向 upstream 开 PR / 导出公开版本（覆盖推送或开 PR）

  未勾选的文件只是本次不提交，仍留在工作区，不写入任何忽略文件。
  注意：确认后脚本会按勾选结果重置暂存区（git reset + git add 勾选项），
  因此事先用 GitHub Desktop 做的部分行暂存会被本次选择覆盖。

.PARAMETER Message
  提交信息。不传则进入候选信息确认/编辑环节。

.PARAMETER NoLlm
  不调 LLM，直接用按文件路径推断的模板候选信息（离线 / 不想耗额度时用）。
  默认行为是让 LLM 读 diff 起草标题、提交正文与 PR 描述；配置见 scripts/lib/llm.ps1，
  可用 MD3_LLM_API_KEY / MD3_LLM_BASE_URL / MD3_LLM_MODEL 覆盖内置默认值。
  送去的 diff 用 -U0 生成（不含未变的上下文行），省 token。
  接口按次计费，故每次提交只调一次、不重试，失败即回退模板候选，不影响提交；
  结果按 diff 指纹缓存在 .git/md3-llm-commit.json，改动没变时重跑脚本直接复用，不再计费。

.PARAMETER All
  跳过勾选界面，直接提交全部改动。

.PARAMETER NoPush
  只提交，不做任何同步（既不拉 upstream/origin 也不推送）。

.PARAMETER NoUpstreamSync
  同步阶段跳过 upstream：只与 origin 对齐后推送。

.PARAMETER UpstreamBranch
  同步阶段从 upstream 拉取的分支（默认与当前分支同名）。

.PARAMETER Pr
  推送后向 upstream 仓库开 PR（fork -> upstream 流程），不自动合并。

.PARAMETER PrMerge
  推送后向 upstream 开 PR **并直接合并**（merge commit 策略），合并后默认把结果拉回本地并同步 origin。
  优先用 gh CLI（gh 登录即可，无需 PAT）；gh 不可用或失败时回退 GitHub REST API，
  此时需要对 upstream 有写权限的 PAT（用 md3.ps1 token 管理）。

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
  .\scripts\md3.ps1 commit -NoLlm
  .\scripts\md3.ps1 commit -All -Message "fix(player): 修复切歌闪烁"
  .\scripts\md3.ps1 commit -Pr
  .\scripts\md3.ps1 commit -PublicPr
#>
[CmdletBinding()]
param(
    [string]$Message = '',
    [switch]$NoLlm,
    [switch]$All,
    [switch]$NoPush,
    [switch]$NoUpstreamSync,
    [string]$UpstreamBranch = '',
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
# 默认由 LLM 读 diff 起草；这里的模板候选是 -NoLlm 或调用失败时的兜底，
# 只能从路径推断 type/scope，描述仍需人工确认。
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

# ---------- LLM 提交信息 ----------
# 给模型的上下文：文件清单 + 增删行数 + 只含变更行的 diff。
# 省 token：diff 用 -U0 生成，未变的上下文行一行不发（同一批改动常能省掉一半以上），
# @@ 头与 +/- 变更行仍在，够看出改了什么；system 提示里也交代了上下文已删。
# 接口按次计费、只调一次：整体上限 $MaxChars（20 万字符，常规提交装得下），
# 超出后按文件依次截断 / 丢弃 diff，保证文件清单永远完整（清单本身就够写出一条合格标题）。
function Get-CommitDiffContext {
    param([Parameter(Mandatory)][object[]]$Items, [int]$MaxChars = 200000, [int]$PerFileChars = 40000)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("文件清单（共 $($Items.Count) 个）：")
    foreach ($it in $Items) {
        $state = if ($it.Untracked) { '新增' } elseif ($it.Deleted) { '删除' } elseif ($it.Orig) { "重命名（原 $($it.Orig)）" } else { '修改' }
        $stat = if ($it.Add -ne '' -or $it.Del -ne '') { "  +$($it.Add) -$($it.Del)" } else { '' }
        [void]$sb.AppendLine("- $($it.Path)  [$state]$stat")
    }
    [void]$sb.AppendLine()
    $budget = $MaxChars - $sb.Length
    foreach ($it in $Items) {
        if ($budget -le 200) { [void]$sb.AppendLine('（diff 过长，其余文件内容已省略）'); break }
        if ($it.Deleted) { continue }
        $text = ''
        if ($it.Untracked) {
            $full = Join-Path $Root $it.Path
            $head = @(Get-Content -LiteralPath $full -TotalCount 3000 -ErrorAction SilentlyContinue)
            if ($head.Count) { $text = "新文件 $($it.Path) 内容（前 $($head.Count) 行）：`n" + ($head -join "`n") }
        } else {
            # -U0：不带上下文行，只出 @@ 头与 +/- 变更行
            $d = @(Invoke-Git @('--no-pager', 'diff', '-U0', 'HEAD', '--', $it.Path) -Quiet)
            if ($d.Count) { $text = ($d -join "`n") }
        }
        if (-not $text) { continue }
        $cap = [Math]::Min($PerFileChars, $budget - 100)
        if ($text.Length -gt $cap) { $text = $text.Substring(0, $cap) + "`n…（此文件 diff 已截断）" }
        [void]$sb.AppendLine($text)
        [void]$sb.AppendLine()
        $budget = $MaxChars - $sb.Length
    }
    $sb.ToString()
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    $a.Trim().ToLowerInvariant() -in @('y', 'yes', '是')
}

# ---------- 候选信息的展示与编辑 ----------
# 起草结果按次计费，所以三段（标题 / 正文 / PR 描述）一次拿回后完整展示，不做省略；
# 改写走终端内嵌编辑器（lib/ui.ps1 的 Show-TextEditor），三段拼成一份带分节标记的草稿，
# 可直接在里面移动光标增删，保存即生效——不再是一段段重敲。
function Show-DraftSegment {
    param([Parameter(Mandatory)][string]$Label, [AllowEmptyString()][string]$Text, [string]$Color = 'DarkYellow')
    if (-not $Text) {
        Write-Host "  $Label：（空）" -ForegroundColor DarkGray
        return
    }
    $lines = @("$Text" -split "`r?`n")
    if ($lines.Count -eq 1) {
        Write-Host "  $Label：$($lines[0])" -ForegroundColor $Color
        return
    }
    Write-Host "  $Label（$($lines.Count) 行）：" -ForegroundColor $Color
    foreach ($l in $lines) { Write-Host "    $l" -ForegroundColor $Color }
}

# 草稿分节标记。节内内容原样采用（PR 描述里的 ## 小标题不能被当注释吃掉），
# 只有首个分节标记之前的说明行不进结果。
$script:DraftHeads = [ordered]@{
    Title  = '=== 标题 ==='
    Body   = '=== 正文 ==='
    PrBody = '=== PR 描述 ==='
}

function ConvertTo-DraftText {
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$Body = '',
        [AllowEmptyString()][string]$PrBody = ''
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# 直接改下面各节内容：Ctrl+S / F2 保存并继续，Esc 放弃改动，Ctrl+E 转外部编辑器')
    [void]$sb.AppendLine('# 这几行说明（首个 === 之前的部分）不会进入结果；各节内容原样采用')
    [void]$sb.AppendLine('# 某节删空即表示不用该节；标题只取第一行')
    $vals = @{ Title = $Title; Body = $Body; PrBody = $PrBody }
    foreach ($k in $script:DraftHeads.Keys) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine($script:DraftHeads[$k])
        if ($vals[$k]) { [void]$sb.AppendLine("$($vals[$k])") }
    }
    $sb.ToString().TrimEnd()
}

function ConvertFrom-DraftText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $buckets = @{ Title = @(); Body = @(); PrBody = @() }
    $cur = $null
    foreach ($line in @("$Text" -split "`r?`n")) {
        $head = $null
        foreach ($k in $script:DraftHeads.Keys) {
            if ("$line".Trim() -eq $script:DraftHeads[$k]) { $head = $k; break }
        }
        if ($head) { $cur = $head; continue }
        if (-not $cur) { continue }        # 首个分节标记之前：说明行，丢掉
        $buckets[$cur] += "$line"
    }
    $get = {
        param($k)
        (($buckets[$k] -join "`n")).Trim()
    }
    [pscustomobject]@{
        Title  = "$(@((& $get 'Title') -split "`r?`n")[0])".Trim()
        Body   = (& $get 'Body')
        PrBody = (& $get 'PrBody')
    }
}

<#
  兜底的逐段确认（非交互控制台下用，内嵌编辑器需要真实控制台）：
  回车保留当前内容；输入新内容即替换；输入单个 - 清空该段。
  多行段（正文 / PR 描述）连续输入多行，空行结束。
#>
function Read-DraftSegment {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Current = '',
        [switch]$MultiLine
    )
    if (-not $MultiLine) {
        $in = Read-Host "  $Label：回车保留，或输入新内容（- 清空）"
        if ([string]::IsNullOrWhiteSpace($in)) { return $Current }
        if ($in.Trim() -eq '-') { return '' }
        return $in.Trim()
    }
    Write-Note "  $Label：回车保留；或逐行输入新内容，空行结束（首行输入 - 清空）"
    $first = Read-Host '    >'
    if ([string]::IsNullOrWhiteSpace($first)) { return $Current }
    if ($first.Trim() -eq '-') { return '' }
    $lines = @($first)
    while ($true) {
        $l = Read-Host '    >'
        if ([string]::IsNullOrWhiteSpace($l)) { break }
        $lines += $l
    }
    ($lines -join "`n").Trim()
}

# ---------- 主流程 ----------
$exitCode = 0
try {
    # 设置搜索索引：收集改动前静默同步，避免提交里带着过期索引（有变化才提示）
    Sync-SettingsSearchIndex
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
    $MessageBody = ''
    $LlmPrBody = ''
    if (-not $Message) {
        Write-Step '提交信息'
        $cand = New-CommitMessageCandidate -Items $sel
        $candBody = ''
        $from = '模板推断'
        if ($NoLlm) {
            Write-Note '  按 -NoLlm 跳过 LLM，使用模板候选'
        } else {
            . (Join-Path $PSScriptRoot '..\lib\llm.ps1')
            $cfg = Get-LlmConfig
            try {
                [void](Enable-AutoProxy)
                $hints = @($sel | ForEach-Object { Get-PathScope $_.Path } | Select-Object -Unique)
                $ctx = Get-CommitDiffContext -Items $sel
                # 按次计费：先查缓存（键 = 上下文 + 模型的指纹），diff 没变就直接复用上次结果
                $gitDir = "$(Invoke-Git @('rev-parse', '--absolute-git-dir'))".Trim()
                $cachePath = if ($gitDir) { Join-Path $gitDir 'md3-llm-commit.json' } else { '' }
                $cacheKey = Get-LlmCommitCacheKey -DiffText $ctx -Model $cfg.Model
                $r = if ($cachePath) { Get-CachedLlmCommitMessage -Path $cachePath -Key $cacheKey } else { $null }
                if ($r) {
                    Write-Ok "复用缓存的起草结果（$($r.At)，改动未变，未再调用 LLM）"
                } else {
                    Write-Note "  调用 LLM 起草提交信息（$($cfg.Model) @ $($cfg.BaseUrl)，key 来源：$($cfg.Source)）…"
                    Write-Note "  上下文 $([int]($ctx.Length / 1000)) K 字符 / $($sel.Count) 个文件"
                    # 按次计费：只发这一次，失败即回退模板，不重试
                    $r = New-LlmCommitMessage -DiffText $ctx -ScopeHints $hints
                    if ($cachePath) {
                        try { Set-CachedLlmCommitMessage -Path $cachePath -Key $cacheKey -Result $r }
                        catch { Write-Warn "起草结果写入缓存失败（不影响本次提交）：$($_.Exception.Message)" }
                    }
                }
                $cand = $r.Title
                $candBody = $r.Body
                $LlmPrBody = $r.PrBody          # 同一次调用顺手拿回的 PR 描述，开 PR 时直接用
                $from = 'LLM 按 diff 生成'
            }
            catch {
                Write-Warn "LLM 起草失败，回退到模板候选：$($_.Exception.Message)"
            }
        }
        if ($Yes) {
            $Message = $cand
            $MessageBody = $candBody
            Write-Host "  候选来源：$from" -ForegroundColor Yellow
            Write-Ok '按 -Yes 直接采用候选信息'
        }
        elseif (Test-InteractiveConsole) {
            # 直接进编辑器：三段拼成一份草稿，就地改写
            $draft = ConvertTo-DraftText -Title $cand -Body $candBody -PrBody $LlmPrBody
            $edited = Show-TextEditor -Text $draft -Title "提交信息草稿（$from）　保存后用于提交与 PR" -Extension '.md'
            if ($null -eq $edited) {
                Write-Warn '已放弃编辑，采用原候选'
                $Message = $cand
                $MessageBody = $candBody
            } else {
                $p = ConvertFrom-DraftText $edited
                $Message = if ($p.Title) { $p.Title } else { $cand }
                if (-not $p.Title) { Write-Warn '草稿里标题一节是空的，仍用原候选标题' }
                $MessageBody = $p.Body
                $LlmPrBody = $p.PrBody
            }
            Write-Host "  候选来源：$from" -ForegroundColor Yellow
        }
        else {
            # 非控制台（管道 / 被其他脚本调用）：内嵌编辑器用不了，退回逐段确认
            Write-Host "  候选来源：$from" -ForegroundColor Yellow
            Show-DraftSegment -Label '标题' -Text $cand -Color 'Yellow'
            Show-DraftSegment -Label '正文' -Text $candBody
            Show-DraftSegment -Label 'PR 描述' -Text $LlmPrBody
            Write-Note '  当前终端不支持内嵌编辑器，改为逐段确认：回车保留该段，输入内容即替换'
            $Message = Read-DraftSegment -Label '标题' -Current $cand
            if (-not $Message) { $Message = $cand }
            $MessageBody = Read-DraftSegment -Label '正文' -Current $candBody -MultiLine
            $LlmPrBody = Read-DraftSegment -Label 'PR 描述' -Current $LlmPrBody -MultiLine
        }
        # 最终采用的内容完整回显一遍，留在终端记录里
        Show-DraftSegment -Label '标题' -Text $Message -Color 'Yellow'
        Show-DraftSegment -Label '正文' -Text $MessageBody
        Show-DraftSegment -Label 'PR 描述' -Text $LlmPrBody
        if ($from -eq 'LLM 按 diff 生成') { Write-Note '  （由模型阅读 diff 生成，仍请自行确认措辞是否准确）' }
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
    $commitArgs = @('commit', '-q', '-m', $Message)
    if ($MessageBody) { $commitArgs += @('-m', $MessageBody) }
    Invoke-Git $commitArgs | Out-Null
    $sha = "$(Invoke-Git @('rev-parse', '--short', 'HEAD'))".Trim()
    Write-Ok "$sha  $Message"

    # ---------- 同步 + 推送 ----------
    function Get-RemoteUrl([string]$Name) {
        $u = Invoke-Git @('remote', 'get-url', $Name) -Quiet
        if ($LASTEXITCODE -eq 0) { "$u".Trim() } else { $null }
    }

    # 把 <远端>/<分支> 的新提交并进本地。
    # 返回 'ok' / 'missing'（远端无此分支）/ 'conflict'；网络类失败重试后抛出。
    function Sync-FromRemote {
        param([Parameter(Mandatory)][string]$Remote, [Parameter(Mandatory)][string]$RemoteBranch)
        $status = Invoke-WithRetry -What "拉取 $Remote/$RemoteBranch" -Action {
            $out = Invoke-Git @('fetch', $Remote, $RemoteBranch) -Quiet
            if ($LASTEXITCODE -eq 0) { return 'ok' }
            # 远端没这个分支是确定性结果，重试没意义；其余（网络/认证）交给重试
            if ("$out" -match "find remote ref") { return 'missing' }
            throw "git fetch $Remote $RemoteBranch 失败：$(@($out) -join ' ')"
        }
        if ($status -eq 'missing') {
            Write-Warn "$Remote 上没有分支 $RemoteBranch，跳过与它的同步"
            return 'missing'
        }
        $behind = [int]("$(Invoke-Git @('rev-list', '--count', 'HEAD..FETCH_HEAD'))".Trim())
        if ($behind -le 0) {
            Write-Ok "本地已包含 $Remote/$RemoteBranch 的全部提交"
            return 'ok'
        }
        Write-Note "$Remote/$RemoteBranch 领先 $behind 个提交，先合并进本地"
        $mergeOut = Invoke-Git @('merge', '--no-edit', 'FETCH_HEAD') -Quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "与 $Remote/$RemoteBranch 合并时发生冲突：本次提交已在本地，解决冲突后重跑推送"
            foreach ($l in @($mergeOut)) { Write-Note "  $l" }
            return 'conflict'
        }
        foreach ($l in @($mergeOut)) { Write-Note "  $l" }
        Write-Ok "已并入 $Remote/$RemoteBranch 的 $behind 个提交"
        'ok'
    }

    $pushed = $false
    if ($NoPush) {
        Write-Warn '按 -NoPush 跳过同步与推送'
    } else {
        Write-Step "同步分支 $branch（upstream → 本地 → origin）"
        [void](Enable-AutoProxy)
        Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -Quiet | Out-Null
        $hasTracking = ($LASTEXITCODE -eq 0)

        # 1. 先跟 upstream 对齐：上游的新提交要经由本地带到 origin，否则 fork 会越落越远。
        #    上游不可达时只警告——它不该拦住本次改动进自己的 fork。
        $upSynced = $false
        if ($NoUpstreamSync) {
            Write-Warn '按 -NoUpstreamSync 跳过与 upstream 的同步'
        } elseif (-not (Get-RemoteUrl 'upstream')) {
            Write-Note '未配置 upstream 远端，跳过上游同步'
        } else {
            $upBranch = if ($UpstreamBranch) { $UpstreamBranch } else { $branch }
            $r = 'skip'
            try { $r = Sync-FromRemote -Remote 'upstream' -RemoteBranch $upBranch }
            catch { Write-Warn "拉取 upstream/$upBranch 失败：$($_.Exception.Message)" }
            if ($r -eq 'conflict') { throw "与 upstream/$upBranch 合并冲突，未推送" }
            if ($r -eq 'skip') { Write-Warn '跳过上游同步，继续同步并推送 origin' }
            $upSynced = ($r -eq 'ok')
        }

        # 2. 再跟 origin 对齐：远端分支领先时（另一台机器 / 网页端改动）直接 push 会被
        #    non-fast-forward 拒绝，重试也过不去，历史上只能手动 git pull 补一个合并提交。
        if ((Sync-FromRemote -Remote 'origin' -RemoteBranch $branch) -eq 'conflict') {
            throw "与 origin/$branch 合并冲突，未推送"
        }

        # 3. 推送：本地此时已包含 upstream + origin 的全部提交
        $out = Invoke-WithRetry -What "推送 origin/$branch" -Action {
            if ($hasTracking) { Invoke-Git @('push', 'origin', "HEAD:$branch") }
            else { Invoke-Git @('push', '-u', 'origin', $branch) }
        }
        foreach ($l in @($out)) { Write-Note "  $l" }
        $pushed = $true
        Write-Ok "已同步 origin/$branch$(if ($upSynced) { '（已与 upstream 对齐）' })"
    }
    # ---------- 后续动作：upstream PR ----------
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
        # PR 描述：优先用起草提交信息那一次调用顺手拿回的正文（已经付过费，不再多调一次）
        $prBody = if ($LlmPrBody) { $LlmPrBody } elseif ($MessageBody) { $MessageBody } else { '' }
        if ($prBody) { $prBody += "`n`n---`n" }
        $prBody += "由 scripts/md3.ps1 commit 创建。`n`n- 提交：$sha`n- 分支：$head"

        if (-not $doMerge) {
            New-GitHubPr -RemoteUrl $upstreamUrl -Base $base -Head $head -Title $Message -Body $prBody -RepoDir $Root
        }
        else {
            if (-not $upstreamSlug) { throw "无法从 upstream 地址解析 owner/repo：$upstreamUrl" }
            # 优先用 gh CLI（gh 已登录即可，无需 PAT）；gh 不可用 / 尝试失败时回退原 REST 实现
            $r = $null
            if (Test-HasCommand gh) {
                try {
                    $r = Invoke-WithRetry -What 'gh 开 PR 并合并' -Action {
                        Invoke-GhPrMerge -RemoteUrl $upstreamUrl -Base $base -Head $head -Title $Message -Body $prBody -RepoDir $Root
                    }
                } catch {
                    Write-Warn "gh 开 PR 并合并异常：$($_.Exception.Message)"
                    $r = [pscustomobject]@{ Number = 0; Url = ''; Merged = $false; Message = 'gh 流程异常' }
                }
            } else {
                Write-Note 'gh 未安装，直接走 REST 实现'
            }
            if ($null -eq $r -or -not $r.Merged) {
                if ($null -ne $r) { Write-Warn "gh 开 PR 并合并未成功（$($r.Message)），回退 REST 实现" }
                else { Write-Note '已回退 REST 实现（需要 GitHub token）' }
                # -Yes 或非控制台环境下不能交互要 token（Read-Host 会直接阻塞）
                $noPrompt = $Yes -or -not (Test-InteractiveConsole)
                $token = Get-GitHubToken -NoPrompt:$noPrompt
                if (-not $token) { throw '没有可用的 GitHub token，无法自动合并（md3.ps1 token -Set 设置，或改用 -Pr 只开 PR）' }
                $r = Invoke-WithRetry -What '开 PR 并合并' -Action {
                    Invoke-GitHubPrMerge -RepoSlug $upstreamSlug -Base $base -Head $head -Token $token `
                        -Title $Message -Body $prBody -MergeMethod 'merge'
                }
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
