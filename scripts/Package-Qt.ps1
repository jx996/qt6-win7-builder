#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Packs a built Qt install into "<version>_Windows7.tar.gz" plus a SHA-256 file.

.DESCRIPTION
    The archive contains the install tree at its root (bin/, lib/, plugins/,
    include/, mkspecs/, ...), so extracting it into e.g. C:\Qt\6.8.4-win7 gives
    you a drop-in Qt prefix.

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

$suffix = if ($Arch -eq 'x64') { '' } else { "_$Arch" }
$name = "${Version}_Windows7${suffix}.tar.gz"
$outFile = Join-Path $OutDir $name

if ($InfoFile -and (Test-Path -LiteralPath $InfoFile)) {
    Copy-Item -LiteralPath $InfoFile -Destination (Join-Path $InstallDir 'BUILDINFO.txt') -Force
    Write-Info 'embedded BUILDINFO.txt'
}

Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue

Write-Info "creating $name (gzip level $CompressionLevel)"
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & tar.exe --options "gzip:compression-level=$CompressionLevel" -czf $outFile -C $InstallDir . 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
}
finally { $ErrorActionPreference = $previous }

if ($code -ne 0) {
    Write-Note "tar with a compression hint failed (code $code), retrying with defaults"
    Invoke-External tar.exe '-czf' $outFile '-C' $InstallDir '.' -Quiet
}

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
