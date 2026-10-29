@REM ============================================================================================================
@REM
@REM                   Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
@REM                                SPDX-License-Identifier: BSD-3-Clause
@REM
@REM ============================================================================================================

@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ==============================================================================
rem QDC SDP one-click connection launcher - C++ tunnel (Windows)
rem
rem Starts the SSH, ADB (Mobile) or SCP/SSH (IOT Qualcomm Linux), target tunnel, and
rem Windows host tunnel steps for Snapdragon Profiler device discovery through SDP,
rem using the native C++ tunnel binaries (qdc-tunnel-target / qdc-tunnel-host.exe) instead
rem of the Java JARs.
rem
rem Why C++: the device-side binary is a single small static ELF (~200 KB) that runs
rem on both QDC Android and QDC Qualcomm Linux (IoT). Deploying it is one quick push
rem with no JVM/JRE/DEX bundle, so target setup is much faster than the Java path.
rem
rem REQUIRED environment variables (or set them in config.local.bat):
rem   QDC_API_KEY       - Your QDC API key
rem   SSH_KEY           - Path to your SSH private key (e.g. C:\Users\you\.ssh\id_ed25519)
rem
rem OPTIONAL environment variables:
rem   SSH_USER_HOST        - SSH user@host (auto-detected from DNS servers if not set)
rem   QDC_SESSIONS_URL     - QDC sessions API endpoint (has a default)
rem   QDC_CHIPSET_CATEGORY - Mobile or IOT; used when passing device ID manually
rem   HOST_BIN             - Explicit path to qdc-tunnel-host.exe (host binary)
rem   TARGET_BIN           - Explicit path to qdc-tunnel-target (device binary, aarch64)
rem   ADB_PATH             - Full path to adb.exe (Mobile only). Set this when adb is not
rem                          on PATH; otherwise the launcher uses "adb" from PATH.
rem
rem IOT-SPECIFIC optional variables (only used when QDC_CHIPSET_CATEGORY=IOT):
rem   IOT_TARGET_SSH       - SSH user@host for the IoT Linux device
rem   IOT_SSH_KEY          - SSH private key for the IoT device (default: SSH_KEY)
rem   IOT_REMOTE_DIR       - Remote directory for deployment (default: /tmp/qdc-sdp)
rem   IOT_TARGET_ARCH      - Target CPU architecture: x64 or aarch64 (auto-detected)
rem   IOT_TARGET_PASSWORD  - Device root password. When set, device ssh/scp use password
rem                          auth with no prompts (via SSH_ASKPASS; Windows OpenSSH 8.6+).
rem   IOT_TARGET_USER      - Device login user (default: root)
rem ==============================================================================

set "CONNECTION_CATEGORY=QDC Cloud device"

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
if not defined SSH_USER_HOST (
    set "SSH_USER_HOST=sshtunnel@ssh-cn.qdc.qualcomm.com"
    for /f "delims=" %%S in ('ipconfig /all ^| findstr /i "DNS Servers"') do (
        echo %%S | findstr /i "qualcomm.com" >nul && set "SSH_USER_HOST=sshtunnel@ssh-cn.qdc-internal.qualcomm.com"
    )
    echo Auto-detected SSH host: !SSH_USER_HOST!
)
if not defined QDC_API_KEY (
    echo ERROR: QDC_API_KEY is not set.
    echo        Set the QDC_API_KEY environment variable or define it in config.local.bat.
    goto :fail
)

if not defined QDC_SESSIONS_URL (
    set "QDC_SESSIONS_URL=https://api.qualcomm.com/deviceloud/v1/sessions"
)

set "QDC_SESSIONS_FILE=%TEMP%\qdc_sessions.json"

if not "%~1"=="" (
    set "QDC_DEVICE_ID=%~1"
    set "ADB_REMOTE_HOST=!QDC_DEVICE_ID!.sa.svc.cluster.local"
    if not defined QDC_CHIPSET_CATEGORY set "QDC_CHIPSET_CATEGORY=Mobile"
    echo Using manually specified QDC device ID: %~1
    echo Using chipset category: !QDC_CHIPSET_CATEGORY! ^(manual/default^)
    goto :config_done
)

