#Requires -Version 5.1
<#
.SYNOPSIS
  一键发布：空树消息历史 + 全量公开树快照，一次推送到公开仓库（默认覆盖目标分支）。

.DESCRIPTION
  等价于 export -ForcePush -WithHistory 的便捷入口，并给出默认目标：
    - 空树消息历史：把私有仓库提交记录重建为「空树提交」（消息完整、diff 全空），备份保存在
      项目 tmp\ 下（<项目根>\tmp\md3music-public-messages-<时间戳>），增量优先：目标分支上次
      导出的 .md3/export-state 映射存在且早期历史未改写时，只追加新提交并 fast-forward（免 force）；
      否则全量重建 + force。
    - 全量公开树快照：白名单拷贝 + 排除私有内容 + 剥离私有依赖 + 否认清单闸门，输出完整公开树，
      叠加在空树历史顶端，一并推送（默认 .public_export；可 -OutDir 指定）。
  不填 -PublicRemote / -PublicBranch 时默认：
    - 仓库：https://github.com/zzyoxml/md3Music
    - 分支：rust-local-force

.PARAMETER PublicRemote
  公开仓库 URL（默认 https://github.com/zzyoxml/md3Music）。

.PARAMETER PublicBranch
  公开仓库目标分支（默认 rust-local-force）。

.PARAMETER OutDir
  公开树快照目录（默认交给 export_public 的 .public_export，已 .gitignore 排除）。

.PARAMETER ForceFullHistory
  强制走「全量重建 + force push」，跳过增量探测（增量基线失效、add 报 unable to read 时使用）。

.PARAMETER NoPause
  结束时不等待按键（CI/被其他脚本调用时使用）。

.EXAMPLE
  .\scripts\md3.ps1 full-export                              # 默认目标仓库/分支一键发布
  .\scripts\md3.ps1 full-export -PublicBranch main           # 覆盖默认分支
  .\scripts\md3.ps1 full-export -OutDir tmp\pub -NoPause     # 指定快照目录 + 非交互
  .\scripts\md3.ps1 full-export -ForceFullHistory            # 增量基线失效时强制全量重建覆盖
#>
[CmdletBinding()]
param(
    [string]$PublicRemote = 'https://github.com/zzyoxml/md3Music',
    [string]$PublicBranch = 'rust-local-force',
    [string]$OutDir = '',
    [switch]$ForceFullHistory,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Root = Get-RepoRoot

try {
    Write-Step "一键发布：空树消息历史 + 全量公开树快照 → $PublicRemote（分支 $PublicBranch）"
    $exportArgs = @{
        PublicRemote = $PublicRemote
        PublicBranch = $PublicBranch
        ForcePush    = $true
        WithHistory  = $true
        NoPause      = $true
    }
    if ($ForceFullHistory) { $exportArgs.ForceFullHistory = $true }
    if ($OutDir) { $exportArgs.OutDir = $OutDir }
    & (Join-Path $PSScriptRoot 'export_public.ps1') @exportArgs
    if ($LASTEXITCODE -ne 0) { throw "导出/发布失败（退出码 $LASTEXITCODE）" }
    Write-Ok '一键发布完成：全量公开树快照已携带空树消息历史推送到公开仓库'
}
catch {
    Write-Host "`n[ERROR] 一键发布失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $NoPause) { Wait-Exit }
exit 0