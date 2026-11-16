@echo off
setlocal enabledelayedexpansion
REM lapis-mt6878-root -- one-shot root for Redmi Note 15 Pro 5G (lapis / MT6878)
REM usage: scripts\root.bat

set "HERE=%~dp0"
set "ROOT=%HERE%.."
set "ADB=adb"

where adb >nul 2>&1
if errorlevel 1 (
  if exist "%ROOT%\..\platform-tools\adb.exe" (
    set "ADB=%ROOT%\..\platform-tools\adb.exe"
  ) else (
    echo [-] adb not found in PATH
    exit /b 2
  )
)

echo === 1/5 check device ===
"%ADB%" get-state || (echo [-] no adb device & exit /b 2)
"%ADB%" shell getprop ro.build.version.incremental
"%ADB%" shell uname -r

echo.
echo === 2/5 push timer ===
"%ADB%" push "%ROOT%\bin\timer-fullroot" /data/local/tmp/timer || exit /b 1
"%ADB%" shell chmod 755 /data/local/tmp/timer

echo.
echo === 3/5 prepare ksud ^(^>= 3.3.1^) ===
"%ADB%" shell "/data/local/tmp/ksud --version" > "%TEMP%\ksuv.txt" 2>nul
set "KSUV="
for /f "delims=" %%i in ('type "%TEMP%\ksuv.txt"') do set "KSUV=%%i"
echo   current: !KSUV!
echo !KSUV! | findstr /b "ksud 3.3" >nul
if errorlevel 1 (
  if exist "%ROOT%\ksud" (
    echo   pushing local ksud...
    "%ADB%" push "%ROOT%\ksud" /data/local/tmp/ksud
  ) else (
    echo   [!] ksud ^< 3.3.1 or missing.
    echo       Download it and put as ksud\ at repo root, or:
    echo       https://github.com/tiann/KernelSU/releases/download/v3.3.1/ksud-aarch64-linux-android
    echo       then re-run this script.
    "%ADB%" shell chmod 755 /data/local/tmp/ksud
  )
)
"%ADB%" shell chmod 755 /data/local/tmp/ksud
"%ADB%" shell "/data/local/tmp/ksud --version"

echo.
echo === 4/5 run exploit ^(~40s, do not touch the phone^) ===
"%ADB%" shell "rm -f /data/local/tmp/t.log /data/local/tmp/ksu_stage.sh"
"%ADB%" shell "cd /data/local/tmp; nohup ./timer fake >t.log 2>&1 </dev/null &"

set /a N=0
:WAIT
timeout /t 5 /nobreak >nul
set /a N+=5
"%ADB%" shell "grep -qE 'KSU_LOADED|KSU_MISSING|parking without reap' /data/local/tmp/t.log 2>/dev/null"
if errorlevel 1 (
  if !N! GEQ 120 goto RESULT
  <nul set /p "."
  goto WAIT
)
echo.

:RESULT
echo.
echo === 5/5 result ===
"%ADB%" shell "grep -E 'selinux|ksud=|late-load|KSU_' /data/local/tmp/t.log"
echo.
echo --- verify ---
"%ADB%" shell "su -c id"
if errorlevel 1 (
  echo [-] su not available. Check /data/local/tmp/t.log
  exit /b 1
)
echo.
echo [+] ROOT OK
echo     soft reboot keeps it: adb shell "su -c 'stop; start'"
echo     cold boot needs a re-run
pause
