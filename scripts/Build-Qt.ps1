#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds and installs the configured Qt tree.

.DESCRIPTION
    Runs "cmake --build", installs every requested configuration and optionally
    compiles extra modules (QtPdf / QtWebEngine) in a second pass with
    qt-configure-module.bat, exactly like the upstream crystalidea perl scripts do.

.EXAMPLE
    .\Build-Qt.ps1 -SourceDir C:\qt-work\src -InstallDir C:\qt-work\install -BuildType release
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$InstallDir,
    [string]$BuildDir = (Join-Path $SourceDir '_build'),
    [ValidateSet('release', 'debug', 'debug-and-release')][string]$BuildType = 'release',
    [ValidateSet('x64', 'x86')][string]$Arch = 'x64',
    [switch]$BuildWebEngine,
    [switch]$CleanBuildDir
)

. "$PSScriptRoot/Common.ps1"

$start = Get-Date
Write-Step "Building Qt ($Arch / $BuildType)"

Initialize-MsvcEnvironment -Arch $Arch

$configs = switch ($BuildType) {
    'release' { @('Release') }
    'debug' { @('Debug') }
    'debug-and-release' { @('Release', 'Debug') }
}

$cores = [Environment]::ProcessorCount
Write-Info "parallel jobs: $cores"
Write-Info "disk: $(Get-DiskReport -Path $BuildDir)"

Invoke-External cmake '--build' '.' '--parallel' -WorkingDirectory $BuildDir

foreach ($cfg in $configs) {
    Write-Step "Installing $cfg"
    Invoke-External cmake '--install' '.' '--config' $cfg -WorkingDirectory $BuildDir
}

if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'bin'))) {
    throw "Install did not produce $InstallDir\bin"
}
Write-Ok "Qt installed ($(Get-Elapsed $start))"
Write-Info "disk: $(Get-DiskReport -Path $BuildDir)"

if ($CleanBuildDir) {
    Write-Step 'Removing the build directory to reclaim disk space'
    Remove-Item -LiteralPath $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info "disk: $(Get-DiskReport -Path $BuildDir)"
}

# ------------------------------------------------------- QtWebEngine / QtPdf
if ($BuildWebEngine) {
    $module = Join-Path $SourceDir 'qtwebengine'
    if (-not (Test-Path -LiteralPath $module)) { throw "qtwebengine not found in $SourceDir" }

    $chromium = Join-Path $module 'src/3rdparty/chromium'
    if (-not (Test-Path -LiteralPath ($chromium -replace '/', '\'))) {
        throw @"
qtwebengine/src/3rdparty/chromium is missing from the source archive.
The 'single' source archive normally ships the Chromium snapshot; if your mirror
stripped it, build from a git checkout instead (init-repository --module-subset=qtwebengine).
"@
    }

    Write-Step 'Building QtWebEngine + QtPdf (second pass)'
    Write-Note 'This needs python + html5lib + node.js and tens of GB of disk; use a self-hosted runner.'

    $qtConfModule = Join-Path $InstallDir 'bin/qt-configure-module.bat'
    if (-not (Test-Path -LiteralPath $qtConfModule)) { throw "qt-configure-module.bat not found in $InstallDir\bin" }

    $weBuild = Join-Path $SourceDir '_build-qtwebengine'
    Remove-Item -LiteralPath $weBuild -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $weBuild -Force

    Invoke-External $qtConfModule $module -WorkingDirectory $weBuild
    Invoke-External cmake '--build' '.' '--parallel' -WorkingDirectory $weBuild
    foreach ($cfg in $configs) {
        Invoke-External cmake '--install' '.' '--config' $cfg -WorkingDirectory $weBuild
    }
    Write-Ok "QtWebEngine installed ($(Get-Elapsed $start))"
}

Write-Ok "Build finished in $(Get-Elapsed $start)"
# GitHub Actions runs each pwsh step as 'pwsh -command ". script"' and exits
# with the leftover $LASTEXITCODE. A clean completion must report 0.
Reset-LastExitCode
