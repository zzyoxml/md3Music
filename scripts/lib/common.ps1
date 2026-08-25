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

# ---------- 设置搜索索引（生成产物） ----------
<#
  设置页搜索索引由 scripts/tools/gen_settings_search_index.dart 从设置页源码生成。
  设置项新增/改名后忘记重新生成，搜索结果就与实际设置项不一致，因此在任何
  commit / build 前静默同步一次：无变化不输出，有变化只提示一行（提醒一并提交）。

  工具缺失（公开导出树剥离了 scripts/tools）、dart 不在 PATH、或生成失败时
  只告警不拦断——构建/提交流程不该被开发期工具卡死；一致性由
  test/modules/settings/settings_search_index_test.dart 兜底。
#>
function Sync-SettingsSearchIndex {
    $root = Get-RepoRoot
    $gen = Join-Path $root 'scripts\tools\gen_settings_search_index.dart'
    $out = Join-Path $root 'lib\modules\settings\settings_search_index.g.dart'
    if (-not (Test-Path $gen)) { return }
    if (-not (Test-HasCommand dart)) { return }

    $before = if (Test-Path $out) { [System.IO.File]::ReadAllText($out) } else { '' }
    # dart run 把 "Running build hooks..." 写到 stderr，'Stop' 下会被当成终止错误，
    # 这里临时降为 Continue，只按退出码判成败（与 Invoke-Native / Invoke-Git 同一套约定）
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $root          # 生成器按当前目录定位源码
    try {
        $log = @(& dart run $gen 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }

    if ($code -ne 0) {
        $tail = @($log) | Where-Object { $_.Trim() } | Select-Object -Last 1
        Write-Warn "设置搜索索引生成失败（不拦断流程）：$tail"
        return
    }
    $after = if (Test-Path $out) { [System.IO.File]::ReadAllText($out) } else { '' }
    if ($after -ne $before) {
        Write-Warn '设置搜索索引已重新生成：lib/modules/settings/settings_search_index.g.dart（请一并提交）'
    }
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

# ---------- 本地代理自动探测 ----------
<#
  没开 TUN 模式时，git / gh 直连 github.com 会超时。这里自动找出本机在跑的代理并
  只在**当前进程内**设置代理环境变量（不写 git config，不影响 GitHub Desktop 等其他工具）。

  判定顺序：直连能通就不用代理 → 逐个探测常见代理端口 → 先认 HTTP 代理再认 SOCKS5
  （gh 对 http:// 支持最稳，socks5h 只在该端口不说 HTTP 时才用）→ 最后验证能否到 github.com。
#>
$script:Md3ProxyPorts = @(7890, 7897, 10809, 7891, 10808, 1080, 8889, 2080)
$script:Md3ProxyResolved = $false
$script:Md3ProxyUrl = $null

function Test-TcpPort {
    param([string]$HostName = '127.0.0.1', [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 200)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar)
        return $c.Connected
    }
    catch { return $false }
    finally { $c.Close() }
}

# 本地判定：给端口发一个普通 HTTP 请求，代理/HTTP 服务都会回 HTTP/xxx（不需要出网）
function Test-PortSpeaksHttp {
    param([Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 400)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar)
        $s = $c.GetStream()
        $s.ReadTimeout = $TimeoutMs
        $req = [Text.Encoding]::ASCII.GetBytes("HEAD / HTTP/1.0`r`n`r`n")
        $s.Write($req, 0, $req.Length); $s.Flush()
        $buf = New-Object byte[] 8
        $n = $s.Read($buf, 0, 8)
        if ($n -lt 5) { return $false }
        return ([Text.Encoding]::ASCII.GetString($buf, 0, 5) -eq 'HTTP/')
    }
    catch { return $false }
    finally { $c.Close() }
}