echo Fetching active QDC session from API...
curl -s -X GET "%QDC_SESSIONS_URL%" ^
  -H "accept: application/json" ^
  -H "Authorization: %QDC_API_KEY%" ^
  -H "X-QCOM-TokenType: apikey" ^
  -H "X-QCOM-AppName: QDCUser" ^
  -H "X-QCOM-ClientType: appName" ^
  -H "X-QCOM-TracingId: qdc-sdp-remote-profiling" ^
  -o "%QDC_SESSIONS_FILE%"
if errorlevel 1 (
    echo ERROR: Failed to call QDC sessions API.
    goto :fail
)

for /f "tokens=1,* delims=|" %%A in ('powershell -NoProfile -Command "$j=(Get-Content '%QDC_SESSIONS_FILE%' -Raw | ConvertFrom-Json).data; $s=$j | Where-Object {$_.state -eq 'Running' -and $_.sshConfigs.Count -gt 0} | Select-Object -First 1; if($s){$cat=''; if($s.targets -and $s.targets.Count -gt 0){$cat=$s.targets[0].chipsetCategory}; 'sa'+$s.deviceCloudSessionId+'|'+$cat}else{''}"') do (
    set "QDC_DEVICE_ID=%%A"
    set "QDC_CHIPSET_CATEGORY=%%B"
)

if "%QDC_DEVICE_ID%"=="" (
    echo ERROR: No running QDC session with SSH config found.
    echo        Start a QDC session at https://qdc.qualcomm.com before running this script.
    goto :fail
)
if "%QDC_CHIPSET_CATEGORY%"=="" (
    echo WARNING: chipsetCategory was not present in API response; defaulting to Mobile.
    set "QDC_CHIPSET_CATEGORY=Mobile"
)
set "ADB_REMOTE_HOST=%QDC_DEVICE_ID%.sa.svc.cluster.local"
echo Auto-discovered QDC device ID: %QDC_DEVICE_ID%
echo API chipset category: %QDC_CHIPSET_CATEGORY%

:config_done

set "ANDROID_REMOTE_DIR=/data/local/tmp"
set "STARTUP_DELAY_SECONDS=5"

rem --- Resolve adb (Mobile only). Honor ADB_PATH when adb is not on PATH. ---
if defined ADB_PATH (
    set "ADB=%ADB_PATH%"
) else (
    set "ADB=adb"
)

rem --- Detect host CPU architecture (selects the matching host binary) ---
rem PROCESSOR_ARCHITECTURE is ARM64 on Windows-on-ARM, AMD64 on x64. Under a
rem 32-bit shell on 64-bit Windows, PROCESSOR_ARCHITEW6432 holds the real arch.
set "HOST_ARCH=x86_64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "HOST_ARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "HOST_ARCH=arm64"
echo Detected host CPU: %PROCESSOR_ARCHITECTURE% (using qdc-tunnel-host-%HOST_ARCH%.exe)

echo ============================================================
echo QDC SDP connection launcher (C++ tunnel)
echo ============================================================
echo.

call :require_tool ssh || goto :fail
call :require_tool curl || goto :fail

call :resolve_bin HOST_BIN "%SCRIPT_DIR%qdc-tunnel-host-%HOST_ARCH%.exe" "%SCRIPT_DIR%bin\qdc-tunnel-host-%HOST_ARCH%.exe" "%SCRIPT_DIR%src\build\win\qdc-tunnel-host.exe" || goto :fail
call :resolve_bin TARGET_BIN "%SCRIPT_DIR%src\build\target\qdc-tunnel-target" "%SCRIPT_DIR%bin\qdc-tunnel-target" "%SCRIPT_DIR%qdc-tunnel-target" || goto :fail

echo Using Target binary: "%TARGET_BIN%"
echo Using Host binary:   "%HOST_BIN%"
echo Connection category: %CONNECTION_CATEGORY%
echo QDC chipset category: %QDC_CHIPSET_CATEGORY%
echo SSH host: %SSH_USER_HOST%
echo SSH private key: "%SSH_KEY%"
echo ADB remote host: %ADB_REMOTE_HOST%
echo.

