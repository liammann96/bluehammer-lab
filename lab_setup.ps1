# lab_setup.ps1
# Self-contained setup for the BlueHammerFix (FunnyApp) lab.
#
# Run ONCE as Administrator on a fresh Windows VM. The script:
#   1. Sets Defender exclusions (before any downloads)
#   2. Downloads the lab repo as a zip (no Git required)
#   3. Installs VS 2022 Build Tools with C++ workload
#   4. Installs Windows ADK Deployment Tools (for offreg.lib)
#   5. Compiles FunnyApp.exe
#   6. Creates labuser (standard) + labadmin (admin)
#   7. Creates a VSS shadow copy (required - PoC silently exits without one)
#   8. Stages FunnyApp.exe to labuser Downloads with correct ACLs
#
# Usage (elevated PowerShell / SSM):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\lab_setup.ps1

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$REPO_ZIP  = "https://github.com/liammann96/bluehammer-lab/archive/refs/heads/main.zip"
$BUILD_DIR = "C:\LabBuild\BlueHammerFix"
$STAGE_DST = "C:\Users\labuser\Downloads\FunnyApp.exe"

# -- 1. Defender exclusions -----------------------------------------------
# Must happen FIRST so nothing gets quarantined during downloads/compile.
Write-Host "[1/8] Setting Defender exclusions..." -ForegroundColor Cyan
Add-MpPreference -ExclusionPath "C:\LabBuild"
Add-MpPreference -ExclusionPath "C:\Users\labuser\Downloads"
Add-MpPreference -ExclusionProcess "FunnyApp.exe"
Add-MpPreference -ExclusionProcess "cl.exe"
Write-Host "    [+] Exclusions set"

# -- 2. Download repo ---------------------------------------------------------
Write-Host "[2/8] Downloading lab repo..." -ForegroundColor Cyan
if (Test-Path "$BUILD_DIR\FunnyApp.cpp") {
    Write-Host "    [=] Repo already present - skipping download"
} else {
    New-Item -ItemType Directory "C:\LabBuild" -Force | Out-Null
    $zipPath = "C:\LabBuild\lab.zip"
    Write-Host "    [*] Downloading $REPO_ZIP"
    Invoke-WebRequest -Uri $REPO_ZIP -OutFile $zipPath -UseBasicParsing
    Write-Host "    [*] Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath "C:\LabBuild" -Force
    # GitHub zips extract to <repo>-<branch>\ subfolder
    $extracted = Get-ChildItem "C:\LabBuild" -Directory | Where-Object { $_.Name -like "bluehammer-lab-*" } | Select-Object -First 1
    if ($extracted) {
        if (Test-Path $BUILD_DIR) { Remove-Item $BUILD_DIR -Recurse -Force }
        Rename-Item $extracted.FullName $BUILD_DIR
        Write-Host "    [+] Repo at $BUILD_DIR"
    } else {
        Write-Host "    [!] Could not find extracted repo folder." -ForegroundColor Red
        exit 1
    }
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

# -- 3. VS 2022 Build Tools ---------------------------------------------------
Write-Host "[3/8] Checking VS 2022 Build Tools (C++ workload)..." -ForegroundColor Cyan
$vcvars = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($vcvars) {
    Write-Host "    [=] Found: $vcvars"
} else {
    Write-Host "    [*] Downloading VS 2022 Build Tools bootstrapper..."
    $btInstaller = "C:\LabBuild\vs_buildtools.exe"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile $btInstaller -UseBasicParsing
    Write-Host "    [*] Installing C++ workload (10-20 min)..."
    $btArgs = "--quiet --wait --norestart --nocache " +
              "--add Microsoft.VisualStudio.Workload.VCTools " +
              "--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 " +
              "--add Microsoft.VisualStudio.Component.Windows11SDK.22621"
    Start-Process -FilePath $btInstaller -ArgumentList $btArgs -Wait
    $vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    if (Test-Path $vcvars) {
        Write-Host "    [+] Build Tools installed"
    } else {
        Write-Host "    [!] Build Tools install may have failed - vcvars64.bat not found." -ForegroundColor Yellow
    }
}

# -- 4. Windows ADK Deployment Tools (offreg.lib) ----------------------------
Write-Host "[4/8] Checking offreg.lib (Windows ADK Deployment Tools)..." -ForegroundColor Cyan
$offregLib = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Lib" -Recurse -Filter "offreg.lib" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*x64*" } | Select-Object -First 1

if ($offregLib) {
    Write-Host "    [=] Found: $($offregLib.FullName)"
} else {
    Write-Host "    [*] Downloading Windows ADK web installer..."
    $adkSetup = "C:\LabBuild\adksetup.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2196127" -OutFile $adkSetup -UseBasicParsing
    Write-Host "    [*] Installing Deployment Tools only (~5 min)..."
    Start-Process -FilePath $adkSetup -ArgumentList "/quiet /features OptionId.DeploymentTools" -Wait
    $offregLib = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Lib" -Recurse -Filter "offreg.lib" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*x64*" } | Select-Object -First 1
    if ($offregLib) {
        Write-Host "    [+] ADK installed, offreg.lib at: $($offregLib.FullName)"
    } else {
        Write-Host "    [!] Could not find offreg.lib after ADK install." -ForegroundColor Yellow
    }
}

if ($offregLib -and (Test-Path $BUILD_DIR)) {
    Copy-Item $offregLib.FullName "$BUILD_DIR\offreg.lib" -Force
    Write-Host "    [+] offreg.lib copied to $BUILD_DIR"
}

# -- 5. Compile FunnyApp.exe --------------------------------------------------
Write-Host "[5/8] Compiling FunnyApp.exe..." -ForegroundColor Cyan
$exe = "$BUILD_DIR\FunnyApp.exe"
if (Test-Path $exe) {
    $kb = [math]::Round((Get-Item $exe).Length/1KB)
    Write-Host "    [=] Already compiled ($kb KB) - skipping"
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
    Write-Host "    [!] Cannot compile - vcvars64.bat not found." -ForegroundColor Red
}

# -- 6. Lab user accounts -----------------------------------------------------
Write-Host "[6/8] Creating lab user accounts..." -ForegroundColor Cyan

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

# -- 7. VSS shadow copy -------------------------------------------------------
Write-Host "[7/8] Creating VSS shadow copy..." -ForegroundColor Cyan
# Critical: FunnyApp enumerates existing VSS shadows to find hive copies.
# On a fresh VM there are none - without at least one the exploit exits silently.
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

# -- 8. Stage binary ----------------------------------------------------------
Write-Host "[8/8] Staging FunnyApp.exe for labuser..." -ForegroundColor Cyan
if (Test-Path $exe) {
    New-Item -ItemType Directory "C:\Users\labuser\Downloads" -Force | Out-Null
    Copy-Item $exe $STAGE_DST -Force
    icacls $STAGE_DST /grant labuser:RX | Out-Null
    $kb = [math]::Round((Get-Item $STAGE_DST).Length/1KB)
    Write-Host "    [+] Staged: $STAGE_DST ($kb KB)"
} else {
    Write-Host "    [!] FunnyApp.exe not compiled - cannot stage." -ForegroundColor Red
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
} else {
    Write-Host "One or more checks failed - see [FAIL] items above before detonating." -ForegroundColor Red
}
