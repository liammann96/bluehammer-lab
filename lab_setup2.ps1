# lab_setup.ps1
# Self-contained setup for the BlueHammerFix (FunnyApp) lab.
#
# Run ONCE as Administrator on a fresh Windows VM.

$ErrorActionPreference = "Continue"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$REPO_ZIP  = "https://github.com/liammann96/bluehammer-lab/archive/refs/heads/main.zip"
$BUILD_DIR = "C:\LabBuild\BlueHammerFix"
$STAGE_DST = "C:\Users\labuser\Downloads\FunnyApp.exe"

function Invoke-CmdWithVcvars {
    param(
        [Parameter(Mandatory)]
        [string]$VcvarsPath,

        [Parameter(Mandatory)]
        [string]$Command
    )

    return cmd.exe /c ('call "{0}" && {1}' -f $VcvarsPath, $Command) 2>&1
}

# -- 1. Defender exclusions ---------------------------------------------------

Write-Host "[1/8] Setting Defender exclusions..." -ForegroundColor Cyan

try {
    Add-MpPreference -ExclusionPath "C:\LabBuild" -ErrorAction Stop
    Add-MpPreference -ExclusionPath "C:\Users\labuser\Downloads" -ErrorAction Stop
    Add-MpPreference -ExclusionPath "C:\Users\labuser\Downloads\FunnyApp.exe" -ErrorAction Stop
    Add-MpPreference -ExclusionProcess "cl.exe" -ErrorAction Stop

    Write-Host "    [+] Exclusions set"
}
catch {
    Write-Host "    [!] Defender exclusions could not be applied: $($_.Exception.Message)" -ForegroundColor Yellow
}


# -- 2. Download repo zip -----------------------------------------------------

Write-Host "[2/8] Downloading lab repo..." -ForegroundColor Cyan