if /i "%QDC_CHIPSET_CATEGORY%"=="IOT" goto :iot_branch

rem ======================================================================
rem Branch: Mobile / Android device (ADB-based workflow)
rem ======================================================================

call :require_adb || goto :fail

echo [1/6] Cleaning up existing local ADB server and port 5037 users...
"%ADB%" kill-server >nul 2>nul
call :kill_port 5037

echo [2/6] Starting ADB discovery SSH tunnel in a new window...
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
"%ADB%" devices
echo.

echo [3/6] Forwarding Linux ADB ports to Android device...
"%ADB%" forward tcp:8927 tcp:8927 || goto :fail
"%ADB%" forward tcp:8929 tcp:8929 || goto :fail

echo [4/6] Pushing qdc-tunnel-target to device and making it executable...
"%ADB%" push "%TARGET_BIN%" "%ANDROID_REMOTE_DIR%/qdc-tunnel-target" || goto :fail
"%ADB%" shell "chmod 755 %ANDROID_REMOTE_DIR%/qdc-tunnel-target" || goto :fail
"%ADB%" shell "pkill -f %ANDROID_REMOTE_DIR%/qdc-tunnel-target" >nul 2>nul

echo [5/6] Starting Target tunnel in a new window...
start "QDC SDP - Target tunnel" cmd /k ""%ADB%" shell "%ANDROID_REMOTE_DIR%/qdc-tunnel-target --port-map 8896:8927 --port-map 8898:8929""
call :sleep %STARTUP_DELAY_SECONDS%

echo [6/6] Starting Host-to-Target SDP SSH port tunnel + Host tunnel...
set "SSH6_ATTEMPT=0"
:ssh6_retry
set /a SSH6_ATTEMPT+=1
if !SSH6_ATTEMPT! gtr 1 (
    echo Retrying SDP SSH port tunnel ^(attempt !SSH6_ATTEMPT!/3^)...
    call :kill_port 8927
    call :kill_port 8929
)
start "QDC SDP - SDP SSH port tunnel" cmd /k ssh -i "%SSH_KEY%" -o IdentitiesOnly=yes -L 8927:%ADB_REMOTE_HOST%:8927 -L 8929:%ADB_REMOTE_HOST%:8929 -L 8900:%ADB_REMOTE_HOST%:8900 -L 8902:%ADB_REMOTE_HOST%:8902 -L 8904:%ADB_REMOTE_HOST%:8904 -L 8906:%ADB_REMOTE_HOST%:8906 -L 8908:%ADB_REMOTE_HOST%:8908   -L 8910:%ADB_REMOTE_HOST%:8910   -L 8912:%ADB_REMOTE_HOST%:8912   -L 8914:%ADB_REMOTE_HOST%:8914   -L 8916:%ADB_REMOTE_HOST%:8916  -L 8918:%ADB_REMOTE_HOST%:8918   -L 8920:%ADB_REMOTE_HOST%:8920   -L 8922:%ADB_REMOTE_HOST%:8922   -L 8924:%ADB_REMOTE_HOST%:8924  -L 8926:%ADB_REMOTE_HOST%:8926 -N %SSH_USER_HOST%
call :sleep %STARTUP_DELAY_SECONDS%
netstat -ano -p tcp | findstr /r /c:":8927 .*LISTENING" >nul 2>nul
if errorlevel 1 (
    if !SSH6_ATTEMPT! lss 3 goto :ssh6_retry
    echo ERROR: SDP SSH port tunnel failed after 3 attempts - port 8927 is not listening.
    goto :fail
)
netstat -ano -p tcp | findstr /r /c:":8929 .*LISTENING" >nul 2>nul
if errorlevel 1 (
    if !SSH6_ATTEMPT! lss 3 goto :ssh6_retry
    echo ERROR: SDP SSH port tunnel failed after 3 attempts - port 8929 is not listening.
    goto :fail
)
echo Ports 8927 and 8929 are listening - SDP SSH port tunnel OK.

start "QDC SDP - Host tunnel" cmd /k ""%HOST_BIN%" --remote-host 127.0.0.1 --port-map 8927:8896 --port-map 8929:8898"

