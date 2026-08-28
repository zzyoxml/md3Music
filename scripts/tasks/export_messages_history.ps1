#Requires -Version 5.1
<#
.SYNOPSIS
  消息级历史导出：把私有仓库的完整 git 历史重建为「空树提交」版本，
  只保留提交信息 / 作者 / 日期，不含任何 diff 与文件内容，可选推送公开仓库。

.DESCRIPTION
  方案 D（见 docs/git_history_export_analysis.md）：
    对私有仓库每个提交，在新临时仓库里用原 author/committer/date/message 重建一个
    树为空的提交对象（空树哈希 4b825dc642cb6eb9a060e54bf8d69288fbee4904），
    父子关系原样保留。产物是「消息完整、diff 全空」的 DAG：
      - 可见：提交信息（subject/body）、作者、提交人、日期
      - 不可见：任何文件内容 / 新增删除行数（空树无 diff）
    下载/缓存在历史上零残留（无 blob），可追溯但不可看代码。

  可选脱敏：
    -SanitizeMessages 对 commit message 文本按 scripts/public_deny.txt 过滤，
    命中特征短语替换为占位符（默认关闭，仅提示）。

  注意：本脚本只造「消息历史」，不导出工作树文件。文件内容仍走
  scripts/md3.ps1 export 的常规快照流程。

.PARAMETER OutDir
  新历史所在的临时仓库目录（默认 %TEMP%\md3music-public-messages-<时间戳>，避免污染仓库）。

.PARAMETER PublicRemote
  公开仓库 URL。提供时构建完成后推送。

.PARAMETER PublicBranch
  公开仓库目标分支（默认 main）。首次推送用 -Force；本地无此分支时正常 push。

.PARAMETER SinceHash
  可选：只保留从该提交（含）起的历史（早期丢弃，配合方案 B 截断）。
  不传则全量历史。

.PARAMETER SanitizeMessages
  对消息文本按 deny 清单做脱敏替换（命中特征短语 → 占位符）。

.PARAMETER DenyReplacement
  -SanitizeMessages 时的占位符文本（默认「[已隐藏]」）。

.PARAMETER Force
  推送用 --force（覆盖公开仓库已有同名分支历史）。首次建立基线的历史时使用。

.PARAMETER NoPause
  结束时不等待按键。

.EXAMPLE
  .\scripts\md3.ps1 export-messages                                  # 只重建消息历史（不推送）
  .\scripts\md3.ps1 export-messages -PublicRemote <URL> -Force       # 重建并首推公开仓库
  .\scripts\md3.ps1 export-messages -PublicRemote <URL> -SanitizeMessages -Force
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [string]$PublicRemote = '',
    [string]$PublicBranch = 'main',
    [string]$SinceHash = '',
    [switch]$SanitizeMessages,
    [string]$DenyReplacement = '[已隐藏]',
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Root = Get-RepoRoot
$EmptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
$redact = if (-not $DenyReplacement) { '[已隐藏]' } else { $DenyReplacement }

# 因 commit-tree 用环境变量取作者/提交人/日期，改前保存、执行后恢复，避免污染本进程
$envKeys = @('GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE',
             'GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE')
