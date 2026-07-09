# lab_setup.ps1
# Self-contained setup for the BlueHammerFix (FunnyApp) lab.
#
# Run ONCE as Administrator on a fresh Windows VM. The script:
#   1. Sets Defender exclusions (before any downloads)
#   2. Downloads the lab repo as a zip (no Git required)
#   3. Installs VS 2022 Build Tools with C++ workload + matching Windows SDK
#   4. Generates offreg.lib from C:\Windows\System32\offreg.dll (dumpbin + lib)
#   5. Compiles FunnyApp.exe
#   6. Creates labuser (standard) + labadmin (admin)
#   7. Creates a VSS shadow copy (required - PoC silently exits without one)
#   8. Stages FunnyApp.exe to labuser Downloads with correct ACLs
#
# Usage (elevated PowerShell / SSM):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\lab_setup.ps1
#
# All output is echoed to console AND appended to a timestamped log file
# under C:\LabBuild\logs so failures can be triaged after the fact.

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$REPO_ZIP  = "https://github.com/liammann96/bluehammer-lab/archive/refs/heads/main.zip"
$BUILD_DIR = "C:\LabBuild\BlueHammerFix"
$STAGE_DST = "C:\Users\labuser\Downloads\FunnyApp.exe"
$LOG_DIR   = "C:\LabBuild\logs"
$LOG_FILE  = Join-Path $LOG_DIR ("setup_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

New-Item -ItemType Directory $LOG_DIR -Force | Out-Null
Start-Transcript -Path $LOG_FILE -Append | Out-Null

# -- Logging helpers -----------------------------------------------------
function Write-Step { param($msg) Write-Host $msg -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "    [*] $msg" }
function Write-Skip { param($msg) Write-Host "    [=] $msg" -ForegroundColor DarkGray }
function Write-Warn { param($msg) Write-Host "    [!] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "    [!] $msg" -ForegroundColor Red }

# Fatal helper: logs, stops transcript, exits non-zero.
# Used anywhere a downstream step is guaranteed to fail/produce a
# misleading partial result if we keep going (this was the root cause
# of the original script cascading past the compile failure).
function Fail-Fatal {
    param([string]$msg)
    Write-Err $msg
    Write-Host ""
    Write-Host "FATAL - aborting setup. Full log: $LOG_FILE" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

Write-Host "=== BlueHammerFix lab setup starting: $(Get-Date -Format o) ===" -ForegroundColor Magenta
Write-Host "Log file: $LOG_FILE" -ForegroundColor DarkGray

# -- 1. Defender exclusions ---------------------------------------------------
Write-Step "[1/8] Setting Defender exclusions..."
try {
    Add-MpPreference -ExclusionPath "C:\LabBuild" -ErrorAction Stop
    Add-MpPreference -ExclusionPath "C:\Users\labuser\Downloads" -ErrorAction Stop
    # ExclusionProcess for FunnyApp.exe intentionally REMOVED.
    # A process exclusion suppresses scanning of files FunnyApp opens/creates,
    # including the EICAR file in %TEMP% that triggers the VSS oplock chain.
    # Use ExclusionPath on the binary so Defender won't quarantine it but still
    # scans its file operations (required for TriggerWDForVS to work).
    Add-MpPreference -ExclusionPath "C:\Users\labuser\Downloads\FunnyApp.exe" -ErrorAction Stop
    Add-MpPreference -ExclusionProcess "cl.exe" -ErrorAction Stop
    Write-Ok "Exclusions set"
} catch {
    Fail-Fatal "Could not set Defender exclusions: $($_.Exception.Message)"
}

# -- 2. Download repo zip -----------------------------------------------------
Write-Step "[2/8] Downloading lab repo..."
if (Test-Path "$BUILD_DIR\FunnyApp.cpp") {
    Write-Skip "Repo already present - skipping"
} else {
    New-Item -ItemType Directory "C:\LabBuild" -Force | Out-Null
    $zipPath = "C:\LabBuild\lab.zip"
    Write-Info "Downloading $REPO_ZIP"
    try {
        Invoke-WebRequest -Uri $REPO_ZIP -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Fail-Fatal "Repo download failed: $($_.Exception.Message)"
    }
    Write-Info "Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath "C:\LabBuild" -Force
    $extracted = Get-ChildItem "C:\LabBuild" -Directory |
        Where-Object { $_.Name -like "bluehammer-lab-*" } | Select-Object -First 1
    if ($extracted) {
        if (Test-Path $BUILD_DIR) { Remove-Item $BUILD_DIR -Recurse -Force }
        Rename-Item $extracted.FullName $BUILD_DIR
        Write-Ok "Repo at $BUILD_DIR"
    } else {
        Fail-Fatal "Could not find extracted repo folder."
    }
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

# -- 3. VS 2022 Build Tools + matching Windows SDK ----------------------------
# NOTE: Windows11SDK.22621 is a Windows 11 SDK. On Server 2022 the quiet
# bootstrapper can report success while this component fails to actually
# lay down headers (cfloat/string.h missing under Include\...\ucrt).
# Use the SDK that matches the host OS: Windows10SDK.20348 (Server 2022 /
# Win10 21H2+ era SDK), which is fully compatible with VC++ 14.4x.
Write-Step "[3/8] Checking VS 2022 Build Tools (C++ workload + SDK)..."

$vcvarsCandidates = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
)
$vcvars = $vcvarsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

function Test-UcrtHeadersPresent {
    param($vcvarsPath)
    if (-not $vcvarsPath) { return $false }
    $probe = cmd /c "`"$vcvarsPath`" && echo INC=%INCLUDE%" 2>&1
    $incLine = $probe | Where-Object { $_ -like "INC=*" } | Select-Object -Last 1
    if (-not $incLine) { return $false }
    $incPaths = ($incLine -replace '^INC=','') -split ';'
    foreach ($p in $incPaths) {
        if ($p -and (Test-Path (Join-Path $p 'string.h'))) { return $true }
    }
    return $false
}

$sdkOk = Test-UcrtHeadersPresent -vcvarsPath $vcvars

if ($vcvars -and $sdkOk) {
    Write-Skip "Found working toolchain: $vcvars"
} else {
    if ($vcvars -and -not $sdkOk) {
        Write-Warn "vcvars64.bat found but UCRT headers (string.h/float.h) are missing - SDK component is broken/incomplete. Reinstalling."
    } else {
        Write-Info "Downloading VS 2022 Build Tools bootstrapper..."
    }
    $btInstaller  = "C:\LabBuild\vs_buildtools.exe"
    $btInstallLog = "C:\LabBuild\logs\vs_buildtools_install.log"
    try {
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile $btInstaller -UseBasicParsing -ErrorAction Stop
    } catch {
        Fail-Fatal "Could not download vs_buildtools.exe: $($_.Exception.Message)"
    }

    Write-Info "Installing C++ workload + Windows 10 SDK 20348 (10-20 min)..."
    $btArgs = "--quiet --wait --norestart --nocache " +
              "--add Microsoft.VisualStudio.Workload.VCTools " +
              "--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 " +
              "--add Microsoft.VisualStudio.Component.Windows10SDK.20348 " +
              "--log `"$btInstallLog`""
    $proc = Start-Process -FilePath $btInstaller -ArgumentList $btArgs -Wait -PassThru
    # VS bootstrapper exit codes: 0 = success, 3010 = success, reboot required.
    # Anything else is a real failure even though the script would previously
    # have blundered ahead as if nothing happened.
    if ($proc.ExitCode -notin @(0, 3010)) {
        Write-Err "vs_buildtools.exe exited with code $($proc.ExitCode)"
        if (Test-Path $btInstallLog) {
            Write-Err "Last 20 lines of install log ($btInstallLog):"
            Get-Content $btInstallLog -Tail 20 | ForEach-Object { Write-Host "        $_" }
        }
        Fail-Fatal "Build Tools / SDK install failed - see $btInstallLog"
    }

    $vcvars = $vcvarsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    $sdkOk  = Test-UcrtHeadersPresent -vcvarsPath $vcvars

    if ($vcvars -and $sdkOk) {
        Write-Ok "Build Tools + SDK installed and verified (string.h present)"
    } else {
        if (Test-Path $btInstallLog) {
            Write-Err "Install log tail ($btInstallLog):"
            Get-Content $btInstallLog -Tail 30 | ForEach-Object { Write-Host "        $_" }
        }
        Fail-Fatal "Build Tools installed but UCRT headers still not found. Check $btInstallLog and disk space (SDK install needs ~2GB free)."
    }
}

# -- 4. Generate offreg.lib from offreg.dll -----------------------------------
# offreg.dll ships with all Windows 10/Server 2016+ systems.
# We generate the import library using dumpbin + lib (both part of VS Build Tools).
# This avoids needing the Windows ADK entirely.
Write-Step "[4/8] Generating offreg.lib from C:\Windows\System32\offreg.dll..."
$offregLib = "$BUILD_DIR\offreg.lib"

if (Test-Path $offregLib) {
    Write-Skip "offreg.lib already present"
} elseif ($vcvars -and (Test-Path $vcvars)) {
    $dumpOut = cmd /c "`"$vcvars`" && dumpbin /exports C:\Windows\System32\offreg.dll" 2>&1
    $names = $dumpOut | ForEach-Object {
        if ($_ -match '^\s+\d+\s+[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+(\w+)\s*$') { $Matches[1] }
    }
    if ($names.Count -eq 0) {
        Write-Err "Could not parse offreg.dll exports"
        $dumpOut | Select-Object -First 10 | ForEach-Object { Write-Host "        $_" }
        Fail-Fatal "offreg.lib generation failed - dumpbin produced no parseable exports"
    } else {
        Write-Info "Found $($names.Count) exports in offreg.dll"
        $defPath = "$BUILD_DIR\offreg.def"
        $defLines = @('LIBRARY "offreg.dll"', 'EXPORTS') + ($names | ForEach-Object { "    $_" })
        [IO.File]::WriteAllLines($defPath, $defLines, [Text.Encoding]::ASCII)
        $libOut = cmd /c "`"$vcvars`" && lib /def:`"$defPath`" /machine:x64 /out:`"$offregLib`" /nologo" 2>&1
        if (Test-Path $offregLib) {
            $kb = [math]::Round((Get-Item $offregLib).Length / 1KB)
            Write-Ok "offreg.lib generated ($kb KB)"
        } else {
            Write-Err "lib.exe failed:"
            $libOut | ForEach-Object { Write-Host "        $_" }
            Fail-Fatal "offreg.lib was not produced by lib.exe"
        }
    }
} else {
    Fail-Fatal "Cannot generate offreg.lib - vcvars64.bat not found"
}

# -- 5. Compile FunnyApp.exe --------------------------------------------------
Write-Step "[5/8] Compiling FunnyApp.exe..."
$exe = "$BUILD_DIR\FunnyApp.exe"
if (Test-Path $exe) {
    $kb = [math]::Round((Get-Item $exe).Length/1KB)
    Write-Skip "Already compiled ($kb KB) - skipping"
} elseif ($vcvars -and (Test-Path $vcvars)) {
    Push-Location $BUILD_DIR
    $buildOut = cmd /c "`"$vcvars`" && compile.bat" 2>&1
    Pop-Location
    if (Test-Path $exe) {
        $kb = [math]::Round((Get-Item $exe).Length/1KB)
        Write-Ok "Build complete: FunnyApp.exe ($kb KB)"
    } else {
        Write-Err "Build failed. Output:"
        $buildOut | ForEach-Object { Write-Host "        $_" }
        # This is the step that previously failed silently and let the script
        # cascade all the way to a misleading partial readiness report.
        # Compilation is a hard prerequisite for staging - stop here.
        Fail-Fatal "FunnyApp.exe did not compile - see build output above and $LOG_FILE"
    }
} else {
    Fail-Fatal "Cannot compile - vcvars64.bat not found."
}

# -- 6. Lab user accounts -----------------------------------------------------
# Passwords must not contain any 3+ char substring of the username (Windows policy).
# 'Winter!2026#Zx' contains no substring of 'labuser' or 'labadmin'.
Write-Step "[6/8] Creating lab user accounts..."

if (-not (Get-LocalUser labuser -ErrorAction SilentlyContinue)) {
    $pw = ConvertTo-SecureString 'Winter!2026#Zx' -AsPlainText -Force
    New-LocalUser -Name labuser -Password $pw -PasswordNeverExpires
    Add-LocalGroupMember -Group "Users" -Member labuser
    Write-Ok "labuser created"
} else {
    Write-Skip "labuser already exists"
}

if (-not (Get-LocalUser labadmin -ErrorAction SilentlyContinue)) {
    $pw = ConvertTo-SecureString 'Winter!2026#Zx' -AsPlainText -Force
    New-LocalUser -Name labadmin -Password $pw -PasswordNeverExpires
    Add-LocalGroupMember -Group "Administrators" -Member labadmin
    Write-Ok "labadmin created"
} else {
    Write-Skip "labadmin already exists"
}

Add-LocalGroupMember -Group "Remote Desktop Users" -Member labuser -ErrorAction SilentlyContinue
Write-Ok "labuser added to Remote Desktop Users"

# -- 7. VSS shadow copy -------------------------------------------------------
Write-Step "[7/8] Creating VSS shadow copy..."
$hasShadow = (vssadmin list shadows 2>&1) -match "Shadow Copy Volume"
if ($hasShadow) {
    Write-Skip "Shadow copy already exists"
} else {
    $result = vssadmin create shadow /for=C: 2>&1
    if ($result -match "Successfully created") {
        Write-Ok "Shadow copy created"
    } else {
        # Downgraded from a soft warning: without a shadow copy the PoC
        # silently no-ops per the header comment, so treat this as fatal
        # rather than letting the run "succeed" with dead functionality.
        Write-Err "VSS failed: $result"
        Fail-Fatal "VSS shadow copy creation failed - PoC requires this to function"
    }
}

# -- 8. Stage binary ----------------------------------------------------------
Write-Step "[8/8] Staging FunnyApp.exe for labuser..."
if (Test-Path $exe) {
    New-Item -ItemType Directory "C:\Users\labuser\Downloads" -Force | Out-Null
    Copy-Item $exe $STAGE_DST -Force
    icacls $STAGE_DST /grant labuser:RX | Out-Null
    $kb = [math]::Round((Get-Item $STAGE_DST).Length/1KB)
    Write-Ok "Staged: $STAGE_DST ($kb KB)"
} else {
    Fail-Fatal "FunnyApp.exe not compiled - cannot stage."
}

# -- Readiness check ----------------------------------------------------------
Write-Host ""
Write-Host "-- Readiness Check --" -ForegroundColor DarkGray
$checks = [ordered]@{
    "FunnyApp.exe staged to labuser\Downloads" = Test-Path $STAGE_DST
    "labuser account exists"                   = $null -ne (Get-LocalUser labuser -ErrorAction SilentlyContinue)
    "labadmin in Administrators"               = (Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue).Name -contains "$env:COMPUTERNAME\labadmin"
    "VSS shadow copy present"                  = [bool]((vssadmin list shadows 2>&1) -match "Shadow Copy Volume")
    "Defender RT protection ON"                = -not (Get-MpPreference).DisableRealtimeMonitoring
    "Defender exclusion: C:\LabBuild"          = (Get-MpPreference).ExclusionPath -contains "C:\LabBuild"
}

$allGood = $true
foreach ($k in $checks.Keys) {
    $pass = $checks[$k]
    if (-not $pass) { $allGood = $false }
    $tag    = if ($pass) { "[PASS]" } else { "[FAIL]" }
    $colour = if ($pass) { "Green"  } else { "Red"   }
    Write-Host "  $tag $k" -ForegroundColor $colour
}

Write-Host ""
if ($allGood) {
    Write-Host "All checks passed. Switch to labuser and run:" -ForegroundColor Green
    Write-Host "  C:\Users\labuser\Downloads\FunnyApp.exe --force" -ForegroundColor White
    Write-Host ""
    Write-Host "Expected behaviour:"
    Write-Host "  - CMD hangs for several minutes while Defender offline scan runs"
    Write-Host "  - Look for: file reads under HarddiskVolumeShadowCopy*, services.exe"
    Write-Host "    spawning from user-writable paths, ImagePath registry writes,"
    Write-Host "    conhost.exe with a user-path parent"
    Write-Host ""
    Write-Host "Full setup log saved to: $LOG_FILE" -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
} else {
    Write-Host "One or more checks failed - see [FAIL] items above before detonating." -ForegroundColor Red
    Write-Host "Full setup log saved to: $LOG_FILE" -ForegroundColor DarkGray
    Stop-Transcript | Out-Null
    exit 1
}