if (Test-Path "$BUILD_DIR\FunnyApp.cpp") {

    Write-Host "    [=] Repo already present - skipping"

}
else {

    New-Item -ItemType Directory "C:\LabBuild" -Force | Out-Null

    $zipPath = "C:\LabBuild\lab.zip"

    Write-Host "    [*] Downloading $REPO_ZIP"

    try {
        Invoke-WebRequest `
            -Uri $REPO_ZIP `
            -OutFile $zipPath `
            -UseBasicParsing `
            -ErrorAction Stop
    }
    catch {
        Write-Host "    [!] Failed downloading repo: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }


    Write-Host "    [*] Extracting..."

    try {
        Expand-Archive `
            -Path $zipPath `
            -DestinationPath "C:\LabBuild" `
            -Force `
            -ErrorAction Stop
    }
    catch {
        Write-Host "    [!] Failed extracting archive: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }


    $extracted = Get-ChildItem "C:\LabBuild" -Directory |
        Where-Object { $_.Name -like "bluehammer-lab-*" } |
        Select-Object -First 1


    if ($extracted) {

        if (Test-Path $BUILD_DIR) {
            Remove-Item $BUILD_DIR -Recurse -Force
        }

        Rename-Item `
            -Path $extracted.FullName `
            -NewName "BlueHammerFix"

        Write-Host "    [+] Repo at $BUILD_DIR"

    }
    else {

        Write-Host "    [!] Could not find extracted repo folder." -ForegroundColor Red
        exit 1
    }


    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}


# -- 3. VS 2022 Build Tools ---------------------------------------------------

Write-Host "[3/8] Checking VS 2022 Build Tools (C++ workload)..." -ForegroundColor Cyan


function Find-Vcvars {

    $paths = @(
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    )

    foreach ($path in $paths) {

        if (Test-Path $path) {
            return $path
        }

    }

    return $null
}


$vcvars = Find-Vcvars


$sdkRoot = "C:\Program Files (x86)\Windows Kits\10\Include"


$msvcRoot = Get-ChildItem `
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC" `
    -Directory `
    -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1


$floatH = $null

if ($msvcRoot) {
    $floatH = Join-Path $msvcRoot.FullName "include\float.h"
}


$toolchainHealthy =
    ($null -ne $vcvars) -and
    (Test-Path $sdkRoot) -and
    ($null -ne $floatH) -and
    (Test-Path $floatH)


if ($toolchainHealthy) {

    Write-Host "    [=] Build tools found - running probe compile"


    $probe = "$env:TEMP\probe.c"

@'
#include <float.h>
#include <string.h>

int main()
{
    return 0;
}
'@ | Set-Content $probe


    $probeOut = Invoke-CmdWithVcvars `
        -VcvarsPath $vcvars `
        -Command ('cl /nologo "{0}" /Fe:"{1}"' -f $probe,"$env:TEMP\probe.exe")


    if ($probeOut -match "fatal error") {

        Write-Host "    [!] Probe compile failed" -ForegroundColor Red

        $probeOut | ForEach-Object {
            Write-Host "        $_"
        }

        $toolchainHealthy = $false
    }
    else {

        Write-Host "    [+] Probe compile succeeded"

        Remove-Item "$env:TEMP\probe.exe" `
            -ErrorAction SilentlyContinue
    }


    Remove-Item $probe `
        -ErrorAction SilentlyContinue
}
if (-not $toolchainHealthy) {

    Write-Host "    [*] Downloading VS 2022 Build Tools bootstrapper..."

    $btInstaller = "C:\LabBuild\vs_buildtools.exe"


    try {

        Invoke-WebRequest `
            -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" `
            -OutFile $btInstaller `
            -UseBasicParsing `
            -ErrorAction Stop

    }
    catch {

        Write-Host "    [!] Failed downloading Build Tools installer: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }


    Write-Host "    [*] Installing C++ workload (10-20 min)..."


    $btArgs = @(
        "--quiet",
        "--wait",
        "--norestart",
        "--nocache",
        "--channelUri", "https://aka.ms/vs/17/release.LTSC.17.12/channel",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--includeRecommended",
        "--log", "C:\LabBuild\vs_install.log"
    )


    $installProc = Start-Process `
        -FilePath $btInstaller `
        -ArgumentList $btArgs `
        -Wait `
        -PassThru


    Write-Host "    [*] Bootstrapper exited with code: $($installProc.ExitCode)"


    if ($installProc.ExitCode -notin @(0,3010)) {

        Write-Host "    [!] Bootstrapper returned non-success exit code" -ForegroundColor Yellow
        Write-Host "        Check C:\LabBuild\vs_install.log"

    }


    # Refresh vcvars after install

    $vcvars = Find-Vcvars


    if (-not $vcvars) {

        Write-Host "    [!] Build Tools install failed - vcvars64.bat not found." -ForegroundColor Red
        exit 1
    }


    # Verify installation with vswhere

    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"


    if (Test-Path $vswhere) {

        Write-Host "    [*] Checking installation completeness with vswhere..."


        $vs = & $vswhere `
            -products * `
            -format json |
            ConvertFrom-Json


        if ($vs -and $vs[0].isComplete -eq $true) {

            Write-Host "    [+] Installation complete per vswhere"

        }
        else {

            Write-Host "    [!] Installation marked incomplete by vswhere" -ForegroundColor Yellow

            if ($vs) {
                Write-Host "        isComplete: $($vs[0].isComplete)"
            }

        }
    }


    # Final compile probe

    Write-Host "    [*] Running final probe compile..."


    $probe = "$env:TEMP\probe.c"


@'
#include <float.h>
#include <string.h>

int main()
{
    return 0;
}
'@ | Set-Content $probe


    $probeOut = Invoke-CmdWithVcvars `
        -VcvarsPath $vcvars `
        -Command ('cl /nologo "{0}" /Fe:"{1}"' -f $probe,"$env:TEMP\probe.exe")


    if ($probeOut -match "fatal error") {

        Write-Host "    [!] Post-install probe compile FAILED" -ForegroundColor Red

        $probeOut | ForEach-Object {
            Write-Host "        $_"
        }

        exit 1

    }
    else {

        Write-Host "    [+] Post-install probe compile succeeded"

        Remove-Item "$env:TEMP\probe.exe" `
            -ErrorAction SilentlyContinue
    }


    Remove-Item $probe `
        -ErrorAction SilentlyContinue
}



# -- 4. Generate offreg.lib from offreg.dll -----------------------------------

Write-Host "[4/8] Generating offreg.lib from offreg.dll..." -ForegroundColor Cyan


$offregLib = "$BUILD_DIR\offreg.lib"


if (Test-Path $offregLib) {

    Write-Host "    [=] offreg.lib already present"

}
elseif ($vcvars) {


    Write-Host "    [*] Dumping exports..."


    $dumpOut = Invoke-CmdWithVcvars `
        -VcvarsPath $vcvars `
        -Command "dumpbin /exports C:\Windows\System32\offreg.dll"


    $names = $dumpOut | ForEach-Object {

        if ($_ -match '^\s+\d+\s+[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+(.+?)\s*$') {

            $Matches[1].Trim()

        }

    }


    if (-not $names -or $names.Count -eq 0) {

        Write-Host "    [!] Could not parse offreg.dll exports" -ForegroundColor Red


        $dumpOut |
            Select-Object -First 15 |
            ForEach-Object {
                Write-Host "        $_"
            }

    }
    else {


        Write-Host "    [*] Found $($names.Count) exports"


        $defPath = "$BUILD_DIR\offreg.def"


        $defLines = @(
            'LIBRARY "offreg.dll"',
            'EXPORTS'
        )


        $defLines += $names | ForEach-Object {
            "    $_"
        }


        [IO.File]::WriteAllLines(
            $defPath,
            $defLines,
            [Text.Encoding]::ASCII
        )


        $libOut = Invoke-CmdWithVcvars `
            -VcvarsPath $vcvars `
            -Command ('lib /def:"{0}" /machine:x64 /out:"{1}" /nologo' -f $defPath,$offregLib)


        if (Test-Path $offregLib) {

            $kb = [math]::Round((Get-Item $offregLib).Length / 1KB)

            Write-Host "    [+] offreg.lib generated ($kb KB)"

        }
        else {

            Write-Host "    [!] lib.exe failed" -ForegroundColor Red

            $libOut | ForEach-Object {
                Write-Host "        $_"
            }

        }

    }

}
else {

    Write-Host "    [!] Cannot generate offreg.lib - vcvars missing" -ForegroundColor Red

}



# -- 5. Compile FunnyApp.exe --------------------------------------------------

Write-Host "[5/8] Compiling FunnyApp.exe..." -ForegroundColor Cyan


$exe = "$BUILD_DIR\FunnyApp.exe"


if (Test-Path $exe) {

    $kb = [math]::Round((Get-Item $exe).Length / 1KB)

    Write-Host "    [=] Already compiled ($kb KB) - skipping"

}
elseif (-not (Test-Path "$BUILD_DIR\compile.bat")) {

    Write-Host "    [!] compile.bat missing from repository" -ForegroundColor Red
    exit 1

}
elseif ($vcvars) {

    Push-Location $BUILD_DIR


    $buildOut = Invoke-CmdWithVcvars `
        -VcvarsPath $vcvars `
        -Command "compile.bat"


    Pop-Location


    if (Test-Path $exe) {

        $kb = [math]::Round((Get-Item $exe).Length / 1KB)

        Write-Host "    [+] Build complete: FunnyApp.exe ($kb KB)"

    }
    else {

        Write-Host "    [!] Build failed. Output:" -ForegroundColor Red

        $buildOut | ForEach-Object {
            Write-Host "        $_"
        }

        exit 1
    }

}
else {

    Write-Host "    [!] Cannot compile - vcvars missing." -ForegroundColor Red
    exit 1
}
# -- 6. Lab user accounts -----------------------------------------------------

Write-Host "[6/8] Creating lab user accounts..." -ForegroundColor Cyan


function New-LabUser {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Group
    )


    if (Get-LocalUser $Name -ErrorAction SilentlyContinue) {

        Write-Host "    [=] $Name already exists"
        return

    }


    try {

        $pw = ConvertTo-SecureString `
            'Winter!2026#Zx' `
            -AsPlainText `
            -Force


        New-LocalUser `
            -Name $Name `
            -Password $pw `
            -PasswordNeverExpires `
            -ErrorAction Stop | Out-Null


        Add-LocalGroupMember `
            -Group $Group `
            -Member $Name `
            -ErrorAction Stop


        Write-Host "    [+] $Name created"

    }
    catch {

        Write-Host "    [!] Failed creating $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}


New-LabUser `
    -Name "labuser" `
    -Group "Users"


New-LabUser `
    -Name "labadmin" `
    -Group "Administrators"



try {

    Add-LocalGroupMember `
        -Group "Remote Desktop Users" `
        -Member labuser `
        -ErrorAction Stop


    Write-Host "    [+] labuser added to Remote Desktop Users"

}
catch {

    Write-Host "    [!] Could not add labuser to Remote Desktop Users" -ForegroundColor Yellow

}



# -- 7. VSS shadow copy -------------------------------------------------------

Write-Host "[7/8] Creating VSS shadow copy..." -ForegroundColor Cyan


function Test-VssShadow {

    try {

        $shadowOutput = vssadmin list shadows 2>&1

        return ($shadowOutput -match "Shadow Copy")

    }
    catch {

        return $false

    }
}


if (Test-VssShadow) {

    Write-Host "    [=] Shadow copy already exists"

}
else {

    try {

        $result = vssadmin create shadow /for=C: 2>&1


        if ($result -match "Successfully") {

            Write-Host "    [+] Shadow copy created"

        }
        else {

            Write-Host "    [!] VSS output:" -ForegroundColor Yellow

            $result | ForEach-Object {
                Write-Host "        $_"
            }

        }

    }
    catch {

        Write-Host "    [!] VSS creation failed: $($_.Exception.Message)" -ForegroundColor Yellow

    }

}



# -- 8. Stage binary ----------------------------------------------------------

Write-Host "[8/8] Staging FunnyApp.exe for labuser..." -ForegroundColor Cyan


if (Test-Path $exe) {


    try {

        New-Item `
            -ItemType Directory `
            "C:\Users\labuser\Downloads" `
            -Force |
            Out-Null


        Copy-Item `
            $exe `
            $STAGE_DST `
            -Force `
            -ErrorAction Stop


        icacls `
            $STAGE_DST `
            /grant `
            "labuser:RX" |
            Out-Null


        $kb = [math]::Round((Get-Item $STAGE_DST).Length / 1KB)


        Write-Host "    [+] Staged: $STAGE_DST ($kb KB)"

    }
    catch {

        Write-Host "    [!] Failed staging executable: $($_.Exception.Message)" -ForegroundColor Red
        exit 1

    }

}
else {

    Write-Host "    [!] FunnyApp.exe not compiled - cannot stage." -ForegroundColor Red
    exit 1

}



# -- Readiness check ----------------------------------------------------------

Write-Host ""
Write-Host "-- Readiness Check --" -ForegroundColor DarkGray



$mpPreference = Get-MpPreference `
    -ErrorAction SilentlyContinue



$checks = [ordered]@{

    "FunnyApp.exe staged to labuser\Downloads" =
        (Test-Path $STAGE_DST)


    "labuser account exists" =
        ($null -ne (Get-LocalUser labuser -ErrorAction SilentlyContinue))


    "labadmin in Administrators" =
        (
            (Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue).Name -contains
            "$env:COMPUTERNAME\labadmin"
        )


    "VSS shadow copy present" =
        (Test-VssShadow)


    "Defender RT protection ON" =
        (
            $null -ne $mpPreference -and
            (-not $mpPreference.DisableRealtimeMonitoring)
        )


    "Defender exclusion: C:\LabBuild" =
        (
            $null -ne $mpPreference -and
            ($mpPreference.ExclusionPath -contains "C:\LabBuild")
        )
}



$allGood = $true


foreach ($k in $checks.Keys) {


    $pass = [bool]$checks[$k]


    if (-not $pass) {

        $allGood = $false

    }


    $tag = if ($pass) {
        "[PASS]"
    }
    else {
        "[FAIL]"
    }


    $colour = if ($pass) {
        "Green"
    }
    else {
        "Red"
    }


    Write-Host "  $tag $k" -ForegroundColor $colour

}



Write-Host ""


if ($allGood) {


    Write-Host "All checks passed. Switch to labuser and run:" -ForegroundColor Green


    Write-Host "  C:\Users\labuser\Downloads\FunnyApp.exe --force" -ForegroundColor White


    Write-Host ""

    Write-Host "Expected behaviour:"


    Write-Host "  - CMD hangs for several minutes while Defender offline scan runs"

    Write-Host "  - Look for:"
    Write-Host "      * file reads under HarddiskVolumeShadowCopy*"
    Write-Host "      * services.exe spawning from user-writable paths"
    Write-Host "      * ImagePath registry writes"
    Write-Host "      * conhost.exe with a user-path parent"


}
else {


    Write-Host ""
    Write-Host "One or more checks failed - see [FAIL] items above." -ForegroundColor Red

    exit 1

}