#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates a built Qt install: smoke-builds a widget app and audits the PE
    import tables for Windows 8/10/11 only dependencies.

.DESCRIPTION
    A real Windows 7 runtime test is impossible on GitHub-hosted runners (they are
    Server 2019/2022/2025), so this script does the next best thing:

      1. compiles tests/hello against the freshly built Qt,
      2. walks the import table of every shipped .dll/.exe and reports any
         API-set DLL that does not exist on Windows 7.

    A clean report is a strong signal; a hit does not necessarily mean a crash
    (it may be a delay-loaded reference), so findings are warnings, not errors.

.EXAMPLE
    .\Test-Artifacts.ps1 -InstallDir C:\qt-work\install -Arch x64 -Strict
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [ValidateSet('x64', 'x86')][string]$Arch = 'x64',
    [string]$TestProject = (Join-Path $PSScriptRoot '..\tests\hello'),
    [switch]$SkipSmokeTest,
    [switch]$Strict
)

. "$PSScriptRoot/Common.ps1"

$start = Get-Date
Write-Step 'Validating the Qt install'

Initialize-MsvcEnvironment -Arch $Arch

# ------------------------------------------------------------------ PE reader
function Get-PeImports {
    param([string]$FilePath)

    $imports = New-Object System.Collections.Generic.List[string]
    try {
        $fs = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'ReadWrite')
        $br = [System.IO.BinaryReader]::new($fs)
        try {
            if ($fs.Length -lt 0x40) { return @() }
            if ($br.ReadUInt16() -ne 0x5A4D) { return @() }          # 'MZ'
            $fs.Position = 0x3C
            $peOffset = $br.ReadUInt32()
            if ($peOffset -eq 0 -or $peOffset -ge $fs.Length) { return @() }
            $fs.Position = $peOffset
            if ($br.ReadUInt32() -ne 0x00004550) { return @() }      # 'PE\0\0'

            $null = $br.ReadUInt16()                                  # Machine
            $numberOfSections = $br.ReadUInt16()
            $null = $br.ReadUInt32()                                  # TimeDateStamp
            $null = $br.ReadUInt32()                                  # PointerToSymbolTable
            $null = $br.ReadUInt32()                                  # NumberOfSymbols
            $sizeOfOptionalHeader = $br.ReadUInt16()
            $null = $br.ReadUInt16()                                  # Characteristics

            $optStart = $fs.Position
            $magic = $br.ReadUInt16()
            $isPe32Plus = ($magic -eq 0x20B)
            if (-not $isPe32Plus -and $magic -ne 0x10B) { return @() }

            # Optional header -> DataDirectory[]. Layout differs between PE32 and PE32+.
            $dataDirOffset = if ($isPe32Plus) { 112 } else { 96 }
            $fs.Position = $optStart + $dataDirOffset
            $null = $br.ReadUInt32()                                  # [0] Export Table RVA
            $null = $br.ReadUInt32()                                  # [0] Export Table Size
            $importRva = $br.ReadUInt32()                             # [1] Import Table RVA
            $importSize = $br.ReadUInt32()                            # [1] Import Table Size
            if ($importRva -eq 0 -or $importSize -eq 0) { return @() }

            $fs.Position = $optStart + $sizeOfOptionalHeader
            $sections = @()
            for ($i = 0; $i -lt $numberOfSections; $i++) {
                $null = $br.ReadBytes(8)                              # Name
                $virtualSize = $br.ReadUInt32()
                $virtualAddress = $br.ReadUInt32()
                $rawSize = $br.ReadUInt32()
                $rawPointer = $br.ReadUInt32()
                $null = $br.ReadBytes(16)                             # Relocs / LineNumbers
                $sections += [pscustomobject]@{
                    VirtualAddress = $virtualAddress
                    VirtualSize    = $virtualSize
                    RawSize        = $rawSize
                    RawPointer     = $rawPointer
                }
            }

            $rvaToFileOffset = {
                param([uint32]$Rva)
                foreach ($s in $sections) {
                    $span = [Math]::Max($s.VirtualSize, $s.RawSize)
                    if ($Rva -ge $s.VirtualAddress -and $Rva -lt ($s.VirtualAddress + $span)) {
                        return ($s.RawPointer + ($Rva - $s.VirtualAddress))
                    }
                }
                return -1
            }

            $cursor = & $rvaToFileOffset $importRva
            if ($cursor -lt 0) { return @() }

            for ($guard = 0; $guard -lt 512; $guard++) {
                if ($cursor + 20 -gt $fs.Length) { break }
                $fs.Position = $cursor
                $null = $br.ReadUInt32()                              # OriginalFirstThunk
                $null = $br.ReadUInt32()                              # TimeDateStamp
                $null = $br.ReadUInt32()                              # ForwarderChain
                $nameRva = $br.ReadUInt32()
                $null = $br.ReadUInt32()                              # FirstThunk
                if ($nameRva -eq 0) { break }

                $nameOffset = & $rvaToFileOffset $nameRva
                if ($nameOffset -lt 0) { break }

                $fs.Position = $nameOffset
                $chars = New-Object System.Collections.Generic.List[char]
                while ($true) {
                    if ($fs.Position -ge $fs.Length) { break }
                    $c = $br.ReadByte()
                    if ($c -eq 0) { break }
                    $chars.Add([char]$c)
                    if ($chars.Count -gt 260) { break }
                }
                if ($chars.Count) { $imports.Add((-join $chars)) }
                $cursor += 20
            }
        }
        finally { $br.Close() }
    }
    catch {
        Write-Verbose "PE parse failed for ${FilePath}: $($_.Exception.Message)"
    }
    return @($imports)
}

