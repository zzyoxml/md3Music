#Requires -Version 5.1
<#
.SYNOPSIS
  否认清单闸门：自检当前（私有）仓库的公开面是否已剥离私有符号。

.DESCRIPTION
  扫描 lib/（排除 lib/private/）与 pubspec.yaml，匹配 scripts/public_deny.txt 里的
  下载/缓存功能符号与短语。lib/ 零命中 = 导出后的公开树安全。
  可作为 pre-push 检查或 CI 闸门，让重新引入私有符号的提交尽早失败。

  pubspec.yaml 命中在私有仓库属预期（私有依赖在导出时才剥离），只提示不失败。

.PARAMETER Quiet
  只输出结论行，不打印 deny 清单规模。

.EXAMPLE
  .\scripts\md3.ps1 verify      # exit 0 = 干净，exit 1 = 命中
#>
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$root = Get-RepoRoot
$gate = Invoke-DenyGate -TreeRoot $root -SkipPrivateDir
if (-not $Quiet) { Write-Note "deny 清单：$($gate.DenyCount) 条符号/短语" }

if ($gate.LibHits.Count -gt 0) {
    Write-Fail "公开面命中私有符号（lib/ 去掉 lib/private 后）$($gate.LibHits.Count) 处："
    Write-DenyHits -Hits $gate.LibHits
    Write-Host '导出后的公开树会泄漏私有功能符号，推送前请先修正。' -ForegroundColor Red
    exit 1
}

if ($gate.PubspecHits.Count -gt 0) {
    Write-Note "pubspec.yaml 仍引用私有包（$($gate.PubspecHits.Count) 处）——私有仓库中属预期，导出时剥离。"
}

Write-Ok '公开面干净：deny 清单零命中。'
exit 0
