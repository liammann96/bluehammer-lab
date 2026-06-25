# bluehammer-lab

Windows offline Defender scan abuse — shadow copy credential access research lab.

> **Security research use only.** This code is derived from the public [technoherder/BlueHammerFix](https://github.com/technoherder/BlueHammerFix) repository.

---

## Quick start — fresh Windows VM

Open PowerShell **as Administrator** and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/liammann96/bluehammer-lab/main/lab_setup.ps1" -OutFile lab_setup.ps1
.\lab_setup.ps1
```

The script installs all dependencies (Git, VS 2022 Build Tools, Windows ADK), compiles `FunnyApp.exe`, creates lab accounts, and creates a VSS shadow copy. When it finishes with all `[PASS]`:

```
# Switch to labuser, open CMD (not as admin):
C:\Users\labuser\Downloads\FunnyApp.exe --force
```

Expected: CMD hangs for several minutes while Defender runs an offline scan — that's the exploit working.

---

## What it does

`FunnyApp.exe --force` abuses the Windows Defender offline scan mechanism to read SAM/SYSTEM/SECURITY hives from a VSS shadow copy as NT AUTHORITY\SYSTEM, without requiring direct admin rights from the calling user.

Attack chain:
1. Enumerates existing VSS shadow copies
2. Opens SAM/SYSTEM/SECURITY hives from the shadow volume via `offreg.lib`
3. Registers a Windows service pointing to its own binary (`C:\Users\labuser\Downloads\FunnyApp.exe`)
4. Schedules a Defender offline scan — Defender runs the service as SYSTEM
5. Service reads credentials, cleans up

## Lab accounts

| Account | Type | Password |
|---------|------|----------|
| `labuser` | Standard user — runs the PoC | `LabBH2026!NCSC#` |
| `labadmin` | Local administrator — credential dump target | `AdminBH2026!NCSC#` |

## Observables

| What to look for | Where |
|-----------------|-------|
| File reads from `HarddiskVolumeShadowCopy*\Config\SAM`, `SYSTEM`, `SECURITY` | File system telemetry |
| `services.exe` spawning a child process from `\Users\` or `\Downloads\` | Process telemetry |
| `ImagePath` registry value written under `CurrentControlSet\Services` | Registry telemetry |
| `conhost.exe` with a parent in a user-writable path | Process telemetry |
