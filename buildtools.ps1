# install_build_tools.ps1
# Standalone prerequisite installer: VS 2022 Build Tools (C++ workload) + optional offreg.lib.
# Extracted from lab_setup.ps1 steps 3-4.
#
# Run as Administrator.

$ErrorActionPreference = "Continue"

# Set to $false if you only want step 3 (Build Tools) and not offreg.lib generation.
$RUN_OFFREG_STEP = $true

# Only needed if you're running the offreg step standalone (normally lab_setup.ps1 sets this).
$BUILD_DIR = "C:\LabBuild\BlueHammerFix"

function Invoke-CmdWithVcvars {
    param(
        [Parameter(Mandatory)]
        [string]$VcvarsPath,

        [Parameter(Mandatory)]
        [string]$Command
    )

    return cmd.exe /c ('call "{0}" && {1}' -f $VcvarsPath, $Command) 2>&1
}


# -- Step 3: VS 2022 Build Tools ---------------------------------------------

Write-Host "[1/2] Checking VS 2022 Build Tools (C++ workload)..." -ForegroundColor Cyan


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

        Remove-Item "$env:TEMP\probe.exe" -ErrorAction SilentlyContinue
    }

    Remove-Item $probe -ErrorAction SilentlyContinue
}

if (-not $toolchainHealthy) {

    New-Item -ItemType Directory "C:\LabBuild" -Force | Out-Null

    # -- Detect machine and pick matching components --------------------------
    # Rather than hardcoding an SDK/channel that happened to work on one box,
    # inspect the actual OS build and CPU arch and choose accordingly. This is
    # what caused the original C1083 (Windows11SDK.22621 doesn't ship on
    # Server 2022) - build number tells us which SDK actually exists for it.

    $os = Get-CimInstance Win32_OperatingSystem
    $buildNumber = [int]$os.BuildNumber
    $arch = $env:PROCESSOR_ARCHITECTURE

    Write-Host "    [*] Detected OS: $($os.Caption) (build $buildNumber, $arch)"

    # Known-good Windows SDK component per OS build. Extend this table as new
    # Windows/Server releases ship - Microsoft doesn't expose this mapping via
    # an API, so it has to be maintained by hand.
    $sdkComponent = switch ($buildNumber) {
        { $_ -ge 26100 } { "Microsoft.VisualStudio.Component.Windows11SDK.26100"; break }  # Server 2025 / Win11 24H2
        { $_ -ge 22621 } { "Microsoft.VisualStudio.Component.Windows11SDK.22621"; break }  # Win11 22H2/23H2
        { $_ -ge 20348 } { "Microsoft.VisualStudio.Component.Windows10SDK.20348"; break }  # Server 2022
        { $_ -ge 17763 } { "Microsoft.VisualStudio.Component.Windows10SDK.17763"; break }  # Server 2019
        default          { "Microsoft.VisualStudio.Component.Windows10SDK.19041" }         # fallback, broadly available
    }

    Write-Host "    [+] Selected SDK component: $sdkComponent"

    $vcToolsComponent = if ($arch -eq "ARM64") {
        "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
    } else {
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
    }

    Write-Host "    [+] Selected VC Tools component: $vcToolsComponent"

    # -- Preflight: disk space -----------------------------------------------
    # VS Build Tools + C++ workload wants ~6-8GB free. EC2 Windows Server AMIs
    # often ship with a small (30GB) C: volume, so check before burning 15+ min.

    $sysDrive = Get-PSDrive -Name C
    $freeGB = [math]::Round($sysDrive.Free / 1GB, 1)

    Write-Host "    [*] Free space on C:: $freeGB GB"

    if ($freeGB -lt 10) {
        Write-Host "    [!] Low disk space ($freeGB GB free) - Build Tools install is likely to fail or run out of room." -ForegroundColor Yellow
        Write-Host "        Consider expanding the EBS volume and extending the partition before continuing."
    }

    # -- Download bootstrapper -----------------------------------------------
    # Use the Current channel consistently for both the bootstrapper and the
    # channelUri it's told to install from. Pinning to a specific LTSC point
    # release (e.g. 17.12) requires that exact version to still exist at that
    # URL - Microsoft moves these forward and stale pins start returning
    # mismatched products. The generic "release" alias is Microsoft's
    # supported "give me a working current bootstrapper" endpoint.

    $channelUri      = "https://aka.ms/vs/17/release/channel"
    $bootstrapperUri = "https://aka.ms/vs/17/release/vs_buildtools.exe"

    Write-Host "    [*] Downloading VS 2022 Build Tools bootstrapper (Current channel)..."

    $btInstaller = "C:\LabBuild\vs_buildtools.exe"

    try {
        Invoke-WebRequest `
            -Uri $bootstrapperUri `
            -OutFile $btInstaller `
            -UseBasicParsing `
            -ErrorAction Stop
    }
    catch {
        Write-Host "    [!] Failed downloading Build Tools installer: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        If this is a network/timeout error, check the EC2 instance has outbound HTTPS" -ForegroundColor Yellow
        Write-Host "        access (security group + NACL) to aka.ms / download.visualstudio.microsoft.com." -ForegroundColor Yellow
        exit 1
    }

    # Sanity-check we actually got the installer, not an HTML error page
    # (happens if aka.ms redirect chain gets blocked/proxied unexpectedly).
    $sig = Get-AuthenticodeSignature $btInstaller
    if ($sig.Status -ne "Valid") {
        Write-Host "    [!] Downloaded file failed signature check (status: $($sig.Status))." -ForegroundColor Red
        Write-Host "        This usually means a proxy/firewall intercepted the download. Aborting." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "    [*] Installing C++ workload for detected build $buildNumber / $arch (10-20 min)..."

    $installLog = "C:\LabBuild\vs_install.log"

    $btArgs = @(
        "--quiet",
        "--wait",
        "--norestart",
        "--nocache",
        "--channelUri", $channelUri,
        "--add", $vcToolsComponent,
        "--add", $sdkComponent,
        "--add", "Microsoft.VisualStudio.Component.VC.CoreBuildTools",
        "--includeRecommended",
        "--log", $installLog
    )

    try {
        $installProc = Start-Process `
            -FilePath $btInstaller `
            -ArgumentList $btArgs `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -ErrorAction Stop
    }
    catch {
        Write-Host "    [!] Failed to launch vs_buildtools.exe: $($_.Exception.Message)" -ForegroundColor Red

        if ($_.Exception.Message -match "87|parameter is incorrect") {
            Write-Host "        Error 87 with no install log usually means the process never launched -" -ForegroundColor Yellow
            Write-Host "        typically because this session has no window station (e.g. running via" -ForegroundColor Yellow
            Write-Host "        SSM Run Command / EC2 UserData as SYSTEM in Session 0). This script now" -ForegroundColor Yellow
            Write-Host "        passes -NoNewWindow to avoid that; if you still see this, try running" -ForegroundColor Yellow
            Write-Host "        interactively via RDP instead." -ForegroundColor Yellow
        }

        exit 1
    }

    Write-Host "    [*] Bootstrapper exited with code: $($installProc.ExitCode)"

    if ($installProc.ExitCode -notin @(0,3010)) {

        Write-Host "    [!] Bootstrapper returned failure exit code $($installProc.ExitCode)" -ForegroundColor Red

        # Surface the actual reason instead of limping forward blind.
        $summaryLog = Get-ChildItem "C:\LabBuild\*_Setup.log*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (Test-Path $installLog) {
            Write-Host "        Last 25 lines of $installLog :" -ForegroundColor Yellow
            Get-Content $installLog -Tail 25 | ForEach-Object { Write-Host "        $_" }
        }
        elseif ($summaryLog) {
            Write-Host "        Last 25 lines of $($summaryLog.FullName) :" -ForegroundColor Yellow
            Get-Content $summaryLog.FullName -Tail 25 | ForEach-Object { Write-Host "        $_" }
        }
        else {
            Write-Host "        No install log found under C:\LabBuild - check %TEMP%\dd_*.log as well." -ForegroundColor Yellow
        }

        exit 1
    }

    # Refresh vcvars after install
    $vcvars = Find-Vcvars

    if (-not $vcvars) {
        Write-Host "    [!] Bootstrapper reported success but vcvars64.bat still not found." -ForegroundColor Red
        Write-Host "        This usually means a reboot is pending, or the VCTools component itself" -ForegroundColor Yellow
        Write-Host "        failed silently - check $installLog for '[Error]' lines." -ForegroundColor Yellow
        exit 1
    }

    # Verify installation with vswhere
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"

    if (Test-Path $vswhere) {

        Write-Host "    [*] Checking installation completeness with vswhere..."

        $vs = & $vswhere -products * -format json | ConvertFrom-Json

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

        Remove-Item "$env:TEMP\probe.exe" -ErrorAction SilentlyContinue
    }

    Remove-Item $probe -ErrorAction SilentlyContinue
}

Write-Host "    [+] vcvars64.bat: $vcvars" -ForegroundColor Green


# -- Step 4 (optional): Generate offreg.lib from offreg.dll ------------------

if ($RUN_OFFREG_STEP) {

    Write-Host "[2/2] Generating offreg.lib from offreg.dll..." -ForegroundColor Cyan

    New-Item -ItemType Directory $BUILD_DIR -Force | Out-Null

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

            $dumpOut | Select-Object -First 15 | ForEach-Object {
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

            $defLines += $names | ForEach-Object { "    $_" }

            [IO.File]::WriteAllLines($defPath, $defLines, [Text.Encoding]::ASCII)

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
}

Write-Host ""
Write-Host "Done. vcvars64.bat located at:" -ForegroundColor Green
Write-Host "  $vcvars"
