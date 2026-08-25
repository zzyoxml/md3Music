#Requires -Version 5.1
<#
.SYNOPSIS
  管理 GitHub Personal Access Token（开 PR / 自动合并用）。

.DESCRIPTION
  token 取用顺序：环境变量 GH_TOKEN / GITHUB_TOKEN → 本机保存 → 交互输入。
  本机保存走 Windows DPAPI 加密，落在 %LOCALAPPDATA%\md3music\github_token.dat，
  **不在仓库内**，换用户或换机器都解不开。

  不带参数运行进入交互界面（鼠标 + 键盘）：查看状态 / 设置 / 测试 / 删除。

.PARAMETER Show
  只打印当前 token 来源与状态。

.PARAMETER Set
  设置 token（交互输入，可选择永久保存或仅本次运行）。

.PARAMETER Test
  用当前 token 调 /user 验证是否可用。

.PARAMETER Remove
  删除本机保存的 token。

.EXAMPLE
  .\scripts\md3.ps1 token           # 交互管理
  .\scripts\md3.ps1 token -Show
  .\scripts\md3.ps1 token -Set
  .\scripts\md3.ps1 token -Test
  .\scripts\md3.ps1 token -Remove
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [switch]$Set,
    [switch]$Test,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Show-TokenStatus {
    Write-Step 'GitHub token 状态'
    $src = Get-GitHubTokenSource
    if ($src) {
        Write-Ok "已配置：$src"
        Write-Note "  保存路径：$(Get-TokenStorePath)"
    } else {
        Write-Warn '未配置 token（开 PR / 自动合并时会提示输入）'
        Write-Note "  可保存到：$(Get-TokenStorePath)"
    }
    Write-Note '  优先级：GH_TOKEN → GITHUB_TOKEN → 本机保存'
}

function Set-TokenInteractive {
    Write-Step '设置 GitHub token'
    if ($env:GH_TOKEN -or $env:GITHUB_TOKEN) {
        Write-Warn '当前环境变量里已有 token，它的优先级高于本机保存——保存后本次仍会用环境变量的那个。'
    }
    # 先清掉已保存的，让 Get-GitHubToken 走到交互输入分支
    [void](Remove-SavedGitHubToken)
    $saved = $env:GH_TOKEN
    $env:GH_TOKEN = ''
    try { $tok = Get-GitHubToken }
    finally { if ($saved) { $env:GH_TOKEN = $saved } }
    if (-not $tok) { Write-Warn '未设置'; return }
    Write-Step '验证 token'
    $r = Test-GitHubToken -Token $tok
    if ($r.Ok) { Write-Ok "可用：登录身份 $($r.Login)" }
    else { Write-Fail "不可用（$($r.Status)）：$($r.Message)" }
}

function Test-TokenNow {
    Write-Step '验证 GitHub token'
    $tok = Get-GitHubToken -NoPrompt
    if (-not $tok) { Write-Warn '未配置 token，无可验证对象'; return }
    [void](Enable-AutoProxy)
    $r = Test-GitHubToken -Token $tok
    if ($r.Ok) { Write-Ok "可用：登录身份 $($r.Login)（来源：$(Get-GitHubTokenSource)）" }
    else { Write-Fail "不可用（$($r.Status)）：$($r.Message)" }
}

function Remove-TokenNow {
    Write-Step '删除本机保存的 token'
    if (Remove-SavedGitHubToken) { Write-Ok "已删除 $(Get-TokenStorePath)" }
    else { Write-Warn '本机没有保存的 token' }
    if ($env:GH_TOKEN -or $env:GITHUB_TOKEN) {
        Write-Warn '注意：环境变量 GH_TOKEN / GITHUB_TOKEN 仍然存在，脚本会继续用它。'
    }
}

# 显式参数：直接执行对应动作
$explicit = $Show -or $Set -or $Test -or $Remove
if ($explicit) {
    if ($Show) { Show-TokenStatus }
    if ($Set) { Set-TokenInteractive }
    if ($Test) { Test-TokenNow }
    if ($Remove) { Remove-TokenNow }
    exit 0
}

# 无参数：交互界面
if (-not (Test-InteractiveConsole)) {
    Show-TokenStatus
    Write-Note '  非交互环境：请用 -Show / -Set / -Test / -Remove 指定动作。'
    exit 0
}

$mouse = Enable-ConsoleMouse
try {
    while ($true) {
        $src = Get-GitHubTokenSource
        $items = @(
            (New-MenuItem -Key 'set'    -Label '设置 token' -Desc '交互输入，可选永久保存或仅本次运行'),
            (New-MenuItem -Key 'test'   -Label '验证 token' -Desc '调 /user 检查是否可用' -Enabled ([bool]$src)),
            (New-MenuItem -Key 'remove' -Label '删除 token' -Desc '清掉本机保存的那份' -Enabled ([bool]$src)),
            (New-MenuItem -Key 'quit'   -Label '返回'       -Desc '退出 token 管理')
        )
        $footer = if ($src) { "当前：$src" } else { '当前：未配置 token' }
        $sel = Show-Menu -Items $items -Title 'MD3Music › token 管理' -Footer $footer
        if (-not $sel) { Clear-Host; break }
        $key = $items[$sel.Index].Key
        if ($key -eq 'quit') { Clear-Host; break }

        Disable-ConsoleMouse
        Clear-Host
        switch ($key) {
            'set'    { Set-TokenInteractive }
            'test'   { Test-TokenNow }
            'remove' { Remove-TokenNow }
        }
        [void](Enable-ConsoleMouse)
        Wait-AnyKey '按任意键 / 点击窗口返回…'
    }
}
finally { if ($mouse) { Disable-ConsoleMouse } }
exit 0
