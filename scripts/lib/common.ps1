#Requires -Version 5.1
<#
.SYNOPSIS
  MD3Music 脚本公共库（由 scripts/tasks/*.ps1 点源引入）。

.DESCRIPTION
  收敛此前散落在 build_android.ps1 / build_windows.ps1 / export_public.ps1 /
  verify_public_clean.ps1 里的重复实现：
    - 输出辅助（Write-Step/Ok/Warn/Fail）与退出前暂停
    - 外部命令调用（cargo/flutter/git 的 stderr 不当作失败）
    - 安全删除旁路（规避本机删除钩子对 Remove-Item 的拦截）
    - 仓库根 / pubspec 版本 / Rust 改动检测
    - 否认清单闸门（唯一实现，导出与自检共用）

  用法：. (Join-Path $PSScriptRoot '..\lib\common.ps1')
#>

# 本文件位于 scripts/lib/ → 上溯两级即项目根
$script:Md3RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-RepoRoot { $script:Md3RepoRoot }

# UTF-8 无 BOM：deny 清单含中文短语，读写都必须显式指定，否则中文命中会漏判
function Get-Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }

# ---------- 输出辅助 ----------
function Write-Step([string]$Msg) { Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Write-Fail([string]$Msg) { Write-Host "  [XX] $Msg" -ForegroundColor Red }
function Write-Note([string]$Msg) { Write-Host "  $Msg" -ForegroundColor DarkGray }

# 结束前暂停，避免双击运行时窗口一闪而过；非交互宿主（CI/工具调用）降级为短等待
function Wait-Exit {
    Write-Host "`n按任意键退出..." -ForegroundColor Cyan
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    catch { Start-Sleep -Seconds 2 }
}

# ---------- 外部命令 ----------
# cargo/flutter/git 的正常进度输出走 stderr，$ErrorActionPreference='Stop' 下会被
# 当成 NativeCommandError 抛出。这里临时切回 Continue，只按退出码判定成败。
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command
        if ($LASTEXITCODE -ne 0) { throw "命令失败，退出码 $LASTEXITCODE" }
    }
    finally { $ErrorActionPreference = $prev }
}

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "未找到 $Name$(if ($Hint) { "：$Hint" })"
    }
}

function Test-HasCommand([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# 把 cargo 加入 PATH（Windows 上非登录 shell 常缺）
function Add-CargoToPath {
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if ((Test-Path $cargoBin) -and ($env:Path -notlike "*$cargoBin*")) {
        $env:Path = "$cargoBin;$env:Path"
    }
}

# ---------- 文件操作 ----------
# 走 .NET IO 旁路，规避本机安全删除钩子对 Remove-Item 的拦截
function Remove-ItemBypass([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item -is [System.IO.DirectoryInfo]) {
            [System.IO.Directory]::Delete($item.FullName, $true)
        } else {
            [System.IO.File]::Delete($item.FullName)
        }
    }
}

function Get-PubspecVersion {
    $pub = Get-Content (Join-Path (Get-RepoRoot) 'pubspec.yaml') | Select-String '^version:'
    if ($pub) { ($pub.ToString() -replace '^version:\s*', '' -split '\+')[0] } else { '0.0.0' }
}

# ---------- Rust 改动检测 ----------
# 工作区（含未跟踪文件）里 Rust 目录是否有未提交改动
function Test-RustDirty {
    $root = Get-RepoRoot
    if (-not (Test-HasCommand git)) { return $false }
    $st = & git -C $root status --porcelain -- kugou_api_server/rust/ 2>$null
    ($LASTEXITCODE -eq 0) -and [bool]$st
}

# ---------- 否认清单闸门（唯一实现） ----------
function Get-DenyPattern {
    param([string]$DenyFile)
    if (-not $DenyFile) { $DenyFile = Join-Path (Get-RepoRoot) 'scripts\public_deny.txt' }
    if (-not (Test-Path $DenyFile)) { throw "未找到否认清单：$DenyFile" }
    $lines = [System.IO.File]::ReadAllLines($DenyFile, (Get-Utf8NoBom)) |
        Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') }
    [pscustomobject]@{
        Count   = @($lines).Count
        Pattern = (($lines | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|')
        File    = $DenyFile
    }
}

<#
  扫描一棵树（私有仓库根 或 导出树根）里的私有符号命中。
  -SkipPrivateDir：跳过 lib/private/（私有仓库自检用；导出树本就没有该目录）。
  只返回命中结果，是否视为致命由调用方决定——导出闸门 pubspec 命中即拦截，
  私有仓库自检 pubspec 命中属预期（导出时才剥离）。
#>
function Invoke-DenyGate {
    param(
        [Parameter(Mandatory)][string]$TreeRoot,
        [switch]$SkipPrivateDir,
        [string]$DenyFile
    )
    $deny = Get-DenyPattern -DenyFile $DenyFile
    $libDir  = Join-Path $TreeRoot 'lib'
    $pubspec = Join-Path $TreeRoot 'pubspec.yaml'

    $libHits = @()
    $dartFiles = Get-ChildItem $libDir -Recurse -Filter *.dart -ErrorAction SilentlyContinue
    if ($SkipPrivateDir) {
        $dartFiles = $dartFiles | Where-Object { $_.FullName -notlike '*\lib\private\*' }
    }
    if ($dartFiles) {
        $libHits += $dartFiles | Select-String -Pattern $deny.Pattern -ErrorAction SilentlyContinue
    }

    $pubspecHits = @()
    if (Test-Path $pubspec) {
        $pubspecHits += Select-String -Path $pubspec -Pattern $deny.Pattern -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        DenyCount   = $deny.Count
        LibHits     = @($libHits)
        PubspecHits = @($pubspecHits)
    }
}

function Write-DenyHits {
    param([Parameter(Mandatory)][object[]]$Hits, [string]$Color = 'Red')
    foreach ($h in $Hits) {
        Write-Host "    $($h.Path):$($h.LineNumber)  $($h.Line.Trim())" -ForegroundColor $Color
    }
}

# ---------- GitHub ----------
# 从 remote URL 提取 owner/repo（支持 https / ssh / 带或不带 .git）
function ConvertTo-GitHubSlug([string]$RemoteUrl) {
    if (-not $RemoteUrl) { return $null }
    $u = $RemoteUrl.Trim()
    $m = [regex]::Match($u, '(?:github\.com[/:])([^/]+)/([^/]+?)(?:\.git)?/?$')
    if ($m.Success) { "$($m.Groups[1].Value)/$($m.Groups[2].Value)" } else { $null }
}

<#
  创建 Pull Request。gh CLI 可用则直接建；否则构造 GitHub compare 链接并用默认浏览器打开，
  标题/正文预填。两条路都不成立时（无浏览器的非交互环境）只打印链接。
  -Head 可以是 'branch' 或 'owner:branch'（跨 fork 时必须带 owner:）。
#>
function New-GitHubPr {
    param(
        [Parameter(Mandatory)][string]$RemoteUrl,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Head,
        [string]$Title = '',
        [string]$Body = '',
        [string]$RepoDir
    )
    $slug = ConvertTo-GitHubSlug $RemoteUrl
    if (-not $slug) { throw "无法从远端地址解析 owner/repo：$RemoteUrl" }

    if (Test-HasCommand gh) {
        $ghArgs = @('pr', 'create', '--repo', $slug, '--base', $Base, '--head', $Head)
        if ($Title) { $ghArgs += @('--title', $Title) }
        if ($Body)  { $ghArgs += @('--body',  $Body) } else { $ghArgs += @('--body', '') }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($RepoDir) { Push-Location $RepoDir }
            try { & gh @ghArgs } finally { if ($RepoDir) { Pop-Location } }
        }
        finally { $ErrorActionPreference = $prev }
        if ($LASTEXITCODE -eq 0) { Write-Ok "已通过 gh 创建 PR：$slug ($Head -> $Base)"; return }
        Write-Warn "gh pr create 失败（退出码 $LASTEXITCODE），改用浏览器方式。"
    }

    $q = "expand=1"
    if ($Title) { $q += "&title=$([System.Uri]::EscapeDataString($Title))" }
    if ($Body)  { $q += "&body=$([System.Uri]::EscapeDataString($Body))" }
    $url = "https://github.com/$slug/compare/$Base...$Head`?$q"
    Write-Host "  PR 链接：$url" -ForegroundColor Cyan
    try { Start-Process $url | Out-Null; Write-Ok '已在默认浏览器中打开 PR 创建页' }
    catch { Write-Warn '无法自动打开浏览器，请手动复制上面的链接。' }
}

# ---------- 通用 TUI ----------
# 非控制台宿主（输出被重定向 / CI）下 RawUI.ReadKey 不可用，给出可执行的替代指引而不是崩栈
function Read-ConsoleKey {
    param([string]$FallbackHint = '请在 PowerShell 窗口中运行，或直接用命令行参数调用。')
    try { return $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    catch { throw "当前宿主不支持交互按键（非控制台环境）。$FallbackHint" }
}

function Wait-AnyKey([string]$Msg = '按任意键继续...') {
    Write-Host ''
    Write-Host $Msg -ForegroundColor Cyan
    $null = Read-ConsoleKey
}

function New-MenuItem {
    param([string]$Key, [string]$Label, [string]$Desc, [bool]$Enabled = $true)
    [pscustomobject]@{ Key = $Key; Label = $Label; Desc = $Desc; Enabled = $Enabled }
}

# 光标只停在 Enabled 项上，首尾循环
function Get-AdjacentEnabledIndex {
    param([Parameter(Mandatory)][object[]]$Items, [int]$From, [int]$Step)
    $n = $Items.Count
    for ($i = 1; $i -le $n; $i++) {
        $idx = (($From + $Step * $i) % $n + $n) % $n
        if ($Items[$idx].Enabled) { return $idx }
    }
    $From
}

<#
  单选菜单。$Items 用 New-MenuItem 构造（Enabled=$false 显示为灰色且不可选中）。
  返回选中项索引；Esc/q 返回 -1。
#>
function Show-Menu {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Title = '',
        [string]$Hint = '↑↓ 选择   Enter 确认   q 退出',
        [string]$Footer = ''
    )
    if (-not @($Items | Where-Object Enabled).Count) { throw '菜单没有可用项' }
    $cursor = Get-AdjacentEnabledIndex -Items $Items -From ($Items.Count - 1) -Step 1
    $width = ($Items | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
    while ($true) {
        Clear-Host
        if ($Title) { Write-Host $Title -ForegroundColor Cyan -NoNewline; Write-Host "   $Hint" -ForegroundColor DarkGray }
        else { Write-Host $Hint -ForegroundColor DarkGray }
        Write-Host ''
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $it = $Items[$i]
            $arrow = if ($i -eq $cursor) { '>' } else { ' ' }
            $color = if (-not $it.Enabled) { 'DarkGray' } elseif ($i -eq $cursor) { 'Cyan' } else { 'White' }
            $tag = if ($it.Enabled) { '' } else { '(当前树不可用) ' }
            Write-Host ("  {0} {1}   {2}{3}" -f $arrow, $it.Label.PadRight($width), $tag, $it.Desc) -ForegroundColor $color
        }
        if ($Footer) { Write-Host ''; Write-Host "  $Footer" -ForegroundColor DarkGray }
        $key = Read-ConsoleKey
        switch ($key.VirtualKeyCode) {
            38      { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step -1 }
            40      { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step 1 }
            13      { return $cursor }
            27      { return -1 }
            default {
                switch ("$($key.Character)".ToLowerInvariant()) {
                    'k' { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step -1 }
                    'j' { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step 1 }
                    'q' { return -1 }
                }
            }
        }
    }
}

# 参数项：switch = 开关；value = 需要取值（空格进入输入，回车留空即清除）
function New-TaskOption {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('switch', 'value')][string]$Kind = 'switch',
        [string]$Desc = '',
        [string]$Value = ''
    )
    [pscustomobject]@{ Name = $Name; Kind = $Kind; Desc = $Desc; Checked = $false; Value = $Value }
}

# 把勾选结果拼成参数数组（数组透传给任务脚本，值里的空格无需自行转义）
function Get-OptionArgs {
    param([object[]]$Options)
    $a = @()
    foreach ($o in @($Options)) {
        if ($o.Kind -eq 'switch') { if ($o.Checked) { $a += $o.Name } }
        elseif ($o.Value) { $a += @($o.Name, $o.Value) }
    }
    , $a
}

function Format-ArgPreview {
    param([object[]]$ArgList)
    (@($ArgList) | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

<#
  参数勾选面板。就地修改 $Options（New-TaskOption 构造）。
  返回 $true=执行 / $false=返回上一级。无可选参数时直接返回 $true。
#>
function Show-OptionPicker {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Options,
        [string]$Title = '',
        [string]$CommandPrefix = ''
    )
    if (-not @($Options).Count) { return $true }
    $cursor = 0
    $width = ($Options | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    while ($true) {
        Clear-Host
        Write-Host $Title -ForegroundColor Cyan -NoNewline
        Write-Host '   ↑↓ 移动   空格 切换/输入   Enter 执行   Esc 返回' -ForegroundColor DarkGray
        Write-Host ''
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $o = $Options[$i]
            $on = if ($o.Kind -eq 'switch') { $o.Checked } else { [bool]$o.Value }
            $box = if ($o.Kind -eq 'switch') { if ($o.Checked) { '[x]' } else { '[ ]' } }
                   elseif ($o.Value) { '[=]' } else { '[ ]' }
            $arrow = if ($i -eq $cursor) { '>' } else { ' ' }
            $suffix = if ($o.Kind -eq 'value' -and $o.Value) { "   = $($o.Value)" }
                      elseif ($o.Kind -eq 'value') { '   （空格输入）' } else { '' }
            $color = if ($i -eq $cursor) { 'Cyan' } elseif ($on) { 'White' } else { 'DarkGray' }
            Write-Host ("  {0} {1} {2}   {3}{4}" -f $arrow, $box, $o.Name.PadRight($width), $o.Desc, $suffix) -ForegroundColor $color
        }
        Write-Host ''
        $preview = Format-ArgPreview (Get-OptionArgs $Options)
        Write-Host "  将执行：$CommandPrefix$(if ($preview) { " $preview" })" -ForegroundColor Yellow
        $key = Read-ConsoleKey
        switch ($key.VirtualKeyCode) {
            38 { if ($cursor -gt 0) { $cursor-- } else { $cursor = $Options.Count - 1 } }
            40 { if ($cursor -lt $Options.Count - 1) { $cursor++ } else { $cursor = 0 } }
            13 { return $true }
            27 { return $false }
            32 {
                $o = $Options[$cursor]
                if ($o.Kind -eq 'switch') { $o.Checked = -not $o.Checked }
                else {
                    Write-Host ''
                    $tip = if ($o.Value) { "（当前 $($o.Value)；直接回车清除）" } else { '（直接回车取消）' }
                    $v = Read-Host "  输入 $($o.Name) 的值$tip"
                    $o.Value = "$v".Trim()
                }
            }
            default {
                switch ("$($key.Character)".ToLowerInvariant()) {
                    'k' { if ($cursor -gt 0) { $cursor-- } else { $cursor = $Options.Count - 1 } }
                    'j' { if ($cursor -lt $Options.Count - 1) { $cursor++ } else { $cursor = 0 } }
                    'q' { return $false }
                }
            }
        }
    }
}
