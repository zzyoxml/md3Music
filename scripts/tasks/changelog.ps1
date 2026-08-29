#Requires -Version 5.1
<#
.SYNOPSIS
  总结提交记录并更新 CHANGELOG.md（私有侧维护工具，不随公开版导出）。

.DESCRIPTION
  总结「指定起始提交哈希之后」的提交记录，用 LLM 生成发布日志条目（失败回退机械分组），
  以用户指定的新版本号写入私有仓库根 CHANGELOG.md，并把本次最新提交哈希 + 版本号记录到
  scripts/changelog_state.json，下次运行时未指定起始哈希会自动从上次记录续订。

  LLM 总结生成后会先预览，必须经用户确认才写入：
    [Y] 写入  / [R] 重新总结（重新调用 LLM，采样出新结果） / [N] 放弃更新（不改任何文件）
  循环直到用户满意。-Yes 可跳过确认循环（自动化 / 非交互环境用）。

  提示顺序：先填版本号，再填起始哈希（仅在无状态记录时询问）。

.PARAMETER Version
  新版本号，如 v5.4.0（接受 5.4.0 / V5.4.0，自动规范化为 v5.4.0）。
  不填且交互环境时首条提示输入。

.PARAMETER SinceHash
  起始提交哈希，总结「该提交之后」的记录。不填时依次尝试：状态文件记录的哈希 →
  交互提示（第二条提示）→ 报错。留空交互提示表示从仓库最初开始（仅取最近 60 条）。

.PARAMETER Yes
  跳过确认循环，自动确认首次生成结果并写入（非交互自动化用）。

.PARAMETER NoPause
  结束时不等待按键（CI / 被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 changelog -Version v5.4.0
  .\scripts\md3.ps1 changelog -Version v5.4.0 -Yes -NoPause
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$SinceHash = '',
    [switch]$Yes,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Root = Get-RepoRoot
$ScriptsDir = Split-Path -Parent $PSScriptRoot          # scripts/
$StateFile  = Join-Path $ScriptsDir 'changelog_state.json'
$ChangelogFile = Join-Path $Root 'CHANGELOG.md'
$exitCode = 0

