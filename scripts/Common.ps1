#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Qt6 for Windows 7 builder - shared helpers.

.DESCRIPTION
    Dot-source this file from the other scripts in scripts/:

        . "$PSScriptRoot/Common.ps1"

    It sets strict-mode / error handling defaults and provides logging,
    external-process invocation and MSVC environment helpers.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Keeps GitHub Actions from killing long builds: print a heartbeat while a
# silent sub-process runs.
$script:HeartbeatStarted = $false

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> [$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Gray
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Note {
    param([string]$Message)
    Write-Host "    [!!] $Message" -ForegroundColor Yellow
}

function Get-Stamp {
    Get-Date -Format 'HH:mm:ss'
}

function Get-Elapsed {
    param([Parameter(Mandatory)][datetime]$Start)
    $span = (Get-Date) - $Start
    return '{0:00}h{1:00}m{2:00}s' -f $span.Hours, $span.Minutes, $span.Seconds
}

<#
.SYNOPSIS
    Runs a native executable, streams its output and fails on a bad exit code.
#>
function Invoke-External {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments,
        [string]$WorkingDirectory,
        [int[]]$AllowedExitCodes = @(0),
        [switch]$Quiet
    )

    $rendered = ($Arguments | ForEach-Object {
        if ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"{0}"' -f $_ } else { $_ }
    }) -join ' '

    if (-not $Quiet) { Write-Host "    $ $FilePath $rendered" -ForegroundColor DarkGray }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($WorkingDirectory) {
            $null = New-Item -ItemType Directory -Path $WorkingDirectory -Force -ErrorAction SilentlyContinue
            Push-Location -LiteralPath $WorkingDirectory
        }
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $code = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
        $ErrorActionPreference = $previous
    }

    if ($code -isnot [int]) { $code = 0 }

    if ($AllowedExitCodes -notcontains $code) {
        throw "Command failed (exit code $code): $FilePath $rendered"
    }
    return $code
}

<#
.SYNOPSIS
    Downloads a file with retries, trying a list of mirrors in order.
#>
function Save-RemoteFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$OutFile,
        [switch]$AllowFailure
    )

    $parent = Split-Path -Parent $OutFile
    if ($parent) { $null = New-Item -ItemType Directory -Path $parent -Force }

    foreach ($url in $Urls) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        Write-Info "downloading $url"
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & curl.exe -L --fail --retry 5 --retry-delay 3 --retry-all-errors -o $OutFile $url 2>&1 | ForEach-Object { Write-Host $_ }
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previous }

        if ($code -eq 0 -and (Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
            $size = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1)
            Write-Ok "saved $((Get-Item -LiteralPath $OutFile).Name) (${size} MB)"
            return $OutFile
        }
        Write-Note "mirror failed: $url"
    }

    if ($AllowFailure) { return $null }
    throw "Failed to download any of: $($Urls -join ', ')"
}

<#
.SYNOPSIS
    Extracts .tar.gz / .tar.xz / .zip / .7z, using bsdtar first and 7-Zip as fallback.
#>
function Expand-ArchiveUniversal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    $null = New-Item -ItemType Directory -Path $Destination -Force

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & tar.exe -xf $Path -C $Destination 2>&1 | ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }

    if ($code -eq 0) { Write-Ok "extracted with tar: $Path"; return }

    Write-Note "tar failed (code $code), falling back to 7z"
    $sevenZip = @('7z', '7z.exe', '7za.exe') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $sevenZip) { throw "Extraction failed and 7-Zip was not found in PATH" }

    if ($Path -match '\.(tar\.(gz|xz|bz2)|tgz)$') {
        $inner = Join-Path (Split-Path -Parent $Path) ([IO.Path]::GetFileNameWithoutExtension($Path))
        Invoke-External $sevenZip 'x' $Path "-o$(Split-Path -Parent $Path)" '-y' -Quiet
        Invoke-External $sevenZip 'x' $inner "-o$Destination" '-y' -Quiet
        Remove-Item -LiteralPath $inner -Force -ErrorAction SilentlyContinue
    }
    else {
        Invoke-External $sevenZip 'x' $Path "-o$Destination" '-y' -Quiet
    }
    Write-Ok "extracted with 7z: $Path"
}

<#
.SYNOPSIS
    Overlays a directory tree (robocopy based, tolerates long paths).
#>
function Copy-Overlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & robocopy.exe $Source $Destination /E /IS /IT /IM /NJH /NJS /NFL /NDL /NP 2>&1 | ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }

    # robocopy: 0..7 mean "files were copied / nothing to do", >= 8 is an error.
    if ($code -ge 8) { throw "robocopy failed (exit code $code) copying $Source -> $Destination" }
    return $code
}

<#
.SYNOPSIS
    Makes sure the MSVC command line environment is active in the current session.
#>
function Initialize-MsvcEnvironment {
    [CmdletBinding()]
    param(
        [ValidateSet('x64', 'x86')][string]$Arch = 'x64'
    )

    if (Get-Command 'cl.exe' -ErrorAction SilentlyContinue) {
        Write-Info "MSVC environment already active"
        return
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "vswhere.exe not found, cannot locate Visual Studio" }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if (-not $installPath) { throw "No Visual Studio installation with the C++ toolset was found" }

    $vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) { throw "vcvarsall.bat not found at $vcvars" }

    Write-Info "loading $vcvars ($Arch)"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        cmd /c "`"$vcvars`" $Arch && set" | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
        }
    }
    finally { $ErrorActionPreference = $previous }

    if (-not (Get-Command 'cl.exe' -ErrorAction SilentlyContinue)) { throw "Failed to initialize the MSVC environment" }
    Write-Ok "MSVC environment ready"
}

<#
.SYNOPSIS
    Appends a line to the GitHub Actions step summary (no-op outside Actions).
#>
function Add-Summary {
    param([string]$Markdown)
    if (-not $env:GITHUB_STEP_SUMMARY) { return }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Markdown -Encoding utf8
}

function Get-DiskReport {
    param([string]$Path = 'C:\')
    $drive = (Get-Item -LiteralPath $Path).PSDrive.Name
    $psd = Get-PSDrive -Name $drive
    return "{0}: {1:N1} GB free / {2:N1} GB used" -f $drive, ($psd.Free / 1GB), ($psd.Used / 1GB)
}