# API-set DLLs that do not exist on Windows 7 (introduced by Windows 8/8.1/10).
$win7Unknown = @(
    'api-ms-win-appmodel-identity-l1-2-0'
    'api-ms-win-appmodel-runtime-l1-1-1'
    'api-ms-win-appmodel-runtime-l1-1-2'
    'api-ms-win-core-appcompat-l1-1-1'
    'api-ms-win-core-appinit-l1-1-0'
    'api-ms-win-core-com-l1-1-1'
    'api-ms-win-core-featurestaging-l1-1-0'
    'api-ms-win-core-featurestaging-l1-1-1'
    'api-ms-win-core-kernel32-legacy-l1-1-0'
    'api-ms-win-core-kernel32-legacy-l1-1-1'
    'api-ms-win-core-kernel32-legacy-l1-1-2'
    'api-ms-win-core-libraryloader-l1-2-0'
    'api-ms-win-core-libraryloader-l1-2-1'
    'api-ms-win-core-memory-l1-1-3'
    'api-ms-win-core-memory-l1-1-4'
    'api-ms-win-core-path-l1-1-0'
    'api-ms-win-core-processthreads-l1-1-2'
    'api-ms-win-core-processthreads-l1-1-3'
    'api-ms-win-core-psm-appnotify-l1-1-0'
    'api-ms-win-core-realtime-l1-1-1'
    'api-ms-win-core-slerror-l1-1-0'
    'api-ms-win-core-synch-l1-2-1'
    'api-ms-win-core-version-l1-1-1'
    'api-ms-win-core-winrt-error-l1-1-0'
    'api-ms-win-core-winrt-error-l1-1-1'
    'api-ms-win-core-winrt-l1-1-0'
    'api-ms-win-core-winrt-l1-1-1'
    'api-ms-win-core-winrt-registration-l1-1-0'
    'api-ms-win-core-winrt-robuffer-l1-1-0'
    'api-ms-win-core-winrt-roparameterizediid-l1-1-0'
    'api-ms-win-core-winrt-string-l1-1-0'
    'api-ms-win-core-winrt-string-l1-1-1'
    'api-ms-win-devices-config-l1-1-1'
    'api-ms-win-power-base-l1-1-0'
    'api-ms-win-power-setting-l1-1-0'
    'api-ms-win-security-systemfunctions-l1-1-0'
    'ext-ms-win-com-ole32-l1-1-1'
    'ext-ms-win-rtcore-ntuser-window-ext-l1-1-0'
)

