#Requires -Version 5.1
<#
.SYNOPSIS
  LLM 辅助生成提交信息（OpenAI 兼容 /chat/completions 接口）。

.DESCRIPTION
  由 scripts/tasks/commit.ps1 在 -Llm 时点源引入，公共输出/网络辅助来自 lib/common.ps1。

  配置优先级：环境变量 > 本文件内置默认值。内置 key 是共享的公共额度，
  额度用完或被吊销时按下面的环境变量换成自己的即可，无需改脚本：

    MD3_LLM_BASE_URL   OpenAI 兼容 base（默认 https://api.chatanywhere.tech/v1）
    MD3_LLM_API_KEY    API key
    MD3_LLM_MODEL      模型名（默认 gpt-5.6-luna）

  失败（无 key / 网络不通 / 返回异常 / 解析不出结果）一律抛出，
  调用方回退到按文件路径推断的候选信息，不影响提交本身。

  接口按「次」计费：这里不做任何重试，一次不成就回退模板；相应地单次请求尽量
  把标题 / 提交正文 / PR 描述一并要回来，别为同一批改动付第二次。结果还会按
  diff 指纹缓存（Get-CachedLlmCommitMessage / Set-CachedLlmCommitMessage）：
  改动没变时重跑脚本直接复用上次结果，不再计费。
#>

# 内置默认配置：写死在脚本里，克隆下来即可用；用环境变量可覆盖任意一项。
$script:Md3LlmDefaults = @{
    BaseUrl = 'https://api.chatanywhere.tech/v1'
    ApiKey  = 'sk-1urEePOMSOFaX4UF5fuP5PwYYVUpwtDtrVv45Sfq6ZtwpxPM'
    Model   = 'gpt-5.6-luna'
}

function Get-LlmConfig {
    $base = if ($env:MD3_LLM_BASE_URL) { $env:MD3_LLM_BASE_URL } else { $script:Md3LlmDefaults.BaseUrl }
    $key  = if ($env:MD3_LLM_API_KEY)  { $env:MD3_LLM_API_KEY }  else { $script:Md3LlmDefaults.ApiKey }
    $mdl  = if ($env:MD3_LLM_MODEL)    { $env:MD3_LLM_MODEL }    else { $script:Md3LlmDefaults.Model }
    [pscustomobject]@{
        BaseUrl = "$base".TrimEnd('/')
        ApiKey  = "$key".Trim()
        Model   = "$mdl".Trim()
        Source  = if ($env:MD3_LLM_API_KEY) { '环境变量 MD3_LLM_API_KEY' } else { '脚本内置默认 key' }
    }
}

<#
  调 /chat/completions。与 Invoke-GitHubApi 同样走 curl.exe：curl 读 git 那套代理
  环境变量（含 socks5h://），网络路径与推送保持一致。
  返回 @{ Status; Content; Raw }；Content 是首个 choice 的文本（取不到则为空）。
#>
function Invoke-LlmChat {
    param(
        [Parameter(Mandatory)][object[]]$Messages,
        [int]$TimeoutSec = 60,
        [double]$Temperature = 0.2
    )
    $cfg = Get-LlmConfig
    if (-not $cfg.ApiKey) { throw '未配置 API key（设置环境变量 MD3_LLM_API_KEY）' }
    Assert-Command curl.exe 'LLM 调用需要 curl（Git for Windows 自带，Win10+ 系统亦内置）'
    $payload = @{
        model       = $cfg.Model
        messages    = $Messages
        temperature = $Temperature
    } | ConvertTo-Json -Depth 6 -Compress
    # 经文件传 body：diff 里有中文与引号，命令行传参会被折损
    $tmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tmp, $payload, (New-Object Text.UTF8Encoding($false)))
    $curlArgs = @(
        '-sS', '--max-time', "$TimeoutSec", '-X', 'POST',
        '-w', '\n%{http_code}',
        '-H', 'Content-Type: application/json',
        '-H', "Authorization: Bearer $($cfg.ApiKey)",
        '-H', 'User-Agent: md3music-scripts',
        '--data-binary', "@$tmp",
        "$($cfg.BaseUrl)/chat/completions"
    )
    $prev = $ErrorActionPreference
    $prevEnc = [Console]::OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
        $out = & curl.exe @curlArgs 2>&1
    }
    finally {
        $ErrorActionPreference = $prev
        try { [Console]::OutputEncoding = $prevEnc } catch { }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    $lines = @()
    foreach ($l in @($out)) { $lines += ("$l" -split "`r?`n") }
    $lines = @($lines | Where-Object { $null -ne $_ })
    $status = 0
    if ($lines.Count) { [void][int]::TryParse("$($lines[-1])".Trim(), [ref]$status) }
    $raw = if ($lines.Count -gt 1) { ($lines[0..($lines.Count - 2)] -join "`n").Trim() } else { '' }
    $content = ''
    if ($raw) {
        try { $content = "$(($raw | ConvertFrom-Json).choices[0].message.content)" } catch { }
    }
    [pscustomobject]@{ Status = $status; Content = $content; Raw = $raw }
}

# 去掉模型偶发包裹的 ```json 围栏，取出第一个 JSON 对象
function ConvertFrom-LlmJson([string]$Text) {
    if (-not $Text) { return $null }
    $t = "$Text".Trim()
    $t = [regex]::Replace($t, '^```(?:json)?\s*', '')
    $t = [regex]::Replace($t, '\s*```$', '')
    $m = [regex]::Match($t, '(?s)\{.*\}')
    if (-not $m.Success) { return $null }
    try { $m.Value | ConvertFrom-Json } catch { $null }
}

