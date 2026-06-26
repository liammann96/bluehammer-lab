# lab_setup.ps1
# Self-contained setup for the BlueHammerFix (FunnyApp) lab.
#
# Run ONCE as Administrator on a fresh Windows VM. The script:
#   1. Sets Defender exclusions (before any downloads so nothing gets quarantined)
#   2. Installs Chocolatey (if absent)
#   3. Installs Git (if absent)
#   4. Clones the lab repo to C:\LabBuild\BlueHammerFix
#   5. Installs VS 2022 Build Tools with C++ workload (if absent)
#   6. Installs Windows ADK (if absent) — provides offreg.lib
#   7. Compiles FunnyApp.exe
#   8. Creates labuser (standard) + labadmin (admin)
#   9. Creates a VSS shadow copy (required — PoC silently exits without one)
#  10. Stages FunnyApp.exe to labuser Downloads with correct ACLs
#  11. Prints a readiness check
#
# After this script completes, RDP/switch to labuser and run:
#   C:\Users\labuser\Downloads\FunnyApp.exe --force
#
# Usage (elevated PowerShell):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\lab_setup.ps1

# Note: #Requires -RunAsAdministrator omitted intentionally so the script can
# run via SSM (which executes as NT AUTHORITY\SYSTEM, not a named admin user).
# The script requires elevation — run from an elevated prompt or SSM.

$ErrorActionPreference = "Continue"

$REPO_URL  = "https://github.com/liammann96/bluehammer-lab.git"
$BUILD_DIR = "C:\LabBuild\BlueHammerFix"
$STAGE_DST = "C:\Users\labuser\Downloads\FunnyApp.exe"

# ── 1. Defender exclusions ─────────────────────────────────────────────────
# Must happen FIRST — before cloning or compiling — so nothing gets blocked.
Write-Host "[1/10] Setting Defender exclusions..." -ForegroundColor Cyan
Add-MpPreference -ExclusionPath "C:\LabBuild"
Add-MpPreference -ExclusionPath "C:\Users\labuser\Downloads"
Add-MpPreference -ExclusionProcess "FunnyApp.exe"
Add-MpPreference -ExclusionProcess "cl.exe"
Write-Host "    [+] Exclusions: C:\LabBuild, labuser\Downloads, FunnyApp.exe, cl.exe"

# ── 2. Chocolatey ─────────────────────────────────────────────────────────
Write-Host "[2/10] Checking Chocolatey..." -ForegroundColor Cyan
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "    [*] Installing Chocolatey..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1" -ErrorAction SilentlyContinue
    refreshenv
    Write-Host "    [+] Chocolatey installed"
} else {
    Write-Host "    [=] Chocolatey already present"
}

# ── 3. Git ─────────────────────────────────────────────────────────────────
Write-Host "[3/10] Checking Git..." -ForegroundColor Cyan
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "    [*] Installing Git (this takes ~1 min)..."
    choco install git -y --no-progress | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-Host "    [+] Git installed"
} else {
    Write-Host "    [=] Git already present ($(git --version))"
}

# ── 4. Clone repo ──────────────────────────────────────────────────────────
Write-Host "[4/10] Cloning lab repo..." -ForegroundColor Cyan
if (Test-Path "$BUILD_DIR\.git") {
    Write-Host "    [=] Already cloned — pulling latest"
    git -C $BUILD_DIR pull --quiet
} else {
    New-Item -ItemType Directory "C:\LabBuild" -Force | Out-Null
    Write-Host "    [*] Cloning $REPO_URL -> $BUILD_DIR"
    git clone $REPO_URL $BUILD_DIR
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    [!] Clone failed. Check network/URL." -ForegroundColor Red
        exit 1
    }
    Write-Host "    [+] Cloned"
}

# ── 5. VS 2022 Build Tools ─────────────────────────────────────────────────
Write-Host "[5/10] Checking VS 2022 Build Tools (C++ workload)..." -ForegroundColor Cyan
$vcvars = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($vcvars) {
    Write-Host "    [=] Found: $vcvars"
} else {
    Write-Host "    [*] Installing VS 2022 Build Tools + C++ workload (this takes 10-20 min)..."
    choco install visualstudio2022buildtools `
        --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --quiet" `
        -y --no-progress --timeout 3600 | Out-Null
    $vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    if (Test-Path $vcvars) {
        Write-Host "    [+] Build Tools installed"
    } else {
        Write-Host "    [!] Build Tools install may have failed — vcvars64.bat not found at expected path." -ForegroundColor Yellow
    }
}

# ── 6. Windows ADK (for offreg.lib) ───────────────────────────────────────
Write-Host "[6/10] Checking offreg.lib (Windows ADK)..." -ForegroundColor Cyan
$offregLib = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Lib" -Recurse -Filter "offreg.lib" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*x64*" } | Select-Object -First 1

if ($offregLib) {
    Write-Host "    [=] Found: $($offregLib.FullName)"
} else {
    Write-Host "    [*] Installing Windows ADK (this takes ~5 min)..."
    choco install windows-adk -y --no-progress | Out-Null
    $offregLib = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Lib" -Recurse -Filter "offreg.lib" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*x64*" } | Select-Object -First 1
    if ($offregLib) {
        Write-Host "    [+] ADK installed, offreg.lib at: $($offregLib.FullName)"
    } else {
        Write-Host "    [!] Could not find offreg.lib after ADK install." -ForegroundColor Yellow
    }
}

