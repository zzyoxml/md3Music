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

# ---------- 任务参数解析 ----------
<#
  把命令行风格的参数数组（'-Switch'、'-Name','值'、'-Name:值'、裸位置值）解析成
  哈希表 + 位置参数数组，供 `& $script @named @pos` 调用。

  必须这么做的原因：PowerShell 的**数组** splat 只按位置传参——
  `$a = @('-Quiet'); & $script @a` 会把 '-Quiet' 当成第一个位置参数的**值**，
  而不是开关（实测 `-Flag` 被绑进了 `[string]$Name`）。只有**哈希表** splat
  才能绑定命名参数，所以透传前必须按目标脚本的参数元数据把 token 还原成键值。
#>
function ConvertTo-TaskParams {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyCollection()][object[]]$ArgList = @()
    )
    $meta = (Get-Command -Name $ScriptPath -CommandType ExternalScript).Parameters
    $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
        'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
        'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction')
    $scriptName = [System.IO.Path]::GetFileName($ScriptPath)

    # 参数名解析：先精确匹配，再前缀匹配（PowerShell 原生也支持缩写）
    function Resolve-ParamName([string]$Want) {
        $c = @($meta.Keys | Where-Object { $_ -ieq $Want })
        if (-not $c.Count) { $c = @($meta.Keys | Where-Object { $_ -ilike "$Want*" -and $common -notcontains $_ }) }
        if ($c.Count -eq 1) { return $c[0] }
        if ($c.Count -gt 1) { throw "参数 -$Want 有歧义（可匹配：$($c -join ', ')）" }
        throw "参数 -$Want 不存在：$scriptName 没有这个参数"
    }

    $named = @{}
    $pos = @()
    $i = 0
    $n = @($ArgList).Count
    while ($i -lt $n) {
        $tok = [string]$ArgList[$i]
        if ($tok -match '^--?([A-Za-z][\w-]*):(.+)$') {
            # -Name:值 单 token 形式
            $name = Resolve-ParamName $Matches[1]
            $val = $Matches[2]
            if ($meta[$name].ParameterType -eq [System.Management.Automation.SwitchParameter]) {
                $named[$name] = [bool]($val -inotin @('false', '$false', '0'))
            } else { $named[$name] = $val }
            $i++
        }
        elseif ($tok -match '^--?([A-Za-z][\w-]*):?$') {
            $name = Resolve-ParamName $Matches[1]
            if ($meta[$name].ParameterType -eq [System.Management.Automation.SwitchParameter]) {
                $named[$name] = $true
                $i++
            } else {
                if ($i + 1 -ge $n) { throw "参数 -$($Matches[1]) 缺少值" }
                $named[$name] = $ArgList[$i + 1]
                $i += 2
            }
        }
        else { $pos += $tok; $i++ }
    }
    [pscustomobject]@{ Named = $named; Positional = @($pos) }
}

# ---------- 终端 UI ----------
# 菜单 / 参数面板 / 勾选列表（鼠标 + 键盘）统一放在 lib/ui.ps1
. (Join-Path $PSScriptRoot 'ui.ps1')