goto :done

rem ======================================================================
rem IOT Branch: Deploy and run tunnel on remote IoT Linux device via SSH
rem ======================================================================
:iot_branch

if not defined IOT_SSH_KEY set "IOT_SSH_KEY=%SSH_KEY%"
if not defined IOT_REMOTE_DIR set "IOT_REMOTE_DIR=/tmp/qdc-sdp"
if not defined IOT_LOCAL_SSH_PORT set "IOT_LOCAL_SSH_PORT=2222"
if not defined IOT_TARGET_USER set "IOT_TARGET_USER=root"
if not defined IOT_TARGET_PASSWORD set "IOT_TARGET_PASSWORD="

set "IOT_AUTH_OPTS=-i "!IOT_SSH_KEY!" -o IdentitiesOnly=yes"
set "IOT_AUTH_DESC=key !IOT_SSH_KEY!"
if not "!IOT_TARGET_PASSWORD!"=="" (
    set "IOT_AUTH_OPTS=-o PreferredAuthentications=password -o PubkeyAuthentication=no"
    set "IOT_AUTH_DESC=password [from IOT_TARGET_PASSWORD]"
    set "IOT_ASKPASS=%TEMP%\qdc-askpass.cmd"
    > "%TEMP%\qdc-askpass.cmd" echo @echo !IOT_TARGET_PASSWORD!
    set "SSH_ASKPASS=%TEMP%\qdc-askpass.cmd"
    set "SSH_ASKPASS_REQUIRE=force"
)

echo.
echo IoT Qualcomm Linux device workflow
echo   QDC SSH host:    %SSH_USER_HOST%
echo   Device host:     %ADB_REMOTE_HOST%
echo   IoT SSH user:    !IOT_TARGET_USER!
echo   IoT device auth: !IOT_AUTH_DESC!
echo   Local SSH port:  !IOT_LOCAL_SSH_PORT! ^(forwarded to device:22^)
echo   Remote dir:      !IOT_REMOTE_DIR!
echo.

rem --- [IOT 1/6] Establish SSH tunnel to device port 22 ---
echo [IOT 1/6] Starting SSH tunnel to device SSH port in a new window...
call :kill_port !IOT_LOCAL_SSH_PORT!
start "QDC SDP - IoT SSH tunnel (port 22)" cmd /k ssh -i "%SSH_KEY%" -o IdentitiesOnly=yes -L !IOT_LOCAL_SSH_PORT!:%ADB_REMOTE_HOST%:22 -N %SSH_USER_HOST%
call :sleep %STARTUP_DELAY_SECONDS%

netstat -ano -p tcp | findstr /r /c:":!IOT_LOCAL_SSH_PORT! .*LISTENING" >nul 2>nul
if errorlevel 1 (
    echo ERROR: SSH tunnel to device port 22 failed - local port !IOT_LOCAL_SSH_PORT! is not listening.
    echo        Check SSH key and network connectivity to %SSH_USER_HOST%.
    goto :fail
)
echo Port !IOT_LOCAL_SSH_PORT! is listening - SSH tunnel to device OK.
echo.

set "IOT_SSH_OPTS=!IOT_AUTH_OPTS! -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=NUL -p !IOT_LOCAL_SSH_PORT!"
set "IOT_SCP_OPTS=!IOT_AUTH_OPTS! -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=NUL -P !IOT_LOCAL_SSH_PORT!"
set "IOT_TARGET_SSH=!IOT_TARGET_USER!@localhost"

rem --- [IOT 2/6] Detect target architecture (informational; bundled binary is aarch64) ---
echo [IOT 2/6] Detecting target architecture...
if defined IOT_TARGET_ARCH (
    echo Using manually specified IOT_TARGET_ARCH: !IOT_TARGET_ARCH!
) else (
    for /f "delims=" %%A in ('ssh !IOT_SSH_OPTS! !IOT_TARGET_SSH! "uname -m" 2^>nul') do (
        set "RAW_ARCH=%%A"
    )
    if "!RAW_ARCH!"=="aarch64" (
        echo Detected target architecture: aarch64
    ) else if "!RAW_ARCH!"=="x86_64" (
        echo WARNING: target reports x86_64 but the bundled qdc-tunnel-target is aarch64.
        echo          Build an x86_64 device binary and set TARGET_BIN.
    ) else (
        echo WARNING: could not detect target architecture ^(got: "!RAW_ARCH!"^); assuming aarch64.
    )
)

