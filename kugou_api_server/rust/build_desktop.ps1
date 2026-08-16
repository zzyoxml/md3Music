#Requires -Version 5.1
<#
.SYNOPSIS
  构建 Windows 桌面版 kugou_server（kugou_server.dll）。

.DESCRIPTION
  本机未装 MSVC，用 GNU toolchain + MinGW 作为 host 编译器。
  产物：target\release\kugou_server.dll
  可选 -OutDir：构建后把 dll 复制到指定目录（例如打包目录）。

.EXAMPLE
  .\build_desktop.ps1
  .\build_desktop.ps1 -OutDir 'C:\dist'
#>
param(
    [string]$OutDir = ""
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot   # rust/..
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
$Toolchain = 'stable-x86_64-pc-windows-gnu'
$HostGcc = 'C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\gcc.exe'
$HostAr  = 'C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\ar.exe'

$env:Path = "$CargoBin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw '未找到 cargo，请先安装 rustup' }
if (-not (Test-Path $HostGcc)) { throw "host gcc 缺失（build-script 需要）：$HostGcc" }

Push-Location $PSScriptRoot
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $env:CC_x86_64_pc_windows_gnu = $HostGcc
        $env:AR_x86_64_pc_windows_gnu = $HostAr
        & cargo "+$Toolchain" build --release
        if ($LASTEXITCODE -ne 0) { throw "cargo build 失败，退出码 $LASTEXITCODE" }
    }
    finally { $ErrorActionPreference = $prevEAP }

    $dll = Join-Path $PSScriptRoot 'target\release\kugou_server.dll'
    if (-not (Test-Path $dll)) { throw "dll 未生成：$dll" }
    Write-Host "Built: $dll ($([math]::Round((Get-Item $dll).Length / 1MB, 1)) MB)" -ForegroundColor Green
    if ($OutDir) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        Copy-Item $dll $OutDir -Force
        Write-Host "Copied to: $OutDir" -ForegroundColor Green
    }
}
finally { Pop-Location }