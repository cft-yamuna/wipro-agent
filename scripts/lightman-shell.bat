@echo off
REM ================================================================
REM LIGHTMAN Shell - Replaces explorer.exe as the Windows shell
REM ================================================================
REM Single source of truth: agent.config.json
REM Everything is read from that one file. No hardcoded URLs.
REM
REM Boot flow:
REM   1. Auto-login (no password)
REM   2. This script runs INSTEAD of explorer.exe
REM   3. Reads slug + browser from agent.config.json
REM   4. Waits for agent service (port 3403)
REM   5. Launches Chrome fullscreen
REM   6. If Chrome crashes, relaunches in 3 seconds (infinite loop)
REM
REM URL override: agent writes kiosk-url.txt, kills Chrome,
REM   this script picks up the new URL on relaunch.
REM ================================================================

set INSTALL_DIR=C:\Program Files\Lightman\Agent
set CONFIG_FILE=%INSTALL_DIR%\agent.config.json
set URL_FILE=C:\ProgramData\Lightman\kiosk-url.txt
set CHROME_DATA=C:\ProgramData\Lightman\chrome-kiosk
set LOG_FILE=C:\ProgramData\Lightman\logs\shell.log

REM Ensure directories exist
if not exist "C:\ProgramData\Lightman\logs" mkdir "C:\ProgramData\Lightman\logs"
if not exist "%CHROME_DATA%" mkdir "%CHROME_DATA%"

echo [%date% %time%] ===== LIGHTMAN Shell starting ===== >> "%LOG_FILE%"

REM ----------------------------------------------------------------
REM Read EVERYTHING from agent.config.json (single source of truth)
REM ----------------------------------------------------------------
set DEVICE_SLUG=
set BROWSER=
set DEFAULT_URL=

REM Wait for node.exe to be available (might not be in PATH immediately after boot)
set NODE_WAIT=0
:wait_for_node
    where node >nul 2>&1
    if %errorlevel%==0 goto node_ready
    set /a NODE_WAIT+=1
    if %NODE_WAIT% geq 30 (
        echo [%date% %time%] ERROR: node.exe not found after 30s >> "%LOG_FILE%"
        goto use_fallbacks
    )
    timeout /t 1 /nobreak >nul
    goto wait_for_node

:node_ready
REM Read slug from config
if exist "%CONFIG_FILE%" (
    for /f "delims=" %%a in ('node -e "try{console.log(JSON.parse(require('fs').readFileSync(String.raw`%CONFIG_FILE%`,'utf8')).deviceSlug)}catch(e){console.log('')}" 2^>nul') do set DEVICE_SLUG=%%a
)

REM Read browser path from config
if exist "%CONFIG_FILE%" (
    for /f "delims=" %%a in ('node -e "try{const c=JSON.parse(require('fs').readFileSync(String.raw`%CONFIG_FILE%`,'utf8'));console.log(c.kiosk&&c.kiosk.browserPath||'')}catch(e){console.log('')}" 2^>nul') do set BROWSER=%%a
)

:use_fallbacks
REM Build URL from slug
if not "%DEVICE_SLUG%"=="" (
    set DEFAULT_URL=http://localhost:3403/display/%DEVICE_SLUG%
    echo [%date% %time%] Slug from config: %DEVICE_SLUG% >> "%LOG_FILE%"
) else (
    set DEFAULT_URL=http://localhost:3403/display
    echo [%date% %time%] WARNING: No slug found in config! >> "%LOG_FILE%"
)

REM Fallback browser detection
if "%BROWSER%"=="" (
    if exist "C:\Program Files\Google\Chrome\Application\chrome.exe" (
        set "BROWSER=C:\Program Files\Google\Chrome\Application\chrome.exe"
    ) else if exist "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" (
        set "BROWSER=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) else (
        echo [%date% %time%] ERROR: Chrome not found! Falling back to explorer. >> "%LOG_FILE%"
        start explorer.exe
        exit /b 1
    )
)

echo [%date% %time%] Browser: %BROWSER% >> "%LOG_FILE%"
echo [%date% %time%] Default URL: %DEFAULT_URL% >> "%LOG_FILE%"

REM ----------------------------------------------------------------
REM Wait for the LIGHTMAN Agent service (port 3403)
REM ----------------------------------------------------------------
echo [%date% %time%] Waiting for agent service (port 3403)... >> "%LOG_FILE%"

set WAIT_COUNT=0
set MAX_WAIT=60

:wait_for_agent
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
echo [%date% %time%] Agent ready >> "%LOG_FILE%"

REM ----------------------------------------------------------------
REM Infinite Chrome loop
REM ----------------------------------------------------------------
:loop
    REM URL override: if agent wrote kiosk-url.txt, use that instead
    set URL=%DEFAULT_URL%
    if exist "%URL_FILE%" (
        set /p URL=<"%URL_FILE%"
    )

    echo [%date% %time%] Launching Chrome: %URL% >> "%LOG_FILE%"

    start /wait "" "%BROWSER%" --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --no-first-run --no-default-browser-check --start-fullscreen --disable-translate --disable-extensions --autoplay-policy=no-user-gesture-required --disable-features=TranslateUI --user-data-dir="%CHROME_DATA%" "%URL%"

    echo [%date% %time%] Chrome exited (code: %errorlevel%). Restarting in 3s... >> "%LOG_FILE%"

    timeout /t 3 /nobreak >nul

goto loop
