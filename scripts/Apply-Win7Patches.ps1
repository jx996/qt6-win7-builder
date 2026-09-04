#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Overlays the crystalidea/qt6windows7 Windows 7 backport files onto a Qt source tree.

.DESCRIPTION
    The upstream project ships *replacement copies* of the files it backports
    (not .patch diffs), so the whole job is "copy the folder over the source tree".
    Only modules that exist in both the patch repo and the source tree are touched.

.PARAMETER SourceDir
    Root of the unpacked Qt source tree (contains qtbase/, qtmultimedia/, ...).

.PARAMETER PatchRepo
    Git URL of the patch repository.

.PARAMETER PatchRef
    Branch / tag / commit to check out. Pin this to a commit for reproducible builds.

.PARAMETER WorkDir
    Scratch directory for the clone.

.PARAMETER Modules
    Which patch repo sub-trees to overlay. Default: qtbase + the modules present
    in the source tree (qtmultimedia, qtwebengine).

.PARAMETER ProvenanceFile
    JSON file receiving patch provenance (repo / ref / sha / file list).

.EXAMPLE
    .\Apply-Win7Patches.ps1 -SourceDir C:\qt-work\src -PatchRef master
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [string]$PatchRepo = 'https://github.com/crystalidea/qt6windows7',
    [string]$PatchRef = 'master',
    [string]$WorkDir,
    [string[]]$Modules = @('qtbase', 'qtmultimedia', 'qtwebengine'),
    [string]$ProvenanceFile
)

. "$PSScriptRoot/Common.ps1"

$start = Get-Date
Write-Step "Applying Windows 7 backport patches ($PatchRepo @ $PatchRef)"

if (-not (Test-Path -LiteralPath $SourceDir)) { throw "Source dir not found: $SourceDir" }
if (-not $WorkDir) { $WorkDir = Join-Path (Split-Path -Parent $SourceDir) 'patches' }
$patchDir = Join-Path $WorkDir 'qt6windows7'

if (Test-Path -LiteralPath (Join-Path $patchDir '.git')) {
    Write-Info "refreshing existing clone in $patchDir"
    Invoke-External git -C $patchDir fetch --all --tags --prune -Quiet
}
else {
    Remove-Item -LiteralPath $patchDir -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $WorkDir -Force
    Write-Info "cloning $PatchRepo"
    Invoke-External git clone $PatchRepo $patchDir -Quiet
}

Invoke-External git -C $patchDir checkout $PatchRef -Quiet

$sha = (& git -C $patchDir rev-parse HEAD).Trim()
$commitDate = (& git -C $patchDir log -1 --format=%cI).Trim()
$subject = (& git -C $patchDir log -1 --format=%s).Trim()
Write-Ok "patch repo at $sha ($commitDate) - $subject"

$copied = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($module in $Modules) {
    $patchModule = Join-Path $patchDir $module
    $srcModule = Join-Path $SourceDir $module

    if (-not (Test-Path -LiteralPath $patchModule)) { $skipped.Add("$module (not in patch repo)"); continue }
    if (-not (Test-Path -LiteralPath $srcModule)) { $skipped.Add("$module (not in Qt source)"); continue }

    # Record every file we are about to overwrite so the manifest is accurate.
    $files = Get-ChildItem -LiteralPath $patchModule -Recurse -File | ForEach-Object {
        $_.FullName.Substring($patchDir.Length + 1).Replace('\', '/')
    }
    $files | ForEach-Object { $copied.Add($_) }

    Write-Info "overlaying $module ($($files.Count) files)"
    Copy-Overlay -Source $patchModule -Destination $srcModule
}

if (-not $ProvenanceFile) { $ProvenanceFile = Join-Path (Split-Path -Parent $SourceDir) 'win7-patches.json' }

$manifest = [ordered]@{
    repository = $PatchRepo
    ref        = $PatchRef
    commit     = $sha
    date       = $commitDate
    subject    = $subject
    appliedAt  = (Get-Date).ToUniversalTime().ToString('o')
    files      = @($copied | Sort-Object)
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ProvenanceFile -Encoding utf8

Write-Ok "patched $($copied.Count) files ($(Get-Elapsed $start))"
if ($skipped.Count) {
    foreach ($s in $skipped) { Write-Info "skipped $s" }
}
Write-Info "provenance: $ProvenanceFile"

Add-Summary ''
Add-Summary "### Windows 7 backport patches"
Add-Summary ''
Add-Summary "| Item | Value |"
Add-Summary "|---|---|"
Add-Summary "| Repository | [$PatchRepo]($PatchRepo) |"
Add-Summary "| Ref | ``$PatchRef`` |"
Add-Summary "| Commit | ``$sha`` |"
Add-Summary "| Files applied | $($copied.Count) |"
Add-Summary "| Modules skipped | $($skipped -join ', ') |"
# GitHub Actions runs each pwsh step as 'pwsh -command ". script"' and exits
# with the leftover $LASTEXITCODE. A clean completion must report 0.
Reset-LastExitCode
