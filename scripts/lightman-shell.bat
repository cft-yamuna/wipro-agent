@echo off
REM ================================================================
REM LIGHTMAN Shell - Replaces explorer.exe as the Windows shell
REM ================================================================
REM This script IS the desktop. When Windows boots:
REM   1. Auto-login happens (no password)
REM   2. This script runs INSTEAD of explorer.exe
REM   3. Chrome launches fullscreen - that's all the user sees
REM   4. If Chrome crashes, this script relaunches it in 3 seconds
REM
REM The LIGHTMAN Agent service runs separately and handles:
REM   - Server communication (WebSocket)
REM   - Health monitoring
REM   - Remote commands (navigate, restart, shutdown, etc.)
REM
REM When the agent wants to change the URL, it writes to kiosk-url.txt
REM and kills Chrome. This script detects the exit and relaunches
REM Chrome with the new URL from the file.
REM ================================================================

set INSTALL_DIR=C:\Program Files\Lightman\Agent
set CONFIG_FILE=%INSTALL_DIR%\agent.config.json
set URL_FILE=C:\ProgramData\Lightman\kiosk-url.txt
set CHROME_DATA=C:\ProgramData\Lightman\chrome-kiosk
set LOG_FILE=C:\ProgramData\Lightman\logs\shell.log
set DEFAULT_URL=http://localhost:3403/display

REM Try to read the device slug from config to build a proper default URL
if exist "%CONFIG_FILE%" (
    for /f "delims=" %%a in ('node -e "try{const c=JSON.parse(require('fs').readFileSync(String.raw`%CONFIG_FILE%`,'utf8'));console.log(c.deviceSlug||'')}catch(e){console.log('')}" 2^>nul') do set DEVICE_SLUG=%%a
)
if not "%DEVICE_SLUG%"=="" (
    set DEFAULT_URL=http://localhost:3403/display/%DEVICE_SLUG%
)

REM Ensure log directory exists
if not exist "C:\ProgramData\Lightman\logs" mkdir "C:\ProgramData\Lightman\logs"

echo [%date% %time%] ===== LIGHTMAN Shell starting ===== >> "%LOG_FILE%"

REM ----------------------------------------------------------------
REM Phase 1: Wait for the LIGHTMAN Agent service to start
REM The agent starts the static server on port 3403. Chrome needs
REM that server to be up before it can load the display page.
REM ----------------------------------------------------------------
echo [%date% %time%] Waiting for agent service... >> "%LOG_FILE%"

set WAIT_COUNT=0
set MAX_WAIT=60

:wait_for_agent
    REM Check if port 3403 is listening (agent's static server)
    netstat -an | findstr ":3403.*LISTENING" >nul 2>&1
    if %errorlevel%==0 goto agent_ready

    set /a WAIT_COUNT+=1
    if %WAIT_COUNT% geq %MAX_WAIT% (
        echo [%date% %time%] Agent not ready after %MAX_WAIT%s, launching Chrome anyway >> "%LOG_FILE%"
        goto agent_ready
    )
    timeout /t 1 /nobreak >nul
    goto wait_for_agent

:agent_ready
echo [%date% %time%] Agent ready (port 3403 listening) >> "%LOG_FILE%"

REM ----------------------------------------------------------------
REM Phase 2: Detect Chrome browser path from config
REM ----------------------------------------------------------------
set BROWSER=
if exist "%CONFIG_FILE%" (
    for /f "delims=" %%a in ('node -e "try{const c=JSON.parse(require('fs').readFileSync(String.raw`%CONFIG_FILE%`,'utf8'));console.log(c.kiosk&&c.kiosk.browserPath||'')}catch(e){console.log('')}" 2^>nul') do set BROWSER=%%a
)

REM Fallback: find Chrome in standard locations
if "%BROWSER%"=="" (
    if exist "C:\Program Files\Google\Chrome\Application\chrome.exe" (
        set "BROWSER=C:\Program Files\Google\Chrome\Application\chrome.exe"
    ) else if exist "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" (
        set "BROWSER=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) else (
        echo [%date% %time%] ERROR: Chrome not found! >> "%LOG_FILE%"
        REM Fall back to launching explorer so user isn't stuck
        start explorer.exe
        exit /b 1
    )
)

echo [%date% %time%] Browser: %BROWSER% >> "%LOG_FILE%"

REM ----------------------------------------------------------------
REM Phase 3: Infinite Chrome loop
REM If Chrome exits for ANY reason, we relaunch it.
REM The agent controls URL changes via the kiosk-url.txt sidecar file.
REM ----------------------------------------------------------------
:loop
    REM Read target URL from sidecar file (written by agent)
    set URL=%DEFAULT_URL%
    if exist "%URL_FILE%" (
        set /p URL=<"%URL_FILE%"
    )

    echo [%date% %time%] Launching Chrome: %URL% >> "%LOG_FILE%"

    REM Launch Chrome kiosk and WAIT for it to exit
    start /wait "" "%BROWSER%" --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --no-first-run --no-default-browser-check --start-fullscreen --disable-translate --disable-extensions --autoplay-policy=no-user-gesture-required --disable-features=TranslateUI --user-data-dir="%CHROME_DATA%" "%URL%"

    echo [%date% %time%] Chrome exited (code: %errorlevel%). Restarting in 3s... >> "%LOG_FILE%"

    REM Brief pause to prevent rapid crash loops eating CPU
    timeout /t 3 /nobreak >nul

goto loop
