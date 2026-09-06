#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Packs a built Qt install into "Qt-<version>-msvc2022-Windows7<x64|x86>-shared-Release.7z"
    plus a SHA-256 file, and exports the artifact coordinates to $GITHUB_OUTPUT.

.DESCRIPTION
    The archive contains the install tree at its root (bin/, lib/, plugins/,
    include/, mkspecs/, ...), so extracting it into e.g. C:\Qt\6.8.4-win7 gives
    you a drop-in Qt prefix. Qt is built as shared (dynamic) libraries.

.EXAMPLE
    .\Package-Qt.ps1 -InstallDir C:\qt-work\install -Version 6.8.4 -Arch x64 -OutDir C:\qt-work\dist
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('x64', 'x86')][string]$Arch = 'x64',
    [Parameter(Mandatory)][string]$OutDir,
    [int]$CompressionLevel = 1,
    [string]$InfoFile
)

. "$PSScriptRoot/Common.ps1"

$start = Get-Date
Write-Step 'Packaging the Qt install'

if (-not (Test-Path -LiteralPath $InstallDir)) { throw "Install dir not found: $InstallDir" }
$null = New-Item -ItemType Directory -Path $OutDir -Force

$plat = if ($Arch -eq 'x64') { 'x64' } else { $Arch }
$name = "Qt-${Version}-msvc2022-Windows7${plat}-shared-Release.7z"
$outFile = Join-Path $OutDir $name

if ($InfoFile -and (Test-Path -LiteralPath $InfoFile)) {
    Copy-Item -LiteralPath $InfoFile -Destination (Join-Path $InstallDir 'BUILDINFO.txt') -Force
    Write-Info 'embedded BUILDINFO.txt'
}

Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue

$sevenZipCmd = @('7z', '7z.exe', '7za.exe') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
$sevenZip = if ($sevenZipCmd) { $sevenZipCmd.Source } else { $null }
if (-not $sevenZip) {
    # Installed but not on PATH (the "Ensure 7-Zip" workflow step covers this too).
    $sevenZip = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $sevenZip) { throw "7-Zip (7z) not found in PATH or the standard install locations; cannot create the .7z package" }

Write-Info "creating $name (7z, compression level $CompressionLevel)"
# Package the install tree at the archive root, so extraction drops bin/ lib/ ...
# directly into the target prefix. -mx1 keeps packaging fast; -mmt uses all cores.
Push-Location -LiteralPath $InstallDir
try {
    & $sevenZip 'a' '-t7z' "-mx$CompressionLevel" '-mmt' $outFile '.' 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
}
finally { Pop-Location }

# 7-Zip exit codes: 0 = ok, 1 = warning (non fatal, archive was still written),
# 2 = fatal error, 7 = command line error, 8 = out of memory, 255 = user stop.
# Do NOT treat 1 as failure - that is the same class of bug as robocopy's 1..7.
if ($code -ge 2) { throw "7z failed (exit code $code) creating $outFile" }
if ($code -eq 1) { Write-Note "7z returned 1 (warning, non fatal) - archive should still be valid" }
Reset-LastExitCode

if (-not (Test-Path -LiteralPath $outFile)) { throw "Packaging failed: $outFile was not created" }

$size = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1MB, 1)
Write-Ok "archive: $outFile (${size} MB)"

$hash = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash.ToLowerInvariant()
$hashFile = "$outFile.sha256"
Set-Content -LiteralPath $hashFile -Value "$hash  $name" -Encoding ascii
Write-Info "sha256: $hash"

if ($env:GITHUB_OUTPUT) {
    @(
        "artifact-name=$name"
        "artifact-path=$outFile"
        "artifact-sha256=$hash"
    ) | ForEach-Object { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value $_ }
}

Add-Summary ''
Add-Summary '### Package'
Add-Summary ''
Add-Summary "| Item | Value |"
Add-Summary "|---|---|"
Add-Summary "| File | ``$name`` |"
Add-Summary "| Size | ${size} MB |"
Add-Summary "| SHA-256 | ``$hash`` |"

Write-Ok "Packaging finished ($(Get-Elapsed $start))"

# GitHub Actions runs each pwsh step as 'pwsh -command ". script"' and exits
# with the leftover $LASTEXITCODE. A clean completion must report 0.
Reset-LastExitCode