<#
  让模型按仓库惯例写提交信息。返回 [pscustomobject]@{ Title; Body; PrBody }。

  接口按「次」计费，所以这里只发一次请求、不重试：任何失败（HTTP 非 200 / 返回
  解析不出 / 没给标题）都直接抛出，由调用方回退到模板候选。相应地，一次请求里
  尽量把能用上的东西都要齐——标题、提交正文、PR 描述——避免为同一批改动再花第二次。

  system 提示按「每次都要发」压缩过措辞：规则一条不少，但不写解释性长句。

  $DiffText 由调用方裁剪好（文件清单 + 统计 + 只含变更行的 diff）。
#>
function New-LlmCommitMessage {
    param(
        [Parameter(Mandatory)][string]$DiffText,
        [string[]]$ScopeHints = @(),
        [int]$TimeoutSec = 120
    )
    $sys = @'
你是资深工程师，为 git 改动写 Conventional Commits 提交信息与 PR 描述。规则：
- 标题一行 type(scope): 中文描述；type 取 feat/fix/docs/style/refactor/perf/test/chore/ci 之一
- scope 小写英文，最多 3 个、用 ", " 分隔；与 type 同名时省略 scope
- 标题不超 50 汉字，写清改动做了什么，不写「更新若干文件」这类空话，末尾不加句号
- body 可选：仅在有多个要点或需说明动机时给，「- 」开头的中文短句，一行一条，最多 5 行
- pr_body 比 body 详细：解决什么问题、怎么做的、哪里值得复核；中文 markdown，
  可用「## 改动」「## 复核要点」等小标题与「- 」列表，25 行内；
  只写 diff 里看得出的事实，不编造测试结论或未做的工作
- diff 只给了 @@ 头与 +/- 变更行，未变的上下文行已删，据此推断即可
只输出 JSON：{"title": "...", "body": "...", "pr_body": "..."}，无内容的字段给空字符串。
'@
    $hint = if ($ScopeHints.Count) { "候选 scope（按改动文件推断，可参考也可自选）：$($ScopeHints -join ', ')`n`n" } else { '' }
    $usr = "$hint以下是本次要提交的改动：`n`n$DiffText"
    $r = Invoke-LlmChat -TimeoutSec $TimeoutSec -Messages @(
        @{ role = 'system'; content = $sys },
        @{ role = 'user';   content = $usr }
    )
    if ($r.Status -ne 200) {
        $detail = if ($r.Raw) { "$($r.Raw)".Substring(0, [Math]::Min(300, "$($r.Raw)".Length)) } else { '无响应' }
        throw "LLM 调用失败（HTTP $($r.Status)）：$detail"
    }
    $obj = ConvertFrom-LlmJson $r.Content
    if (-not $obj) { throw "LLM 返回无法解析为 JSON：$("$($r.Content)".Substring(0, [Math]::Min(200, "$($r.Content)".Length)))" }
    $title = "$(@("$($obj.title)" -split "`r?`n")[0])".Trim()
    if (-not $title) { throw 'LLM 未给出标题' }
    [pscustomobject]@{
        Title  = $title
        Body   = "$($obj.body)".Trim()
        PrBody = "$($obj.pr_body)".Trim()
    }
}

# ---------- 结果缓存 ----------
# 按次计费：同一批改动重跑脚本（勾选被取消、推送失败重来、先提交后开 PR）不该再付一次。
# 缓存键 = 送进模型的上下文 + 模型名的 SHA256；diff 一变、换模型就自然失效。
# 缓存落在 .git/ 下（由调用方传入路径），不进版本库。

function Get-LlmCommitCacheKey {
    param([Parameter(Mandatory)][string]$DiffText, [string]$Model = '')
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Model`n$DiffText")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# PS 5.1 的 ConvertFrom-Json 把 JSON 数组当「一个」对象送出管道，
# 直接 @(... | ConvertFrom-Json) 会得到「数组套数组」。先落到变量再展开。
function Read-LlmCacheStore([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        @($parsed | Where-Object { $_ })
    }
    catch { @() }
}

function Get-CachedLlmCommitMessage {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key)
    $hit = Read-LlmCacheStore $Path | Where-Object { "$($_.key)" -eq $Key } | Select-Object -First 1
    if (-not $hit) { return $null }
    $title = "$($hit.title)".Trim()
    if (-not $title) { return $null }
    [pscustomobject]@{
        Title     = $title
        Body      = "$($hit.body)".Trim()
        PrBody    = "$($hit.pr_body)".Trim()
        At        = "$($hit.at)"
    }
}

# 保留最近 10 条：够覆盖「改回上一版勾选」这类来回，也不会让文件无限长。
function Set-CachedLlmCommitMessage {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][object]$Result
    )
    $store = @(Read-LlmCacheStore $Path | Where-Object { "$($_.key)" -ne $Key })
    $entry = [pscustomobject]@{
        key        = $Key
        title      = "$($Result.Title)"
        body       = "$($Result.Body)"
        pr_body    = "$($Result.PrBody)"
        at         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $kept = @(@($entry) + $store | Select-Object -First 10)
    # 单条时 ConvertTo-Json 会输出对象而非数组，读回后同样能用（@() 归一）
    $json = $kept | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