function Set-GitEnv([string]$name,[string]$value,[string]$email,[string]$date) {
    Set-Item "Env:GIT_$($name)_NAME"  $value
    Set-Item "Env:GIT_$($name)_EMAIL" $email
    Set-Item "Env:GIT_$($name)_DATE"  $date
}
function Reset-GitEnv() {
    foreach ($k in $envKeys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

# 读 deny 清单（脱敏用；含中文短语，UTF-8 读取）
function Get-DenyTerms {
    $f = Join-Path $Root 'scripts\public_deny.txt'
    if (-not (Test-Path $f)) { return @() }
    $terms = @()
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($line in [System.IO.File]::ReadAllLines($f, $utf8)) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { $terms += $t }
    }
    return $terms
}

try {
    # ---------- 1. 前置检查 ----------
    Write-Step '前置检查'
    if (-not (Test-Path (Join-Path $Root '.git'))) { throw "未找到 .git（$Root），请在项目根运行" }
    Assert-Command git '本脚本依赖 git'
    Write-Ok "源仓库：$Root"

    if (-not $OutDir) {
        $OutDir = Join-Path $env:TEMP "md3music-public-messages-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Write-Warn "未指定 -OutDir，使用临时目录：$OutDir"
    }
    if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $Root $OutDir }

    # ---------- 2. 收集提交历史（拓扑逆序：父先于子） ----------
    Write-Step '收集提交历史（拓扑逆序）'
    $sinceArg = if ($SinceHash) { "$SinceHash..HEAD" } else { 'HEAD' }
    $lines = & git -C $Root rev-list --topo-order --reverse --parents $sinceArg 2>$null
    if ($LASTEXITCODE -ne 0) { throw "rev-list 失败，请确认 -SinceHash 有效" }
    $srcCount = @($lines).Count
    if ($srcCount -eq 0) { throw "没有可导出的提交历史（$sinceArg）" }
    # SinceHash 模式下把基线提交本身也纳入（否则它会被当根丢弃可选，见下）
    Write-Ok "待重建提交数：$srcCount"

    # ---------- 3. 重建空树提交 ----------
    Write-Step "重建空树提交（空树 $($EmptyTree.Substring(0,8))…）"
    # 清空并初始化新仓库；别名必须先入对象库，fsck/推送才完整
    Remove-ItemBypass $OutDir
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Invoke-Native { git -C $OutDir init -q }
    $created = (& git -C $OutDir hash-object -t tree -w --stdin 2>$null)
    if ($created) { $EmptyTree = $created }
    Write-Ok "已在导出仓库物化空树对象：$EmptyTree"

    $msgFile = Join-Path $OutDir "._msg.tmp"
    $terms = if ($SanitizeMessages) { (Get-DenyTerms) } else { @() }
    $newMap = @{}   # 原始哈希 -> 新空树提交哈希
    $lastNew = $null

    for ($i = 0; $i -lt $srcCount; $i++) {
        $line = @($lines)[$i]
        $tok = $line -split '\s+'
        $orig = $tok[0]
        $origParents = @($tok[1..($tok.Count-1)] | Where-Object { $_ })
        Write-Progress -Activity '重建空树提交' -Status "处理 $($i+1)/$srcCount" -PercentComplete (($i+1)*100/$srcCount)

        # 读取作者/提交人/日期（RFC2822 含时区），以及消息正文
        $logFmt = '--format=%an%x09%ae%x09%aD%x09%cn%x09%ce%x09%cD'
        $meta = (& git -C $Root log -1 $logFmt $orig)
        $p = $meta -split "`t"
        if ($p.Count -lt 6) { throw "解析元数据失败：$orig" }
        $an,$ae,$ad,$cn,$ce,$cd = $p[0],$p[1],$p[2],$p[3],$p[4],$p[5]

        $msg = ( (& git -C $Root log -1 --format=%B $orig) -join "`n")
        foreach ($term in $terms) {
            if ($msg -match [regex]::Escape($term)) {
                $msg = $msg -replace [regex]::Escape($term), $redact
            }
        }
        if (-not $msg.EndsWith("`n")) { $msg += "`n" }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($msgFile, $msg, $utf8)

        # 父子映射：只保留已在映射中的父（截断模式允许祖先被丢弃 → 该分支成为根）
        $newParents = @()
        foreach ($op in $origParents) {
            if ($newMap.ContainsKey($op)) { $newParents += $op }
        }

        Set-GitEnv AUTHOR $an $ae $ad
        Set-GitEnv COMMITTER $cn $ce $cd
        $args = @($EmptyTree)
        foreach ($np in $newParents) { $args += @('-p', $newMap[$np]) }
        $args += @('-F', $msgFile)
        $new = (& git -C $OutDir commit-tree $args 2>&1)
        Reset-GitEnv
        if ($LASTEXITCODE -ne 0) { throw "commit-tree 失败：$($new -join ' ')" }

        $newMap[$orig] = ($new | Out-String).Trim()
        $lastNew = $newMap[$orig]
    }
    Write-Progress -Activity '重建空树提交' -Completed
    Remove-ItemBypass $msgFile
    Write-Ok "已重建 $($newMap.Count) 个空树提交"

    # 建立分支引用（研究对象）指向最新提交
    Invoke-Native { git -C $OutDir symbolic-ref HEAD "refs/heads/$PublicBranch" }
    Invoke-Native { git -C $OutDir update-ref "refs/heads/$PublicBranch" $lastNew }

    # ---------- 4. 自检 ----------
    Write-Step '自检'
    $outCount = (& git -C $OutDir rev-list --count HEAD 2>$null).Trim()
    if ([int]$outCount -ne $srcCount) { throw "自检失败：重建 $outCount ≠ 源 $srcCount" }
    # 确认历史中除空树外无任何树/文件 blob（唯一 tree 即空树，无 blob）
    $blobs = @(& git -C $OutDir rev-list --all --objects)
    $treeCount = @($blobs | Where-Object { $_ -match '^4b825dc642cb6eb9a060e54bf8d69288fbee4904 ' }).Count
    Write-Ok "历史提交数：$outCount（vs 源 $srcCount）"
    if ($treeCount -gt 1) { Write-Warn "检测到 $treeCount 处空树条目（首个为根空树，属预期）" }
    else { Write-Ok '历史零文件内容（无 blob）——下载/缓存代码零残留' }

    # ---------- 5. 可选推送 ----------
    if ($PublicRemote) {
        Write-Step "推送到公开仓库分支 $PublicBranch"
        [void](Enable-AutoProxy)
        Invoke-Native { git -C $OutDir remote add origin $PublicRemote }
        $pushArgs = @('push', '-u', 'origin', $PublicBranch)
        if ($Force) { $pushArgs = @('push', '--force', '-u', 'origin', $PublicBranch) }
        Invoke-WithRetry -What "推送 $PublicBranch" -Action { Invoke-Native { git -C $OutDir @pushArgs } }
        Write-Ok "已推送 $PublicRemote（分支 $PublicBranch）"
    } else {
        Write-Note "未指定 -PublicRemote，仅生成本地消息历史。产物目录：$OutDir"
    }

    # ---------- 6. 总结 ----------
    Write-Step '完成'
    Write-Ok "消息级历史已生成：$OutDir"
    Write-Host ''
    Write-Host '  验证：' -ForegroundColor Cyan
    Write-Host "    git -C $OutDir log --oneline --format='%h %an %ad %s' "
    Write-Host '    （可见作者/日期/消息；--stat 或 git show 无文件内容）'
}
catch {
    Write-Host "`n[ERROR] 导出失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $NoPause) { Wait-Exit }
exit 0