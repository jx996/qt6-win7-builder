#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Downloads and unpacks the Qt "everywhere" source tree for the requested version.

.PARAMETER Version
    Qt version to fetch, e.g. 6.8.4.

.PARAMETER Destination
    Directory that will receive the source tree root (contains configure.bat, qtbase/, ...).

.PARAMETER CacheRoot
    Where the downloaded archive is kept (useful for local reruns).

.PARAMETER ArchiveUrl
    Optional direct URL override (skips mirror probing).

.EXAMPLE
    .\Fetch-QtSource.ps1 -Version 6.8.4 -Destination C:\qt-work\src
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Destination,
    [string]$CacheRoot,
    [string]$ArchiveUrl,
    [switch]$KeepArchive
)

. "$PSScriptRoot/Common.ps1"

$start = Get-Date
Write-Step "Fetching Qt $Version source"

if (-not ($Version -match '^(\d+)\.(\d+)')) { throw "'$Version' does not look like a Qt version (expected e.g. 6.8.4)" }
$minor = '{0}.{1}' -f $Matches[1], $Matches[2]

if (-not $CacheRoot) { $CacheRoot = Join-Path ([IO.Path]::GetTempPath()) 'qt6-win7-downloads' }

$mirrorRoots = @(
    'https://download.qt.io'
    'https://mirrors.ustc.edu.cn/qtproject'
    'https://mirrors.tuna.tsinghua.edu.cn/qt'
    'https://mirror.sjtu.edu.cn/qt'
    'https://mirrors.cloud.tencent.com/qt'
    'https://mirrors.aliyun.com/qt'
    'https://qt-mirror.dannhauer.de'
    'https://mirrors.ocf.berkeley.edu/qt'
)

$relNames = @(
    "official_releases/qt/$minor/$Version/single/qt-everywhere-opensource-src-$Version.tar.xz"
    "official_releases/qt/$minor/$Version/single/qt-everywhere-src-$Version.tar.xz"
    "official_releases/qt/$minor/$Version/single/qt-everywhere-opensource-src-$Version.zip"
)

if ($ArchiveUrl) {
    $urls = @($ArchiveUrl)
    $archiveName = [IO.Path]::GetFileName(($ArchiveUrl -split '\?')[0])
}
else {
    # Put the official host first for every candidate filename, then the mirrors.
    $urls = @()
    foreach ($rel in $relNames) {
        foreach ($root in $mirrorRoots) { $urls += "$root/$rel" }
    }
    $archiveName = "qt-everywhere-opensource-src-$Version.tar.xz"
}

$archive = Join-Path $CacheRoot $archiveName
Write-Info "disk: $(Get-DiskReport)"
Write-Info "target source dir: $Destination"

if (Test-Path -LiteralPath (Join-Path $Destination 'configure.bat')) {
    Write-Ok "source already present at $Destination, skipping download"
    return
}

$null = Save-RemoteFile -Urls $urls -OutFile $archive

Write-Step "Extracting $([IO.Path]::GetFileName($archive))"
$extractRoot = Join-Path $CacheRoot "extract-$Version"
Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
Expand-ArchiveUniversal -Path $archive -Destination $extractRoot

$children = @(Get-ChildItem -LiteralPath $extractRoot -Force)
if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
    $inner = $children[0].FullName
}
else {
    $inner = $extractRoot
}

Write-Info "source root: $inner"
$null = New-Item -ItemType Directory -Path $Destination -Force
Copy-Overlay -Source $inner -Destination $Destination

if (-not (Test-Path -LiteralPath (Join-Path $Destination 'configure.bat'))) {
    throw "configure.bat not found after extraction - unexpected archive layout"
}

Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue

if (-not $KeepArchive) {
    # The archive alone is ~1 GB and the extracted tree is already on disk.
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Write-Info "removed $archive to reclaim disk space"
}

$modules = Get-ChildItem -LiteralPath $Destination -Directory -Filter 'qt*' |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'CMakeLists.txt') } |
    Select-Object -ExpandProperty Name

Write-Ok "Qt $Version source ready at $Destination ($(Get-Elapsed $start))"
Write-Info ("modules found: " + (($modules | Sort-Object) -join ', '))
Write-Info "disk: $(Get-DiskReport)"