try {
    # ---------- 1. 版本号（先填版本号） ----------
    Assert-Command git 'changelog 需要 git 在 PATH 中'
    $Version = "$Version".Trim()
    if (-not $Version) {
        if (Test-InteractiveConsole) {
            Write-Step '更新 CHANGELOG'
            $Version = (Read-Host '请输入新版本号（如 v5.4.0）').Trim()
        } else {
            throw '未指定版本号：非交互环境请用 -Version 传入（如 .\scripts\md3.ps1 changelog -Version v5.4.0）'
        }
    }
    # 规范化：5.4.0 -> v5.4.0；V5.4.0 -> v5.4.0
    if ($Version -match '^[0-9]') { $Version = "v$Version" }
    elseif ($Version -match '^[vV]') { $Version = "v" + $Version.Substring(1) }
    Write-Ok "新版本号：$Version"

    # ---------- 2. 起始哈希（再填哈希） ----------
    $since = "$SinceHash".Trim()
    $stateHash = $null
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $stateHash = "$($state.hash)".Trim()
        } catch { Write-Warn "状态文件解析失败（忽略）：$StateFile" }
    }
    if (-not $since -and $stateHash) {
        $since = $stateHash
        Write-Note "自动使用上次记录的起始哈希（$($since.Substring(0, [Math]::Min(12, $since.Length)))…）"
    }
    if (-not $since) {
        if (Test-InteractiveConsole) {
            Write-Note '未找到上次记录的起始哈希，也没有 -SinceHash 参数。'
            $in = (Read-Host '请输入起始提交哈希（该提交之后的记录将被总结；留空=从最初开始）').Trim()
            $since = $in
        } else {
            throw '未指定起始哈希且无状态记录：请用 -SinceHash 传入，或先交互运行一次生成状态'
        }
    }

    # ---------- 3. 取提交 ----------
    Write-Step '收集提交记录'
    # PowerShell 5.1 默认按控制台代码页(GBK)解码外部命令输出，而 git 输出是 UTF-8，
    # 不切会让中文提交标题全部乱码，连带机械分组/预览/写入全乱。故先切 UTF-8 解码。
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $logArgs = @('--no-merges', '--pretty=format:%h %s')
    if ($since) { $logArgs += @("$since..HEAD") } else { $logArgs += @('-n', '60') }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $commits = @(& git -C $Root log $logArgs 2>&1) ; $logCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    if ($logCode -ne 0) {
        throw "git log 失败（起始哈希可能无效）：$($commits -join ' ')"
    }
    if (-not $commits.Count) {
        Write-Warn '起始哈希之后没有新提交，跳过更新（CHANGELOG 与状态文件均未改动）'
        exit 0
    }
    Write-Ok "共 $($commits.Count) 条提交（$($commits[0]) … $($commits[-1])）"

    # ---------- 4. 机械分组（LLM 的兜底） ----------
    # 按 Conventional Commits 类型归组，摘录类型前缀之后的主体，产出一行一条的发布日志列表
    function New-MechanicalBullets([string[]]$CommitLines) {
        $groups = [ordered]@{
            '功能' = @(); '修复' = @(); '性能' = @(); '改进' = @()
            '文档' = @(); '重构' = @(); '测试' = @(); 'CI/构建' = @(); '其他' = @()
        }
        foreach ($ln in $CommitLines) {
            $subject = ($ln -replace '^[0-9a-f]{7,}\s+', '').Trim()
            $type = ''
            if ($subject -match '^(feat|feature)(\([^)]*\))?:\s*(.+)$') { $type = '功能'; $subject = $Matches[3] }
            elseif ($subject -match '^fix(\([^)]*\))?:\s*(.+)$')        { $type = '修复'; $subject = $Matches[2] }
            elseif ($subject -match '^perf(\([^)]*\))?:\s*(.+)$')       { $type = '性能'; $subject = $Matches[2] }
            elseif ($subject -match '^(improve|style)(\([^)]*\))?:\s*(.+)$') { $type = '改进'; $subject = $Matches[3] }
            elseif ($subject -match '^docs(\([^)]*\))?:\s*(.+)$')       { $type = '文档'; $subject = $Matches[2] }
            elseif ($subject -match '^refactor(\([^)]*\))?:\s*(.+)$')   { $type = '重构'; $subject = $Matches[2] }
            elseif ($subject -match '^test(\([^)]*\))?:\s*(.+)$')       { $type = '测试'; $subject = $Matches[2] }
            elseif ($subject -match '^(ci|chore|build|revert)(\([^)]*\))?:\s*(.+)$') { $type = 'CI/构建'; $subject = $Matches[3] }
            else { $type = '其他' }
            $groups[$type] += "- $((($subject -replace '[\r\n]+', ' ')).Trim())"
        }
        $out = @()
        foreach ($k in $groups.Keys) {
            if ($groups[$k].Count) {
                $out += ''
                $out += "**$k**"
                $out += $groups[$k]
            }
        }
        ($out -join "`n").Trim()
    }

    # ---------- 5. 生成 + 用户确认循环（写入前置，直到满意） ----------
    $bullets = $null
    $source = ''
    while ($true) {
        $tryLlm = $true
        try {
            . (Join-Path $PSScriptRoot '..\lib\llm.ps1')
            [void](Enable-AutoProxy)
            $cfg = Get-LlmConfig
            Write-Note "  调用 LLM 总结（$($cfg.Model)，$($commits.Count) 条提交）…"
            $sample = (New-MechanicalBullets -CommitLines $commits) -split "`r?`n" |
                Where-Object { $_ -match '^\- ' } | Select-Object -First 1
            $usr = "以下是 git 提交清单（共 $($commits.Count) 条，格式：短哈希 标题）：`n`n" +
                ($commits -join "`n") +
                "`n`n请按主题聚类，用中文总结为发布日志条目。要求每行一条、以 '- ' 开头、" +
                '中文短句、本轮发布里做了什么都讲清楚、总计不超过 30 行、只输出列表本身不要标题和解释。' +
                "`n风格参考一条：$sample"
            $resp = Invoke-LlmChat -TimeoutSec 90 -Temperature 0.5 -Messages @(
                @{ role = 'system'; content = @'
你是资深发布经理，把 git 提交记录总结成用户可读的中文更新日志。
规则：按功能/修复/性能/其他等主题聚类；每条以 "- " 开头、一行中文短句、写清做了什么；
只输出 markdown 列表，不要 "#"/"##" 标题、不要代码块围栏、不要额外解释；不超过 30 行。
'@ },
                @{ role = 'user'; content = $usr }
            )
            if ($resp.Status -eq 200 -and $resp.Content) {
                $text = "$($resp.Content)" -replace '(?s)^```(?:markdown|md|text)?\s*', '' -replace '\s*```$', ''
                $lines = @($text -split "`r?`n" | ForEach-Object { $_.TrimEnd() } |
                    Where-Object { $_.Trim() -ne '' })
                if ($lines.Count) { $bullets = ($lines -join "`n").Trim(); $source = 'LLM' }
            }
        } catch { Write-Warn "LLM 总结失败：$($_.Exception.Message)" }
        if (-not $bullets) {
            $bullets = New-MechanicalBullets -CommitLines $commits
            $source = '机械分组'
            Write-Warn "已回退到机械分组（来源：$source）"
        }

        # 预览
        Write-Host ''
        Write-Host "  ── 待写入的 $Version 条目（来源：$source，共 $($commits.Count) 条提交）──" -ForegroundColor Cyan
        $bullets -split "`r?`n" | ForEach-Object { Write-Host "  $_" }
        Write-Host '  ──────────────────────────────────────────────' -ForegroundColor Cyan

        # 确认
        if ($Yes) {
            Write-Ok '-Yes：自动确认写入'
            break
        }
        if (-not (Test-InteractiveConsole)) {
            throw '需要在交互环境确认生成结果，或加 -Yes 自动确认'
        }
        $a = (Read-Host '  [Y]写入  [R]重新总结  [N]放弃更新').Trim().ToLowerInvariant()
        if ($a -in @('y', 'yes', '是')) { break }
        if ($a -in @('r', '重新', '重试')) {
            Write-Note '重新总结…'
            $bullets = $null
            continue
        }
        Write-Warn '已放弃更新 CHANGELOG（CHANGELOG 与状态文件均未改动）'
        exit 0
    }

    # ---------- 6. 写入 CHANGELOG.md ----------
    Write-Step "写入 CHANGELOG.md（$Version）"
    $block = "## $Version`n`n$bullets`n`n---`n`n"
    if (Test-Path $ChangelogFile) {
        $content = [System.IO.File]::ReadAllText($ChangelogFile, (Get-Utf8NoBom))
        $headRe = '^(# 更新日志[^\r\n]*\r?\n+\s*-{3,}[^\r\n]*\r?\n+\r?\n?)'
        if ($content -match $headRe) {
            $content = [regex]::Replace($content, $headRe, "`$1$block", 1)
        } else {
            Write-Warn 'CHANGELOG.md 头部不是「# 更新日志 + ---」结构，新条目直接置于文件顶部'
            $content = $block.TrimEnd("`r`n") + "`n`n---`n`n" + $content
        }
    } else {
        $content = "# 更新日志`n`n---`n`n" + $block
        Write-Note "CHANGELOG.md 不存在，已创建：$ChangelogFile"
    }
    [System.IO.File]::WriteAllText($ChangelogFile, $content, (Get-Utf8NoBom))
    Write-Ok "已写入 $ChangelogFile（新增 $(@($bullets -split "`r?`n").Count) 行）"

    # ---------- 7. 记录状态（最新提交哈希 + 版本号） ----------
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $headSha = "$(& git -C $Root rev-parse HEAD)".Trim() } finally { $ErrorActionPreference = $prevEap }
    $stateJson = @{
        version   = $Version
        hash      = $headSha
        updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($StateFile, $stateJson, (Get-Utf8NoBom))
    Write-Ok "已记录状态到 $StateFile（下次可自动从该哈希续订）"

    Write-Host ''
    Write-Host "  CHANGELOG.md 与 $StateFile 已改动，请随本次发布一并提交。" -ForegroundColor Yellow
}
catch {
    Write-Host "`n[ERROR] 更新 CHANGELOG 失败：$($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

if (-not $NoPause) { Wait-Exit }
exit $exitCode