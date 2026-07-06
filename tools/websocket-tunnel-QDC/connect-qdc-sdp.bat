@REM ============================================================================================================
@REM   
@REM                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
@REM                                SPDX-License-Identifier: BSD-3-Clause
@REM   
@REM ============================================================================================================ 

@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ==============================================================================
rem QDC SDP one-click connection launcher
rem
rem Starts the SSH, ADB, Android app_process, and Windows Java tunnel steps needed
rem for Snapdragon Profiler device discovery through SDP.
rem
rem REQUIRED environment variables (or set them in config.local.bat):
rem   QDC_API_KEY       - Your QDC API key
rem   SSH_KEY           - Path to your SSH private key (e.g. C:\Users\you\.ssh\id_ed25519)
rem
rem OPTIONAL environment variables:
rem   SSH_USER_HOST     - SSH user@host (auto-detected from DNS servers if not set)
rem   QDC_SESSIONS_URL  - QDC sessions API endpoint (has a default)
rem ==============================================================================

set "CONNECTION_CATEGORY=QDC Cloud device"

rem Load local config overrides if present (git-ignored)
set "SCRIPT_DIR=%~dp0"
if exist "%SCRIPT_DIR%config.local.bat" (
    call "%SCRIPT_DIR%config.local.bat"
)

rem --- Validate required configuration ---
if not defined SSH_KEY (
    echo ERROR: SSH_KEY is not set.
    echo        Set the SSH_KEY environment variable or define it in config.local.bat.
    echo        Example: set "SSH_KEY=C:\Users\you\.ssh\id_ed25519"
    goto :fail
)
rem Auto-determine SSH_USER_HOST from DNS servers if not already set
if not defined SSH_USER_HOST (
    set "SSH_USER_HOST=sshtunnel@ssh.qdc.qualcomm.com"
    for /f "delims=" %%S in ('ipconfig /all ^| findstr /i "DNS Servers"') do (
        echo %%S | findstr /i "qualcomm.com" >nul && set "SSH_USER_HOST=sshtunnel@ssh.qdc-internal.qualcomm.com"
    )
    echo Auto-detected SSH host: !SSH_USER_HOST!
)
if not defined QDC_API_KEY (
    echo ERROR: QDC_API_KEY is not set.
    echo        Set the QDC_API_KEY environment variable or define it in config.local.bat.
    goto :fail
)

rem Default sessions URL if not overridden
if not defined QDC_SESSIONS_URL (
    set "QDC_SESSIONS_URL=https://api.qualcomm.com/deviceloud/v1/sessions"
)

set "QDC_SESSIONS_FILE=%TEMP%\qdc_sessions.json"

rem QDC device ID changes with each cloud session.
rem Optionally pass the device ID as the first argument to skip the API lookup:
rem   connect-qdc-sdp.bat sa630771
if not "%~1"=="" (
    set "QDC_DEVICE_ID=%~1"
    set "ADB_REMOTE_HOST=%QDC_DEVICE_ID%.sa.svc.cluster.local"
    echo Using manually specified QDC device ID: %~1
    goto :config_done
)

echo Fetching active QDC session from API...
curl -s -X GET "%QDC_SESSIONS_URL%" ^
  -H "accept: application/json" ^
  -H "Authorization: %QDC_API_KEY%" ^
  -H "X-QCOM-TokenType: apikey" ^
  -H "X-QCOM-AppName: QDCUser" ^
  -H "X-QCOM-ClientType: appName" ^
  -H "X-QCOM-TracingId: 4cf76b2b-bfa4-4f27-91da-378bf2a52288" ^
  -o "%QDC_SESSIONS_FILE%"
if errorlevel 1 (
    echo ERROR: Failed to call QDC sessions API.
    goto :fail
)

for /f "delims=" %%I in ('powershell -NoProfile -Command "$j=(Get-Content '%QDC_SESSIONS_FILE%' -Raw | ConvertFrom-Json).data; $s=$j | Where-Object {$_.state -eq 'Running' -and $_.sshConfigs.Count -gt 0} | Select-Object -First 1; if($s){'sa'+$s.deviceCloudSessionId}else{''}"') do set "QDC_DEVICE_ID=%%I"