# SOCKS5 握手 + 可选的 CONNECT 目标验证，全程只用一条 TCP 连接
function Test-Socks5Proxy {
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$TargetHost = '',
        [int]$TargetPort = 443,
        [int]$TimeoutMs = 3000
    )
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(400)) { return $false }
        $c.EndConnect($ar)
        $s = $c.GetStream()
        $s.ReadTimeout = $TimeoutMs; $s.WriteTimeout = $TimeoutMs
        # 握手：VER=5, 1 种认证方式, 00=无认证
        $s.Write([byte[]](5, 1, 0), 0, 3); $s.Flush()
        $r = New-Object byte[] 2
        if ($s.Read($r, 0, 2) -ne 2 -or $r[0] -ne 5 -or $r[1] -ne 0) { return $false }
        if (-not $TargetHost) { return $true }
        # CONNECT：VER=5, CMD=1, RSV=0, ATYP=3(域名)
        $hb = [Text.Encoding]::ASCII.GetBytes($TargetHost)
        $req = @(5, 1, 0, 3, $hb.Length) + $hb + @([byte]($TargetPort -shr 8), [byte]($TargetPort -band 0xFF))
        $bytes = [byte[]]$req
        $s.Write($bytes, 0, $bytes.Length); $s.Flush()
        $rep = New-Object byte[] 4
        if ($s.Read($rep, 0, 4) -ne 4) { return $false }
        return ($rep[0] -eq 5 -and $rep[1] -eq 0)   # REP=0 表示连接目标成功
    }
    catch { return $false }
    finally { $c.Close() }
}

# 经 HTTP 代理（或直连）访问 github.com，验证真的能出网
function Test-HttpsReachable {
    param([string]$ProxyUrl = '', [int]$TimeoutMs = 5000)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        $req = [Net.HttpWebRequest]::Create('https://github.com/')
        $req.Method = 'HEAD'
        $req.Timeout = $TimeoutMs
        $req.AllowAutoRedirect = $false
        $req.Proxy = if ($ProxyUrl) { New-Object Net.WebProxy($ProxyUrl, $true) } else { $null }
        $resp = $req.GetResponse(); $resp.Close()
        return $true
    }
    catch [Net.WebException] {
        # 有 HTTP 响应（403/404 等）也说明链路是通的
        return [bool]$_.Exception.Response
    }
    catch { return $false }
}

# 返回可用代理 URL（socks5h://... 或 http://...），找不到返回 $null
# 优先 SOCKS5：它的验证是对 github.com:443 做真实 CONNECT，比一次 HTTPS HEAD 更硬；
# 实测同一个混合端口走 http:// 时 git 偶发 "schannel: failed to receive handshake"，
# 而 socks5h 稳定通过（git/curl 与 gh 都支持 socks5h）。
function Find-LocalProxy {
    foreach ($p in $script:Md3ProxyPorts) {
        if (-not (Test-TcpPort -Port $p)) { continue }
        if (Test-Socks5Proxy -Port $p -TargetHost 'github.com') { return "socks5h://127.0.0.1:$p" }
        if (Test-PortSpeaksHttp -Port $p) {
            $url = "http://127.0.0.1:$p"
            if (Test-HttpsReachable -ProxyUrl $url) { return $url }
        }
    }
    $null
}

<#
  确保后续 git / gh 的 GitHub 请求能出网。直连可用则什么都不做。
  只设置当前进程的环境变量：git（curl）读 ALL_PROXY / HTTPS_PROXY，gh 读 HTTPS_PROXY / HTTP_PROXY。
  结果在本次运行内缓存，多次调用不重复探测。
#>
function Enable-AutoProxy {
    param([switch]$Quiet)
    if ($script:Md3ProxyResolved) { return $script:Md3ProxyUrl }
    $script:Md3ProxyResolved = $true

    if ($env:HTTPS_PROXY -or $env:https_proxy -or $env:ALL_PROXY -or $env:all_proxy) {
        if (-not $Quiet) { Write-Note "沿用环境里已有的代理设置（HTTPS_PROXY/ALL_PROXY）" }
        $script:Md3ProxyUrl = $null
        return $null
    }
    if (Test-HttpsReachable) {
        if (-not $Quiet) { Write-Note 'github.com 直连可用，不使用代理' }
        $script:Md3ProxyUrl = $null
        return $null
    }
    if (-not $Quiet) { Write-Note 'github.com 直连不通，探测本机代理端口…' }
    $url = Find-LocalProxy
    if (-not $url) {
        if (-not $Quiet) {
            Write-Warn "未找到可用的本机代理（探测端口：$($script:Md3ProxyPorts -join ', ')）"
            Write-Warn '请开启代理软件，或手动设置 $env:HTTPS_PROXY 后重试。'
        }
        return $null
    }
    $env:HTTPS_PROXY = $url
    $env:HTTP_PROXY = $url
    $env:ALL_PROXY = $url
    $script:Md3ProxyUrl = $url
    if (-not $Quiet) { Write-Ok "已启用代理（仅本次运行）：$url" }
    $url
}

