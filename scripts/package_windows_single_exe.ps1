param(
    [string]$BundlePath = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\build\windows\md3music-windows.exe')
)

$ErrorActionPreference = 'Stop'

$bundle = (Resolve-Path -LiteralPath $BundlePath).Path
$app = Join-Path $bundle 'md3music.exe'
if (-not (Test-Path -LiteralPath $app -PathType Leaf)) {
    throw "Flutter Windows Release bundle not found: $app"
}

$iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
if (-not (Test-Path -LiteralPath $iexpress -PathType Leaf)) {
    throw 'IExpress is required and was not found in the Windows system directory.'
}

$output = [IO.Path]::GetFullPath($OutputPath)
$outputDir = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$work = Join-Path ([IO.Path]::GetTempPath()) ('md3music-iexpress-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $payload = Join-Path $work 'payload.zip'
    $launchScript = Join-Path $work 'launch.ps1'
    $sed = Join-Path $work 'md3music.sed'
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $payload -CompressionLevel Optimal

    @'
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDirectory = Join-Path $env:TEMP ('md3music-' + [Guid]::NewGuid().ToString('N'))
$exitCode = 1

try {
    Expand-Archive -LiteralPath (Join-Path $root 'payload.zip') -DestinationPath $appDirectory -Force
    $app = Join-Path $appDirectory 'md3music.exe'
    $process = Start-Process -FilePath $app -WorkingDirectory $appDirectory -Wait -PassThru
    $exitCode = $process.ExitCode
}
finally {
    if (Test-Path -LiteralPath $appDirectory) {
        Remove-Item -LiteralPath $appDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
'@ | Set-Content -LiteralPath $launchScript -Encoding ASCII

    $sourceDirectory = $work.TrimEnd('\') + '\'
    @"
[Version]
Class=IEXPRESS
SEDVersion=3

[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles

[SourceFiles]
SourceFiles0=$sourceDirectory

[SourceFiles0]
%FILE0%=
%FILE1%=

[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName="$output"
FriendlyName="MD3Music Windows"
AppLaunched=powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File launch.ps1
PostInstallCmd=<None>
FILE0="launch.ps1"
FILE1="payload.zip"
"@ | Set-Content -LiteralPath $sed -Encoding ASCII

    $process = Start-Process -FilePath $iexpress -ArgumentList '/N', '/Q', $sed -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "IExpress failed with exit code $($process.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "IExpress did not create the output file: $output"
    }
    Get-Item -LiteralPath $output
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