if "%QDC_DEVICE_ID%"=="" (
    echo ERROR: No running QDC session with SSH config found.
    echo        Start a QDC session at https://qdc.qualcomm.com before running this script.
    goto :fail
)
set "ADB_REMOTE_HOST=%QDC_DEVICE_ID%.sa.svc.cluster.local"
echo Auto-discovered QDC device ID: %QDC_DEVICE_ID%

:config_done

rem Prefer locally built JARs in this project; fall back to Downloads.
set "LOCAL_ANDROID_JAR=%SCRIPT_DIR%tunnel-android-reverse-1.0.0.jar"
set "LOCAL_WINDOWS_JAR=%SCRIPT_DIR%tunnel-windows-reverse-1.0.0.jar"
set "DOWNLOAD_ANDROID_JAR=%USERPROFILE%\Downloads\tunnel-android-reverse-1.0.0.jar"
set "DOWNLOAD_WINDOWS_JAR=%USERPROFILE%\Downloads\tunnel-windows-reverse-1.0.0.jar"

set "ANDROID_REMOTE_DIR=/data/local/tmp"
set "ANDROID_REMOTE_JAR=tunnel-android-reverse-1.0.0.jar"

set "STARTUP_DELAY_SECONDS=5"

echo ============================================================
echo QDC SDP connection launcher
echo ============================================================
echo.

call :require_tool ssh || goto :fail
call :require_tool adb || goto :fail
call :require_tool java || goto :fail

call :resolve_file "%LOCAL_ANDROID_JAR%" "%DOWNLOAD_ANDROID_JAR%" ANDROID_JAR || goto :fail
call :resolve_file "%LOCAL_WINDOWS_JAR%" "%DOWNLOAD_WINDOWS_JAR%" WINDOWS_JAR || goto :fail

echo Using Android tunnel JAR: "%ANDROID_JAR%"
echo Using Windows tunnel JAR: "%WINDOWS_JAR%"
echo Connection category: %CONNECTION_CATEGORY%
echo SSH host: %SSH_USER_HOST%
echo SSH private key: "%SSH_KEY%"
echo ADB remote host: %ADB_REMOTE_HOST%
echo.

echo [1/7] Cleaning up existing local ADB server and port 5037 users...
adb kill-server >nul 2>nul
call :kill_port 5037

echo [2/7] Starting ADB discovery SSH tunnel in a new window...
set "SSH2_ATTEMPT=0"
:ssh2_retry
set /a SSH2_ATTEMPT+=1
if !SSH2_ATTEMPT! gtr 1 (
    echo Retrying ADB discovery SSH tunnel ^(attempt !SSH2_ATTEMPT!/3^)...
    call :kill_port 5037
)
start "QDC SDP - ADB discovery tunnel" cmd /k ssh -i "%SSH_KEY%" -o IdentitiesOnly=yes -L 5037:%ADB_REMOTE_HOST%:5037 -N %SSH_USER_HOST%
call :sleep %STARTUP_DELAY_SECONDS%
netstat -ano -p tcp | findstr /r /c:":5037 .*LISTENING" >nul 2>nul
if errorlevel 1 (
    if !SSH2_ATTEMPT! lss 3 goto :ssh2_retry
    echo ERROR: ADB discovery SSH tunnel failed after 3 attempts - port 5037 is not listening.
    echo        Check SSH key, device ID ^(%QDC_DEVICE_ID%^), and network connectivity.
    goto :fail
)
echo Port 5037 is listening - ADB discovery SSH tunnel OK.
echo.
echo Discovered ADB devices:
adb devices
echo.

echo [3/7] Forwarding Linux ADB ports to Android device...
adb forward tcp:8900 tcp:8900 || goto :fail
adb forward tcp:8902 tcp:8902 || goto :fail

echo [4/7] Pushing Android DEX tunnel JAR to device...
adb push "%ANDROID_JAR%" "%ANDROID_REMOTE_DIR%/%ANDROID_REMOTE_JAR%" || goto :fail

echo [5/7] Starting Android websocket tunnel in a new window...
start "QDC SDP - Android websocket tunnel" cmd /k adb shell "cd %ANDROID_REMOTE_DIR% && CLASSPATH=%ANDROID_REMOTE_JAR% app_process / com.sdp.tunnel.TunnelAndroidReverse --port-map 6500:8900 --port-map 6502:8902"
call :sleep %STARTUP_DELAY_SECONDS%

