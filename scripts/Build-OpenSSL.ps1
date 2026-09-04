#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds static OpenSSL with MSVC and installs it into a prefix directory.

.DESCRIPTION
    The Qt build links OpenSSL statically (-openssl-linked) so that the resulting
    Qt does not depend on libcrypto/libssl DLLs being deployed next to the app.

.PARAMETER Version
    OpenSSL version, e.g. 3.0.13. Upstream uses 3.0.13; any OpenSSL 3.x should work.

.PARAMETER Arch
    x64 or x86.

.PARAMETER Prefix
    Install prefix passed to CMake as OPENSSL_ROOT_DIR.

.EXAMPLE
    .\Build-OpenSSL.ps1 -Version 3.0.13 -Arch x64 -Prefix C:\qt-work\openssl
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('x64', 'x86')][string]$Arch = 'x64',
    [Parameter(Mandatory)][string]$Prefix,
    [string]$WorkDir
)

. "$PSScriptRoot/Common.ps1"

$start = Get-Date
Write-Step "Building OpenSSL $Version ($Arch, static)"

Initialize-MsvcEnvironment -Arch $Arch

$libDir = Join-Path $Prefix 'lib'
if ((Test-Path -LiteralPath $libDir) -and (Test-Path -LiteralPath (Join-Path $Prefix 'include'))) {
    Write-Ok "OpenSSL already installed at $Prefix, skipping"
    return
}

if (-not $WorkDir) { $WorkDir = Join-Path (Split-Path -Parent $Prefix) "openssl-build" }
$null = New-Item -ItemType Directory -Path $WorkDir -Force

$minor = ($Version -split '\.')[0..1] -join '.'
$archive = Join-Path $WorkDir "openssl-$Version.tar.gz"
$urls = @(
    "https://github.com/openssl/openssl/releases/download/openssl-$Version/openssl-$Version.tar.gz"
    "https://www.openssl.org/source/openssl-$Version.tar.gz"
    "https://www.openssl.org/source/old/$minor/openssl-$Version.tar.gz"
)

$null = Save-RemoteFile -Urls $urls -OutFile $archive

$extractDir = Join-Path $WorkDir "openssl-$Version"
if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'Configure'))) {
    Write-Step 'Extracting OpenSSL'
    Expand-ArchiveUniversal -Path $archive -Destination $extractDir
    # Most OpenSSL tarballs unpack into a single top level directory.
    $children = @(Get-ChildItem -LiteralPath $extractDir -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        $inner = $children[0].FullName
        Get-ChildItem -LiteralPath $inner -Force | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination $extractDir -Force
        }
        Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$target = if ($Arch -eq 'x64') { 'VC-WIN64A' } else { 'VC-WIN32' }

Write-Step "Configuring OpenSSL ($target)"
Invoke-External perl 'Configure' $target 'no-asm' 'no-shared' 'no-tests' 'no-docs' `
    "--prefix=$Prefix" "--openssldir=$Prefix\ssl" -WorkingDirectory $extractDir

Write-Step 'Compiling OpenSSL (single threaded nmake, expect 10-20 minutes)'
Invoke-External nmake -WorkingDirectory $extractDir

Write-Step 'Installing OpenSSL'
Invoke-External nmake 'install_sw' -WorkingDirectory $extractDir

if (-not (Test-Path -LiteralPath (Join-Path $Prefix 'lib'))) {
    throw "OpenSSL install did not produce $Prefix\lib"
}

Write-Ok "OpenSSL $Version installed to $Prefix ($(Get-Elapsed $start))"
Write-Info "disk: $(Get-DiskReport)"
# GitHub Actions runs each pwsh step as 'pwsh -command ". script"' and exits
# with the leftover $LASTEXITCODE. A clean completion must report 0.
Reset-LastExitCode