rem --- [IOT 3/6] Deploy the tunnel binary via SCP (single small static ELF - no JRE) ---
echo [IOT 3/6] Deploying qdc-tunnel-target to IoT device...
ssh !IOT_SSH_OPTS! !IOT_TARGET_SSH! "mkdir -p !IOT_REMOTE_DIR!"
scp !IOT_SCP_OPTS! "%TARGET_BIN%" !IOT_TARGET_SSH!:!IOT_REMOTE_DIR!/qdc-tunnel-target
if errorlevel 1 (
    echo ERROR: Failed to SCP qdc-tunnel-target to IoT device.
    goto :fail
)
ssh !IOT_SSH_OPTS! !IOT_TARGET_SSH! "chmod 755 !IOT_REMOTE_DIR!/qdc-tunnel-target"
echo Deployment complete.

rem --- [IOT 4/6] Start Target tunnel on IoT device ---
echo [IOT 4/6] Starting Target tunnel on IoT device in a new window...
ssh !IOT_SSH_OPTS! !IOT_TARGET_SSH! "pgrep -f !IOT_REMOTE_DIR!/qdc-tunnel-target >/dev/null 2>&1"
if not errorlevel 1 (
    echo   Existing target tunnel found on device - killing it...
    ssh !IOT_SSH_OPTS! !IOT_TARGET_SSH! "pkill -f !IOT_REMOTE_DIR!/qdc-tunnel-target"
    call :sleep 2
)
start "QDC SDP - IoT Target tunnel" cmd /k ssh !IOT_SSH_OPTS! !IOT_TARGET_SSH! "!IOT_REMOTE_DIR!/qdc-tunnel-target --port-map 8896:8927 --port-map 8898:8929"
call :sleep %STARTUP_DELAY_SECONDS%

rem --- [IOT 5/6] Start SSH port tunnel (8927/8929) via QDC SSH host ---
echo [IOT 5/6] Starting Host-to-Target SDP SSH port tunnel in a new window...
set "SSH_IOT6_ATTEMPT=0"
:ssh_iot6_retry
set /a SSH_IOT6_ATTEMPT+=1
if !SSH_IOT6_ATTEMPT! gtr 1 (
    echo Retrying SDP SSH port tunnel ^(attempt !SSH_IOT6_ATTEMPT!/3^)...
    call :kill_port 8927
    call :kill_port 8929
)
start "QDC SDP - SDP SSH port tunnel" cmd /k ssh -i "%SSH_KEY%" -o IdentitiesOnly=yes -L 8927:%ADB_REMOTE_HOST%:8927 -L 8929:%ADB_REMOTE_HOST%:8929 -N %SSH_USER_HOST%
call :sleep %STARTUP_DELAY_SECONDS%
netstat -ano -p tcp | findstr /r /c:":8927 .*LISTENING" >nul 2>nul
if errorlevel 1 (
    if !SSH_IOT6_ATTEMPT! lss 3 goto :ssh_iot6_retry
    echo ERROR: SDP SSH port tunnel failed after 3 attempts - port 8927 is not listening.
    goto :fail
)
netstat -ano -p tcp | findstr /r /c:":8929 .*LISTENING" >nul 2>nul
if errorlevel 1 (
    if !SSH_IOT6_ATTEMPT! lss 3 goto :ssh_iot6_retry
    echo ERROR: SDP SSH port tunnel failed after 3 attempts - port 8929 is not listening.
    goto :fail
)
echo Ports 8927 and 8929 are listening - SDP SSH port tunnel OK.

rem --- [IOT 6/6] Start Host tunnel on Windows ---
echo [IOT 6/6] Starting Host tunnel in a new window...
start "QDC SDP - Host tunnel" cmd /k ""%HOST_BIN%" --remote-host 127.0.0.1 --port-map 8927:8896 --port-map 8929:8898"

