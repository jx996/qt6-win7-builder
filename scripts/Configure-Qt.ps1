#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs Qt's configure.bat with the Windows 7 friendly settings.

.DESCRIPTION
    Computes the -skip list from a module preset, appends OpenSSL / FFmpeg
    locations, writes the final command line to configure-command.txt and
    records a short summary for GitHub Actions.

.EXAMPLE
    .\Configure-Qt.ps1 -SourceDir C:\qt-work\src -InstallDir C:\qt-work\install -Arch x64
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$InstallDir,
    [ValidateSet('x64', 'x86')][string]$Arch = 'x64',
    [string]$BuildDir = (Join-Path $SourceDir '_build'),
    [ValidateSet('release', 'debug', 'debug-and-release')][string]$BuildType = 'release',
    [ValidateSet('base', 'essential', 'all')][string]$ModulePreset = 'essential',
    [string[]]$ExtraModules = @(),
    [string[]]$SkipModules = @(),
    [ValidateSet('desktop', 'dynamic')][string]$Opengl = 'desktop',
    [ValidateSet('static', 'none')][string]$OpensslMode = 'static',
    [string]$OpensslPrefix,
    [string]$FfmpegDir,
    [string[]]$ExtraCMakeArgs = @()
)

. "$PSScriptRoot/Common.ps1"

$start = Get-Date
Write-Step "Configuring Qt ($Arch / $BuildType / modules: $ModulePreset)"

Initialize-MsvcEnvironment -Arch $Arch

# ---------------------------------------------------------------- module set
$allModules = @(
    Get-ChildItem -LiteralPath $SourceDir -Directory -Filter 'qt*' |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'CMakeLists.txt') } |
        Select-Object -ExpandProperty Name
)
if ($allModules.Count -eq 0) { throw "No Qt modules found under $SourceDir - is this a qt-everywhere source tree?" }
Write-Info ("detected modules: " + (($allModules | Sort-Object) -join ', '))

$keep = switch ($ModulePreset) {
    'base' { @('qtbase') }
    'essential' { @('qtbase', 'qtshadertools', 'qtdeclarative', 'qtsvg', 'qttools', 'qtimageformats', 'qt5compat') }
    'all' { $allModules }
    default { throw "Unknown preset '$ModulePreset'" }
}

# Modules that are never part of the main configure run:
#  - qtwayland is Linux only
#  - qtwebengine is compiled in a second pass with qt-configure-module.bat
#  - qtmultimedia: since Qt 6.8 the FFmpeg backend is the only one left on Windows,
#    so configure hard-fails without an FFmpeg prefix. Skip it unless one was given.
$forcedSkip = @('qtwayland', 'qtwebengine')
if (-not $FfmpegDir) { $forcedSkip += 'qtmultimedia' }

# Note the order matters: strips from $keep first, so forced skips always win even
# when the preset is 'all' (which starts out keeping every detected module).
$keep = @($keep) + @($ExtraModules | Where-Object { $_ })
$keep = @($keep |
    Where-Object { ($forcedSkip -notcontains $_) -and ($SkipModules -notcontains $_) } |
    Select-Object -Unique)

$skip = @($allModules | Where-Object { $keep -notcontains $_ } | Select-Object -Unique)

Write-Info ("modules kept  : " + (($keep | Sort-Object) -join ', '))
Write-Info ("modules skipped: " + (($skip | Sort-Object) -join ', '))
Write-Info ("forced skip   : " + ($forcedSkip -join ', '))

# ---------------------------------------------------------------- configure
$args = @(
    '-prefix', $InstallDir
    '-opensource'
    '-confirm-license'
    "-opengl", $Opengl
    "-$BuildType"
    '-nomake', 'tests'
    '-nomake', 'examples'
)
foreach ($m in ($skip | Sort-Object)) { $args += @('-skip', $m) }

if ($OpensslMode -eq 'static') {
    if (-not $OpensslPrefix) { throw "OpensslMode 'static' requires -OpensslPrefix" }
    if (-not (Test-Path -LiteralPath (Join-Path $OpensslPrefix 'include'))) {
        throw "OpenSSL prefix '$OpensslPrefix' does not look like an OpenSSL install (no include dir)"
    }
    Write-Info "static OpenSSL: $OpensslPrefix"
    # Qt's OpenSSL probe needs the classic Windows system libs as well.
    $env:OPENSSL_LIBS = '-lUser32 -lAdvapi32 -lGdi32 -llibcrypto -llibssl'
    $args += @('-openssl-linked')
    $args += @('--')
    $args += @("-DOPENSSL_ROOT_DIR=$OpensslPrefix")
    $args += @("-DOPENSSL_INCLUDE_DIR=$OpensslPrefix\include")
    $args += @('-DOPENSSL_USE_STATIC_LIBS=ON')
}
elseif ($ExtraCMakeArgs.Count) {
    $args += @('--')
}

if ($FfmpegDir) {
    if ($args -notcontains '--') { $args += @('--') }
    $args += @("-DFFMPEG_DIR=$FfmpegDir")
    Write-Info "FFmpeg prefix: $FfmpegDir"
}

foreach ($a in ($ExtraCMakeArgs | Where-Object { $_ })) {
    if ($args -notcontains '--') { $args += @('--') }
    $args += @($a)
}

$configureExe = Join-Path (Split-Path -Parent $BuildDir) 'configure.bat'
if (-not (Test-Path -LiteralPath $configureExe)) { throw "configure.bat not found next to $BuildDir" }

$rendered = "..\configure.bat " + (($args | ForEach-Object {
    if ($_ -match '\s' -and $_ -notmatch '^-') { '"{0}"' -f $_ } else { $_ }
}) -join ' ')
$cmdFile = Join-Path (Split-Path -Parent $SourceDir) 'configure-command.txt'
Set-Content -LiteralPath $cmdFile -Value $rendered -Encoding utf8
Write-Info "full command saved to $cmdFile"
Write-Info $rendered

$null = New-Item -ItemType Directory -Path $BuildDir -Force
Write-Step 'Running configure (this produces the feature summary)'
Invoke-External (Resolve-Path -LiteralPath $configureExe).Path @args -WorkingDirectory $BuildDir

Write-Ok "Qt configured ($(Get-Elapsed $start))"
Write-Info "disk: $(Get-DiskReport)"

Add-Summary ''
Add-Summary "### Qt configure"
Add-Summary ''
Add-Summary '```bat'
Add-Summary $rendered
Add-Summary '```'