# Copy offreg.lib into the build directory so compile.bat can find it
if ($offregLib -and (Test-Path $BUILD_DIR)) {
    Copy-Item $offregLib.FullName "$BUILD_DIR\offreg.lib" -Force
    Write-Host "    [+] offreg.lib copied to $BUILD_DIR"
}

# ── 7. Compile FunnyApp.exe ────────────────────────────────────────────────
Write-Host "[7/10] Compiling FunnyApp.exe..." -ForegroundColor Cyan
$exe = "$BUILD_DIR\FunnyApp.exe"
if (Test-Path $exe) {
    Write-Host "    [=] Already compiled ($(([math]::Round((Get-Item $exe).Length/1KB))) KB) — skipping"
} elseif ($vcvars -and (Test-Path $vcvars)) {
    Push-Location $BUILD_DIR
    $buildOut = cmd /c "`"$vcvars`" && compile.bat" 2>&1
    Pop-Location
    if (Test-Path $exe) {
        $kb = [math]::Round((Get-Item $exe).Length/1KB)
        Write-Host "    [+] Build complete: FunnyApp.exe ($kb KB)"
    } else {
        Write-Host "    [!] Build failed. Output:" -ForegroundColor Red
        $buildOut | ForEach-Object { Write-Host "        $_" }
    }
} else {
    Write-Host "    [!] Cannot compile — vcvars64.bat not found." -ForegroundColor Red
}

# ── 8. Lab user accounts ───────────────────────────────────────────────────
Write-Host "[8/10] Creating lab user accounts..." -ForegroundColor Cyan

if (-not (Get-LocalUser labuser -ErrorAction SilentlyContinue)) {
    $pw = ConvertTo-SecureString "LabBH2026!NCSC#" -AsPlainText -Force
    New-LocalUser -Name labuser -Password $pw -FullName "Lab Standard User" -PasswordNeverExpires
    Add-LocalGroupMember -Group "Users" -Member labuser
    Write-Host "    [+] labuser created"
} else {
    Write-Host "    [=] labuser already exists"
}

if (-not (Get-LocalUser labadmin -ErrorAction SilentlyContinue)) {
    $pw = ConvertTo-SecureString "AdminBH2026!NCSC#" -AsPlainText -Force
    New-LocalUser -Name labadmin -Password $pw -FullName "Lab Admin User" -PasswordNeverExpires
    Add-LocalGroupMember -Group "Administrators" -Member labadmin
    Write-Host "    [+] labadmin created"
} else {
    Write-Host "    [=] labadmin already exists"
}

Add-LocalGroupMember -Group "Remote Desktop Users" -Member labuser -ErrorAction SilentlyContinue
Write-Host "    [+] labuser added to Remote Desktop Users"

# ── 9. VSS shadow copy ─────────────────────────────────────────────────────
Write-Host "[9/10] Creating VSS shadow copy..." -ForegroundColor Cyan
# Critical: FunnyApp enumerates existing VSS shadows to find hive copies.
# On a fresh VM there are none — without at least one the exploit exits silently.
$hasShadow = (vssadmin list shadows 2>&1) -match "Shadow Copy Volume"
if ($hasShadow) {
    Write-Host "    [=] Shadow copy already exists"
} else {
    $result = vssadmin create shadow /for=C: 2>&1
    if ($result -match "Successfully created") {
        Write-Host "    [+] Shadow copy created"
    } else {
        Write-Host "    [!] VSS failed: $result" -ForegroundColor Yellow
    }
}

# ── 10. Stage binary ───────────────────────────────────────────────────────
Write-Host "[10/10] Staging FunnyApp.exe for labuser..." -ForegroundColor Cyan
if (Test-Path $exe) {
    New-Item -ItemType Directory "C:\Users\labuser\Downloads" -Force | Out-Null
    Copy-Item $exe $STAGE_DST -Force
    icacls $STAGE_DST /grant labuser:RX | Out-Null
    $kb = [math]::Round((Get-Item $STAGE_DST).Length/1KB)
    Write-Host "    [+] Staged: $STAGE_DST ($kb KB)"
} else {
    Write-Host "    [!] FunnyApp.exe not compiled — cannot stage." -ForegroundColor Red
}

# ── Readiness check ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "── Readiness Check ──────────────────────────────────────────" -ForegroundColor DarkGray
$checks = [ordered]@{
    "FunnyApp.exe staged to labuser\Downloads" = Test-Path $STAGE_DST
    "labuser account exists"                   = $null -ne (Get-LocalUser labuser -ErrorAction SilentlyContinue)
    "labadmin in Administrators"               = (Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue).Name -contains "$env:COMPUTERNAME\labadmin"
    "VSS shadow copy present"                  = (vssadmin list shadows 2>&1) -match "Shadow Copy Volume"
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
    Write-Host "  - CMD hangs for several minutes while the offline scan runs"
    Write-Host "  - Windows may prompt to restart to complete the scan"
    Write-Host "  - Look for: file reads under HarddiskVolumeShadowCopy*, services.exe spawning"
    Write-Host "    from user-writable paths, ImagePath registry writes, conhost.exe with user parent"
} else {
    Write-Host "One or more checks failed — see [FAIL] items above before detonating." -ForegroundColor Red
}