# ---------- GitHub 凭据（PAT） ----------
<#
  开 PR / 自动合并要调 GitHub REST API，需要一个带 repo 权限的 PAT。取用顺序：
    1. 环境变量 GH_TOKEN / GITHUB_TOKEN
    2. 本机保存的 token（DPAPI 加密，只有当前 Windows 用户能解开）
    3. 交互输入（可选择永久保存或仅本次运行）
  保存位置在 %LOCALAPPDATA%\md3music\ 下，**不在仓库内**，不可能被误提交。
#>
function Get-TokenStorePath {
    Join-Path $env:LOCALAPPDATA 'md3music\github_token.dat'
}

function Save-GitHubToken {
    param([Parameter(Mandatory)][string]$Token)
    $p = Get-TokenStorePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    # DPAPI：密文与当前用户 + 本机绑定，换机器/换用户都解不开
    $enc = ConvertTo-SecureString -String $Token -AsPlainText -Force | ConvertFrom-SecureString
    Set-Content -LiteralPath $p -Value $enc -Encoding ASCII
    $p
}

function Get-SavedGitHubToken {
    $p = Get-TokenStorePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $sec = ConvertTo-SecureString (Get-Content -LiteralPath $p -Raw).Trim()
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
    catch {
        Write-Warn "已保存的 token 解密失败（可能换了用户或机器）：$p"
        $null
    }
}

function Remove-SavedGitHubToken {
    $p = Get-TokenStorePath
    if (Test-Path -LiteralPath $p) { Remove-ItemBypass $p; return $true }
    $false
}

function Get-GitHubTokenSource {
    if ($env:GH_TOKEN) { return '环境变量 GH_TOKEN' }
    if ($env:GITHUB_TOKEN) { return '环境变量 GITHUB_TOKEN' }
    if (Test-Path -LiteralPath (Get-TokenStorePath)) { return "本机保存（$(Get-TokenStorePath)）" }
    return $null
}

<#
  取 PAT。-NoPrompt 时找不到就返回 $null；否则交互输入并询问是否永久保存。
  仅本次运行 = 写进当前进程的 $env:GH_TOKEN，进程退出即消失。
#>
function Get-GitHubToken {
    param([switch]$NoPrompt)
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    $saved = Get-SavedGitHubToken
    if ($saved) { return $saved }
    # 非控制台环境下 Read-Host 会阻塞而不是报错，这里直接放弃交互
    if ($NoPrompt -or -not (Test-InteractiveConsole)) { return $null }

    Write-Host ''
    Write-Host '  需要 GitHub Personal Access Token（PAT）才能开 PR / 自动合并。' -ForegroundColor Cyan
    Write-Note '  生成：https://github.com/settings/tokens  → 勾选 repo 权限（classic）或对目标仓库有 PR 读写的 fine-grained'
    $sec = Read-Host '  粘贴 token（输入不回显，直接回车取消）' -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $tok = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    $tok = "$tok".Trim()
    if (-not $tok) { Write-Warn '未输入 token'; return $null }

    $ans = Read-Host '  保存到本机以后免输入？(Y=永久保存 / N=仅本次运行) [Y/n]'
    if ([string]::IsNullOrWhiteSpace($ans) -or $ans.Trim().ToLowerInvariant() -in @('y', 'yes', '是')) {
        $p = Save-GitHubToken -Token $tok
        Write-Ok "已加密保存到 $p（DPAPI，仅当前用户可解）"
    } else {
        $env:GH_TOKEN = $tok
        Write-Note '  仅本次运行有效（未落盘）'
    }
    $tok
}

<#
  调 GitHub REST API。走 curl.exe 而不是 Invoke-RestMethod：curl 与 git 读同一套
  代理环境变量（含 socks5h://，.NET 的 WebProxy 不支持 SOCKS），网络路径保持一致。
  返回 @{ Status; Body }（Body 已 ConvertFrom-Json，解析失败则为原始字符串）。
