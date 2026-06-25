@echo off
setlocal

:: ---------------------------------------------------------------------------
:: compile.bat — Build FunnyApp.exe with MSVC (cl.exe) from the command line.
:: Run this from a Developer Command Prompt, or let the script find vcvars64.
:: ---------------------------------------------------------------------------

:: --- Auto-locate vcvars64.bat if not already in a VS environment ----------
if "%VSCMD_VER%"=="" (
    set "VCVARS="
    for %%P in (
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvars64.bat"
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    ) do (
        if exist %%P set "VCVARS=%%P"
    )
    if "%VCVARS%"=="" (
        echo [!] Could not find vcvars64.bat. Open a Developer Command Prompt instead.
        exit /b 1
    )
    call "%VCVARS%"
)

:: --- Compiler flags --------------------------------------------------------
set CFLAGS=/nologo /W0 /O2 /GL /std:c++17 /DNDEBUG /D_CONSOLE /DUNICODE /D_UNICODE /D_CRT_SECURE_NO_WARNINGS /MT

:: --- Linker flags ----------------------------------------------------------
set LIBS=offreg.lib wininet.lib ktmw32.lib Shlwapi.lib Rpcrt4.lib ntdll.lib Cabinet.lib Wuguid.lib CldApi.lib Advapi32.lib Ole32.lib OleAut32.lib User32.lib

:: --- Sources ---------------------------------------------------------------
set SRCS=FunnyApp.cpp windefend_c.c windefend_s.c

:: --- Build -----------------------------------------------------------------
echo [*] Compiler: cl %VSCMD_VER%
echo [*] Sources:  %SRCS%
echo [*] Output:   FunnyApp.exe
echo.

cl %CFLAGS% %SRCS% /Fe:FunnyApp.exe /link /LTCG %LIBS%

if %ERRORLEVEL%==0 (
    echo.
    echo [+] Build complete: FunnyApp.exe
) else (
    echo.
    echo [-] Build failed.
    exit /b %ERRORLEVEL%
)

endlocal
