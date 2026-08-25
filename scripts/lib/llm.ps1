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

  失败（无 key / 网络不通 / 返回异常 / 解析不出结果）一律返回 $null，
  调用方回退到按文件路径推断的候选信息，不影响提交本身。
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
  让模型按仓库惯例写提交信息。返回 [pscustomobject]@{ Title; Body }，任何失败返回 $null。
  $DiffText 由调用方裁剪好（含文件清单 + 统计 + 截断的 unified diff）。
#>
function New-LlmCommitMessage {
    param(
        [Parameter(Mandatory)][string]$DiffText,
        [string[]]$ScopeHints = @(),
        [int]$TimeoutSec = 60
    )
    $sys = @'
你是资深工程师，为 git 改动撰写 Conventional Commits 提交信息。仓库惯例：
- 标题格式 type(scope): 中文描述；type 取 feat/fix/docs/style/refactor/perf/test/chore/ci 之一
- scope 用英文小写，多个用 ", " 分隔，最多 3 个；与 type 同名时省略 scope
- 标题为一行，不超过 50 个汉字，描述改动做了什么，不写「更新若干文件」这类空话，句尾不加句号
- 正文可选：只在改动有多个要点或需要说明动机时给出，用「- 」开头的中文短句，每行一个要点，最多 5 行
只输出 JSON：{"title": "...", "body": "..."}；无正文时 body 为空字符串。不要输出任何其它内容。
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
    $body = "$($obj.body)".Trim()
    [pscustomobject]@{ Title = $title; Body = $body }
}