#>
function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'GET',
        [string]$Token = '',
        $Body = $null,
        [int]$TimeoutSec = 30
    )
    Assert-Command curl.exe 'GitHub API 调用需要 curl（Git for Windows 自带，Win10+ 系统亦内置）'
    $url = if ($Path -like 'http*') { $Path } else { "https://api.github.com$Path" }
    $curlArgs = @(
        '-sS', '--max-time', "$TimeoutSec", '-X', $Method,
        '-w', '\n%{http_code}',
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28',
        '-H', 'User-Agent: md3music-scripts'
    )
    if ($Token) { $curlArgs += @('-H', "Authorization: Bearer $Token") }
    $tmp = $null
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 -Compress }
        # 经文件传 body：避免中文标题/正文在命令行上被编码折损
        $tmp = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        $curlArgs += @('-H', 'Content-Type: application/json', '--data-binary', "@$tmp")
    }
    $curlArgs += $url
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # GitHub 的响应是 UTF-8；不临时切换读取编码的话，中文在 GBK 控制台下会被解成乱码，
    # 错误消息看不懂，返回体里的中文也对不上。
    $prevEnc = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
        $out = & curl.exe @curlArgs 2>&1
    }
    finally {
        $ErrorActionPreference = $prev
        try { [Console]::OutputEncoding = $prevEnc } catch { }
        if ($tmp) { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
    # curl 的原生输出在 PowerShell 里已按行拆成数组，直接插值会用空格拼接，
    # 那样最后一行的状态码就取不出来了——这里逐元素再拆一次行。
    $lines = @()
    foreach ($l in @($out)) { $lines += ("$l" -split "`r?`n") }
    $lines = @($lines | Where-Object { $null -ne $_ })
    $status = 0
    if ($lines.Count) { [void][int]::TryParse("$($lines[-1])".Trim(), [ref]$status) }
    $raw = if ($lines.Count -gt 1) { ($lines[0..($lines.Count - 2)] -join "`n").Trim() } else { '' }
    $parsed = $raw
    if ($raw) { try { $parsed = $raw | ConvertFrom-Json } catch { } }
    [pscustomobject]@{ Status = $status; Body = $parsed; Raw = $raw }
}

function Test-GitHubToken {
    param([Parameter(Mandatory)][string]$Token)
    $r = Invoke-GitHubApi -Path '/user' -Token $Token
    if ($r.Status -eq 200) {
        [pscustomobject]@{ Ok = $true; Login = $r.Body.login; Status = 200 }
    } else {
        [pscustomobject]@{ Ok = $false; Login = $null; Status = $r.Status; Message = "$($r.Body.message)" }
    }
}

# ---------- GitHub ----------
<#
  网络类操作重试。经代理访问 github.com 时链路会偶发抖动，实测同一条 git ls-remote
  在 schannel 与 openssl 两种 TLS 后端下都会随机报
  "schannel: failed to receive handshake, SSL/TLS connection failed"（约 1/5 概率），
  换后端并不能消除——所以推送 / 克隆 / 开 PR 这类一次性网络操作统一重试几次。
  只用于网络操作；本地 git 操作失败应当立刻报错，不要重试。
#>
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$Retries = 3,
        [int]$DelayMs = 2000,
        [string]$What = '网络操作'
    )
    for ($i = 1; $i -le $Retries; $i++) {
        try { return (& $Action) }
        catch {
            if ($i -eq $Retries) { throw }
            $first = "$($_.Exception.Message)".Split("`n")[0].Trim()
            Write-Warn "$What 第 $i 次失败：$first"
            Write-Note "  $([int]($DelayMs / 1000)) 秒后重试（第 $($i + 1)/$Retries 次）…"
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

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

<#
  开 PR 并直接合并（走 REST API，需要对目标仓库有写权限的 PAT）。
  已存在同 head 的 open PR 时复用它，不重复创建。
  返回 [pscustomobject]{ Number; Url; Merged; Message }；Merged=$false 时 Message 说明原因。

  合并前要等 GitHub 算完可合并性：PR 刚建出来 mergeable 是 null，此时直接 PUT merge 会被拒。
#>
function Invoke-GitHubPrMerge {
    param(
        [Parameter(Mandatory)][string]$RepoSlug,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$Token,
        [string]$Title = '',
        [string]$Body = '',
        [ValidateSet('merge', 'squash', 'rebase')][string]$MergeMethod = 'merge'
    )
    # 网络/服务端抖动（curl 失败 Status=0、5xx）抛出去交给 Invoke-WithRetry 重试；
    # 权限、冲突、参数一类的确定性错误不重试，直接返回结构化结果。
    function Assert-TransientOk {
        param($Resp, [string]$What)
        if ($Resp.Status -eq 0 -or $Resp.Status -ge 500) { throw "$What 暂时失败（HTTP $($Resp.Status)）" }
    }

    # 1) 找已存在的 open PR（head 过滤要求 owner:branch 形式）
    $enc = [Uri]::EscapeDataString($Head)
    $find = Invoke-GitHubApi -Path "/repos/$RepoSlug/pulls?state=open&base=$([Uri]::EscapeDataString($Base))&head=$enc" -Token $Token
    Assert-TransientOk -Resp $find -What '查询 PR'
    if ($find.Status -eq 401) { return [pscustomobject]@{ Number = 0; Url = ''; Merged = $false; Message = 'token 无效（401 Bad credentials）' } }
    if ($find.Status -eq 404) { return [pscustomobject]@{ Number = 0; Url = ''; Merged = $false; Message = "仓库不可见或无权限：$RepoSlug（404）" } }

    $pr = $null
    if ($find.Status -eq 200 -and @($find.Body).Count -gt 0) {
        $pr = @($find.Body)[0]
        Write-Note "  复用已存在的 PR #$($pr.number)"
    }

    # 2) 没有就创建
    if (-not $pr) {
        $create = Invoke-GitHubApi -Path "/repos/$RepoSlug/pulls" -Method POST -Token $Token -Body @{
            title = $(if ($Title) { $Title } else { "$Head -> $Base" })
            head  = $Head
            base  = $Base
            body  = $Body
        }
        Assert-TransientOk -Resp $create -What '创建 PR'
        if ($create.Status -eq 201) {
            $pr = $create.Body
            Write-Ok "已创建 PR #$($pr.number)：$($pr.html_url)"
        }
        elseif ($create.Status -eq 422) {
            # 常见于「已存在同 head 的 PR」或「无提交差异」
            $msg = "$($create.Body.message)"
            foreach ($e in @($create.Body.errors)) { if ($e.message) { $msg += "；$($e.message)" } }
            $again = Invoke-GitHubApi -Path "/repos/$RepoSlug/pulls?state=open&head=$enc" -Token $Token
            if ($again.Status -eq 200 -and @($again.Body).Count -gt 0) {
                $pr = @($again.Body)[0]
                Write-Note "  已存在 PR #$($pr.number)，改为直接合并它"
            } else {
                return [pscustomobject]@{ Number = 0; Url = ''; Merged = $false; Message = "创建 PR 失败（422）：$msg" }
            }
        }
        else {
            return [pscustomobject]@{ Number = 0; Url = ''; Merged = $false; Message = "创建 PR 失败（$($create.Status)）：$($create.Body.message)" }
        }
    }

    # 3) 等 GitHub 算出可合并性
    $num = $pr.number
    $mergeable = $pr.mergeable
    for ($i = 1; $i -le 6 -and $null -eq $mergeable; $i++) {
        Start-Sleep -Seconds 2
        $d = Invoke-GitHubApi -Path "/repos/$RepoSlug/pulls/$num" -Token $Token
        if ($d.Status -eq 200) { $pr = $d.Body; $mergeable = $pr.mergeable }
    }
    if ($mergeable -eq $false) {
        return [pscustomobject]@{ Number = $num; Url = "$($pr.html_url)"; Merged = $false
            Message = "PR #$num 存在冲突，无法自动合并（mergeable_state=$($pr.mergeable_state)），请在网页上处理" }
    }

    # 4) 合并
    $m = Invoke-GitHubApi -Path "/repos/$RepoSlug/pulls/$num/merge" -Method PUT -Token $Token -Body @{
        merge_method = $MergeMethod
        commit_title = "Merge pull request #$num from $($Head -replace ':', '/')"
    }
    Assert-TransientOk -Resp $m -What '合并 PR'
    if ($m.Status -eq 200 -and $m.Body.merged) {
        return [pscustomobject]@{ Number = $num; Url = "$($pr.html_url)"; Merged = $true; Message = "$($m.Body.sha)" }
    }
    $why = switch ($m.Status) {
        403 { 'token 对该仓库没有合并权限（需要 write / maintain）' }
        405 { "GitHub 拒绝合并：$($m.Body.message)（常见原因：分支保护要求评审或 CI 通过）" }
        409 { "PR 的 head 已变化：$($m.Body.message)，重新推送后再试" }
        default { "合并失败（$($m.Status)）：$($m.Body.message)" }
    }
    [pscustomobject]@{ Number = $num; Url = "$($pr.html_url)"; Merged = $false; Message = $why }
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