rem --- Clear stale localhost host keys (right before SDP connects) ---
echo Clearing stale known_hosts entries for localhost:!IOT_LOCAL_SSH_PORT!...
if exist "%USERPROFILE%\.ssh\known_hosts" (
    ssh-keygen -R "[localhost]:!IOT_LOCAL_SSH_PORT!" >nul 2>nul
    ssh-keygen -R "[127.0.0.1]:!IOT_LOCAL_SSH_PORT!" >nul 2>nul
)

goto :done

rem ======================================================================
rem SUCCESS
rem ======================================================================
:done
if defined IOT_ASKPASS if exist "%IOT_ASKPASS%" del /f /q "%IOT_ASKPASS%" >nul 2>nul
echo.
echo ============================================================
echo Launcher completed.
echo.
echo Keep the opened tunnel windows running.
echo Verify the Target tunnel window shows connections.
echo Then open Snapdragon Profiler; it should discover the device.
echo ============================================================
echo.
pause
exit /b 0

rem ======================================================================
rem Helper subroutines
rem ======================================================================

:require_tool
where %~1 >nul 2>nul
if errorlevel 1 (
    echo ERROR: Required tool "%~1" was not found in PATH.
    exit /b 1
)
exit /b 0

rem Validate the resolved adb (%ADB%). If ADB_PATH was set, require the file to
rem exist; otherwise fall back to a PATH lookup for "adb".
:require_adb
if defined ADB_PATH (
    if not exist "%ADB%" (
        echo ERROR: ADB_PATH is set but adb was not found: "%ADB%"
        echo        Point ADB_PATH at adb.exe itself ^(not its folder^) in config.local.bat.
        exit /b 1
    )
    echo Using adb from ADB_PATH: "%ADB%"
    exit /b 0
)
where adb >nul 2>nul
if errorlevel 1 (
    echo ERROR: Required tool "adb" was not found in PATH.
    echo        Install platform-tools and add adb to PATH, or set ADB_PATH in config.local.bat.
    exit /b 1
)
exit /b 0

rem :resolve_bin OUTVAR cand1 cand2 cand3
rem If OUTVAR is already defined and exists, keep it; else use the first candidate
rem that exists; else try PATH by the binary's leaf name.
:resolve_bin
set "OUTVAR=%~1"
call set "CUR=%%%OUTVAR%%%"
if defined CUR (
    if exist "!CUR!" exit /b 0
    echo ERROR: %OUTVAR% is set but was not found: "!CUR!"
    exit /b 1
)
if exist "%~2" ( set "%OUTVAR%=%~2" & exit /b 0 )
if exist "%~3" ( set "%OUTVAR%=%~3" & exit /b 0 )
if exist "%~4" ( set "%OUTVAR%=%~4" & exit /b 0 )
echo ERROR: Could not find the %OUTVAR% binary. Looked in:
echo   "%~2"
echo   "%~3"
echo   "%~4"
echo.
echo Build the C++ tunnel binaries (see src\README.md):
echo   Windows host: cmake -S src -B src\build\win -DCMAKE_TOOLCHAIN_FILE=src\toolchains\x86_64-w64-mingw32.cmake -DCMAKE_BUILD_TYPE=Release ^&^& cmake --build src\build\win
echo   Device:       cmake -S src -B src\build\target -DCMAKE_TOOLCHAIN_FILE=src\toolchains\aarch64-linux-musl.cmake -DCMAKE_BUILD_TYPE=Release ^&^& cmake --build src\build\target
echo or set %OUTVAR% to an explicit path in config.local.bat.
exit /b 1

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

:sleep
timeout /t %~1 /nobreak >nul
exit /b 0

:fail
if defined IOT_ASKPASS if exist "%IOT_ASKPASS%" del /f /q "%IOT_ASKPASS%" >nul 2>nul
echo.
echo ============================================================
echo Failed to start QDC SDP connection workflow.
echo Review the error above, fix it, then run this script again.
echo ============================================================
echo.
pause
exit /b 1
