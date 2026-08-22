# verify_public_clean.ps1 - Deny-list gate for the current repo's public tree.
#
# Scans lib/ (excluding lib/private) and pubspec.yaml for any download/cache
# feature symbols. Zero hits = the public export is safe. Use as a pre-push
# check or CI gate so a future commit that re-introduces a private symbol
# fails fast.
#
# Usage:
#   .\scripts\verify_public_clean.ps1        # exit 0 = clean, exit 1 = hit
param()
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

# Deny list lives in scripts/public_deny.txt (UTF-8, includes Chinese phrases).
$denyFile = Join-Path $PSScriptRoot 'public_deny.txt'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$denyLines = [System.IO.File]::ReadAllLines($denyFile, $utf8) |
    Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') }
$deny = ($denyLines | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|'

$libHits = @()
$libHits += Get-ChildItem (Join-Path $Root 'lib') -Recurse -Filter *.dart -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike '*\lib\private\*' } |
    Select-String -Pattern $deny -ErrorAction SilentlyContinue
$pubspecHits = @()
$pubspecHits += Select-String -Path (Join-Path $Root 'pubspec.yaml') -Pattern $deny -ErrorAction SilentlyContinue

if ($libHits.Count -gt 0) {
    Write-Host "Deny-list HIT in public lib/ tree (lib/ minus lib/private):"
    $libHits | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)  $($_.Line.Trim())" }
    Write-Host "Public export would leak private feature symbols. Fix before pushing."
    exit 1
}

if ($pubspecHits.Count -gt 0) {
    Write-Host "Note: pubspec.yaml still references the private package."
    Write-Host "  Expected in the private repo (dependency is stripped on export)."
}

Write-Host "Public lib/ tree clean: deny-list zero-hit."
exit 0