# --------------------------------------------------------------- smoke build
if (-not $SkipSmokeTest) {
    Write-Step 'Smoke-building tests/hello'
    $testBuild = Join-Path (Split-Path -Parent $InstallDir) '_smoke-build'
    Remove-Item -LiteralPath $testBuild -Recurse -Force -ErrorAction SilentlyContinue

    $cmakeArgs = @(
        '-S', (Resolve-Path -LiteralPath $TestProject).Path
        '-B', $testBuild
        "-DCMAKE_PREFIX_PATH=$InstallDir"
        '-DCMAKE_BUILD_TYPE=Release'
        '-Wno-dev'
    )
    Invoke-External cmake @cmakeArgs
    Invoke-External cmake '--build' $testBuild '--config' 'Release' '--parallel'

    $exe = Get-ChildItem -LiteralPath $testBuild -Recurse -Filter '*.exe' | Select-Object -First 1
    if (-not $exe) { throw 'Smoke test produced no executable' }
    Write-Ok "smoke test built: $($exe.Name)"

    Write-Step 'Checking that the smoke test only needs DLLs shipped by this build'
    $missing = @()
    foreach ($dll in (Get-PeImports $exe.FullName)) {
        if ($dll -match '^(api-ms-win|ext-ms-win)') { continue }
        if (@('KERNEL32.dll', 'USER32.dll', 'GDI32.dll', 'SHELL32.dll', 'ADVAPI32.dll', 'ole32.dll', 'OLEAUT32.dll', 'MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll', 'WS2_32.dll', 'CRYPT32.dll', 'SHLWAPI.dll', 'COMDLG32.dll', 'COMCTL32.dll', 'IMM32.dll', 'WINMM.dll', 'NETAPI32.dll', 'VERSION.dll', 'WINSPOOL.DRV', 'DWMAPI.dll', 'UXTHEME.dll', 'PROPSYS.dll', 'UxTheme.dll', 'MFPlat.DLL', 'MF.dll', 'MFCORE.DLL') -contains $dll) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir "bin\$dll"))) { $missing += $dll }
    }
    if ($missing.Count) {
        Write-Note "non-system imports not found in $InstallDir\bin : $($missing -join ', ')"
    }
    else {
        Write-Ok 'every non-system import resolves inside the install tree'
    }
}

# -------------------------------------------------------- Windows 7 import audit
Write-Step 'Auditing PE import tables for Windows 8+ dependencies'
$binaries = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -File |
        Where-Object { $_.Extension -in @('.dll', '.exe') } |
        Sort-Object FullName -Unique)

Write-Info "scanning $($binaries.Count) binaries"
$findings = @{}
foreach ($b in $binaries) {
    foreach ($dll in (Get-PeImports $b.FullName)) {
        $key = $dll.ToLowerInvariant()
        if ($win7Unknown -contains $key) {
            if (-not $findings.ContainsKey($key)) { $findings[$key] = New-Object System.Collections.Generic.List[string] }
            $findings[$key].Add($b.FullName.Substring($InstallDir.Length))
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Ok 'no Windows 8+ API-set imports found'
    Add-Summary ''
    Add-Summary '### Windows 7 dependency audit'
    Add-Summary ''
    Add-Summary ":white_check_mark: No Windows 8+ API-set imports detected in $($binaries.Count) binaries."
}
else {
    Write-Note "found $($findings.Count) distinct Windows 8+ API-set imports"
    Add-Summary ''
    Add-Summary '### Windows 7 dependency audit'
    Add-Summary ''
    Add-Summary '| API-set (absent on Windows 7) | Referenced by |'
    Add-Summary '|---|---|'
    foreach ($key in ($findings.Keys | Sort-Object)) {
        $sample = @($findings[$key] | Select-Object -First 3) -join '<br>'
        $more = ''
        if ($findings[$key].Count -gt 3) { $more = " <br>_(+$($findings[$key].Count - 3) more)_" }
        Write-Note "$key -> $($findings[$key].Count) file(s)"
        Add-Summary "| ``$key`` | $($findings[$key].Count) file(s): $sample$more |"
    }
    Add-Summary ''
    Add-Summary '> These are usually delay-loaded / `GetProcAddress` guarded by the backport patches.'
    Add-Summary '> Always smoke-test on a real Windows 7 machine before shipping.'

    if ($Strict) {
        throw "Windows 8+ API-set imports found and -Strict was requested"
    }
}

Write-Ok "Validation finished ($(Get-Elapsed $start))"
# GitHub Actions runs each pwsh step as 'pwsh -command ". script"' and exits
# with the leftover $LASTEXITCODE. A clean completion must report 0.
Reset-LastExitCode