echo [6/7] Starting Windows-to-Linux SDP SSH port tunnel in a new window...
set "SSH6_ATTEMPT=0"
:ssh6_retry
set /a SSH6_ATTEMPT+=1
if !SSH6_ATTEMPT! gtr 1 (
    echo Retrying SDP SSH port tunnel ^(attempt !SSH6_ATTEMPT!/3^)...
    call :kill_port 8900
    call :kill_port 8902
)
start "QDC SDP - SDP SSH port tunnel" cmd /k ssh -i "%SSH_KEY%" -o IdentitiesOnly=yes -L 8900:%ADB_REMOTE_HOST%:8900 -L 8902:%ADB_REMOTE_HOST%:8902 -N %SSH_USER_HOST%
call :sleep %STARTUP_DELAY_SECONDS%
netstat -ano -p tcp | findstr /r /c:":8900 .*LISTENING" >nul 2>nul
if errorlevel 1 (
    if !SSH6_ATTEMPT! lss 3 goto :ssh6_retry
    echo ERROR: SDP SSH port tunnel failed after 3 attempts - port 8900 is not listening.
    echo        Check SSH key, device ID ^(%QDC_DEVICE_ID%^), and network connectivity.
    goto :fail
)
netstat -ano -p tcp | findstr /r /c:":8902 .*LISTENING" >nul 2>nul
if errorlevel 1 (
    if !SSH6_ATTEMPT! lss 3 goto :ssh6_retry
    echo ERROR: SDP SSH port tunnel failed after 3 attempts - port 8902 is not listening.
    echo        Check SSH key, device ID ^(%QDC_DEVICE_ID%^), and network connectivity.
    goto :fail
)
echo Ports 8900 and 8902 are listening - SDP SSH port tunnel OK.

echo [7/7] Starting Windows websocket tunnel in a new window...
start "QDC SDP - Windows websocket tunnel" cmd /k java -jar "%WINDOWS_JAR%" --remote-host 127.0.0.1 --port-map 8900:6500 --port-map 8902:6502

echo.
echo ============================================================
echo Launcher completed.
echo.
echo Keep the opened tunnel windows running.
echo Verify the Android websocket tunnel window shows connections.
echo Then open Snapdragon Profiler; it should discover the device.
echo ============================================================
echo.
pause
exit /b 0

:require_tool
where %~1 >nul 2>nul
if errorlevel 1 (
    echo ERROR: Required tool "%~1" was not found in PATH.
    exit /b 1
)
exit /b 0

:kill_port
set "PORT=%~1"
set "FOUND_PORT_PROCESS=0"

for /f "tokens=5" %%P in ('netstat -ano -p tcp ^| findstr /r /c:":%PORT% .*LISTENING"') do (
    set "FOUND_PORT_PROCESS=1"
    echo Killing process %%P listening on TCP port %PORT%...
    taskkill /F /PID %%P >nul 2>nul
)

if "%FOUND_PORT_PROCESS%"=="0" (
    echo No process found listening on TCP port %PORT%.
)
exit /b 0

:resolve_file
set "PRIMARY=%~1"
set "FALLBACK=%~2"
set "OUTPUT_VAR=%~3"

if exist "%PRIMARY%" (
    set "%OUTPUT_VAR%=%PRIMARY%"
    exit /b 0
)

if exist "%FALLBACK%" (
    set "%OUTPUT_VAR%=%FALLBACK%"
    exit /b 0
)

echo ERROR: Could not find required file:
echo   "%PRIMARY%"
echo or fallback:
echo   "%FALLBACK%"
echo.
echo Build the JARs with:
echo   cd /d "%SCRIPT_DIR%"
echo   gradlew.bat windowsJar dexJar
echo or download them to %USERPROFILE%\Downloads.
exit /b 1

:sleep
timeout /t %~1 /nobreak >nul
exit /b 0

:fail
echo.
echo ============================================================
echo Failed to start QDC SDP connection workflow.
echo Review the error above, fix it, then run this script again.
echo ============================================================
echo.
pause
exit /b 1