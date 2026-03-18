#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LIGHTMAN Agent - Local Setup Script (no git clone needed)
.DESCRIPTION
    Use this when you've already copied the lightman-app01 folder to the machine.
    Run this script ONCE as Administrator on each kiosk device.
.PARAMETER ServerUrl
    URL of the central LIGHTMAN server. Default: http://192.168.0.253:3401
.PARAMETER DeviceSlug
    Unique slug for this device (e.g., lobby-screen-01)
.PARAMETER ShutdownCron
    Cron expression for daily shutdown. Default: "0 19 * * *" (7 PM)
.PARAMETER StartupCron
    Cron expression for daily startup (reference only). Default: "0 8 * * *" (8 AM)
.PARAMETER Timezone
    Timezone for schedules. Default: "Asia/Kolkata"
.PARAMETER SkipService
    Skip NSSM service installation (for testing/dev). Agent must be started manually.
.EXAMPLE
    .\setup-device-local.ps1 -DeviceSlug "kiosk-01"
.EXAMPLE
    .\setup-device-local.ps1 -ServerUrl "http://192.168.0.253:3401" -DeviceSlug "kiosk-01" -SkipService
#>

param(
    [string]$ServerUrl = "http://192.168.0.253:3401",

    [Parameter(Mandatory=$true)]
    [string]$DeviceSlug,

    [string]$ShutdownCron = "0 19 * * *",
    [string]$StartupCron = "0 8 * * *",
    [string]$Timezone = "Asia/Kolkata",
    [switch]$SkipService
)

$ErrorActionPreference = "Stop"
$ServiceName = "LightmanAgent"

# Auto-detect: find the agent folder relative to this script
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentDir = $ScriptDir  # This script lives in the agent/ folder

# Verify we're in the right place
if (!(Test-Path "$AgentDir\package.json")) {
    Write-Host "ERROR: Cannot find package.json in $AgentDir" -ForegroundColor Red
    Write-Host "Make sure this script is inside the agent/ folder of the project." -ForegroundColor Red
    exit 1
}

$InstallDir = Split-Path -Parent $AgentDir  # project root
$NssmDir = "$InstallDir\nssm"

$totalSteps = if ($SkipService) { 4 } else { 6 }

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  LIGHTMAN Agent - Local Device Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Server:     $ServerUrl"
Write-Host "  Device:     $DeviceSlug"
Write-Host "  Agent dir:  $AgentDir"
Write-Host "  Service:    $(if ($SkipService) { 'SKIPPED (manual start)' } else { 'Will install' })"
Write-Host ""

# ============================================================
# 1. CONFIGURE WAKE-ON-LAN
# ============================================================
Write-Host "[1/$totalSteps] Configuring Wake-on-LAN..." -ForegroundColor Yellow

# Disable Fast Startup (breaks WOL)
Write-Host "  - Disabling Fast Startup..."
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null

# Enable WOL on all Ethernet/Wi-Fi adapters
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and ($_.InterfaceDescription -match "Ethernet|Wi-Fi|Wireless|Realtek|Intel") }
foreach ($adapter in $adapters) {
    Write-Host "  - Enabling WOL on: $($adapter.Name) ($($adapter.InterfaceDescription))"
    try {
        Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName "Wake on Magic Packet" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
        Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName "Wake on Pattern Match" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
        powercfg /deviceenablewake "$($adapter.InterfaceDescription)" 2>$null
    } catch {
        Write-Host "    Warning: Could not configure WOL on $($adapter.Name): $_" -ForegroundColor DarkYellow
    }
}

$primaryAdapter = $adapters | Select-Object -First 1
if ($primaryAdapter) {
    Write-Host "  - Primary MAC: $($primaryAdapter.MacAddress)" -ForegroundColor Green
} else {
    Write-Host "  - WARNING: No active network adapter found!" -ForegroundColor Red
}
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 2. CHECK/INSTALL NODE.JS
# ============================================================
Write-Host "[2/$totalSteps] Checking Node.js..." -ForegroundColor Yellow

$nodeVersion = $null
try { $nodeVersion = (node --version 2>$null) } catch {}

if ($nodeVersion) {
    Write-Host "  Node.js $nodeVersion already installed." -ForegroundColor Green
} else {
    Write-Host "  Node.js not found. Installing..."
    $nodeInstaller = "$env:TEMP\node-setup.msi"
    $nodeUrl = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-x64.msi"
    Write-Host "  Downloading Node.js v20.18.0..."
    Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeInstaller -UseBasicParsing
    Write-Host "  Installing (this may take a minute)..."
    Start-Process msiexec.exe -ArgumentList "/i `"$nodeInstaller`" /qn /norestart" -Wait -NoNewWindow
    Remove-Item $nodeInstaller -Force
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    $nodeVersion = (node --version 2>$null)
    if ($nodeVersion) {
        Write-Host "  Node.js $nodeVersion installed successfully." -ForegroundColor Green
    } else {
        Write-Host "  ERROR: Node.js installation failed!" -ForegroundColor Red
        exit 1
    }
}

# ============================================================
# 3. INSTALL AGENT DEPENDENCIES
# ============================================================
Write-Host "[3/$totalSteps] Installing agent dependencies..." -ForegroundColor Yellow

Push-Location $AgentDir
$ErrorActionPreference = "Continue"
npm install --omit=dev 2>&1 | Out-Host
$ErrorActionPreference = "Stop"
Pop-Location
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 4. GENERATE AGENT CONFIG
# ============================================================
Write-Host "[4/$totalSteps] Generating agent configuration..." -ForegroundColor Yellow

$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (!(Test-Path $chromePath)) {
    $chromePath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
}
if (!(Test-Path $chromePath)) {
    $chromePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
}

$kioskDataDir = "$InstallDir\chrome-kiosk"
if (!(Test-Path $kioskDataDir)) {
    New-Item -ItemType Directory -Path $kioskDataDir -Force | Out-Null
}

$displayUrl = "$ServerUrl/display/$DeviceSlug"

$config = @{
    serverUrl = $ServerUrl
    deviceSlug = $DeviceSlug
    healthIntervalMs = 60000
    logLevel = "info"
    logFile = "agent.log"
    identityFile = ".lightman-identity.json"
    localServices = $false
    kiosk = @{
        browserPath = $chromePath
        defaultUrl = $displayUrl
        extraArgs = @(
            "--start-fullscreen",
            "--disable-translate",
            "--disable-extensions",
            "--user-data-dir=$kioskDataDir"
        )
        pollIntervalMs = 10000
        maxCrashesInWindow = 10
        crashWindowMs = 300000
    }
    powerSchedule = @{
        shutdownCron = $ShutdownCron
        startupCron = $StartupCron
        timezone = $Timezone
        shutdownWarningSeconds = 60
    }
} | ConvertTo-Json -Depth 4

[System.IO.File]::WriteAllText("$AgentDir\agent.config.json", $config, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  Config written to: $AgentDir\agent.config.json" -ForegroundColor Green
Write-Host "  Kiosk URL: $displayUrl"
Write-Host "  Browser: $chromePath"

# ============================================================
# 5. INSTALL NSSM + WINDOWS SERVICE (skip with -SkipService)
# ============================================================
if (!$SkipService) {
    Write-Host "[5/$totalSteps] Setting up Windows Service..." -ForegroundColor Yellow

    if (!(Test-Path $NssmDir)) {
        New-Item -ItemType Directory -Path $NssmDir -Force | Out-Null
    }

    $nssmExe = "$NssmDir\nssm.exe"

    # Check if nssm.exe is bundled in the repo (place it at lightman-app01/nssm/nssm.exe)
    if (!(Test-Path $nssmExe)) {
        Write-Host "  Downloading NSSM..."
        $nssmZip = "$env:TEMP\nssm.zip"
        $ErrorActionPreference = "Continue"
        try {
            Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip -UseBasicParsing -TimeoutSec 15
        } catch {
            Write-Host "  NSSM download failed." -ForegroundColor DarkYellow
            $nssmZip = $null
        }
        $ErrorActionPreference = "Stop"

        if ($nssmZip -and (Test-Path $nssmZip)) {
            Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm-extract" -Force
            Copy-Item "$env:TEMP\nssm-extract\nssm-2.24\win64\nssm.exe" $nssmExe
            Remove-Item $nssmZip -Force
            Remove-Item "$env:TEMP\nssm-extract" -Recurse -Force
            Write-Host "  NSSM downloaded." -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "  Could not download NSSM automatically." -ForegroundColor Red
            Write-Host "  To fix: download nssm-2.24.zip from https://nssm.cc" -ForegroundColor Yellow
            Write-Host "  Extract nssm.exe (win64) to: $nssmExe" -ForegroundColor Yellow
            Write-Host "  Then re-run this script." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Skipping service installation. Start agent manually:" -ForegroundColor Yellow
            Write-Host "    cd $AgentDir && npx tsx src/index.ts" -ForegroundColor White
            $SkipService = $true
        }
    }

    if (!$SkipService -and (Test-Path $nssmExe)) {
        # Remove existing service if present
        $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($existingService) {
            Write-Host "  Removing existing service..."
            & $nssmExe stop $ServiceName 2>$null
            & $nssmExe remove $ServiceName confirm 2>$null
            Start-Sleep -Seconds 2
        }

        $nodePath = (Get-Command node).Source

        Write-Host "  Installing service: $ServiceName"
        & $nssmExe install $ServiceName $nodePath
        & $nssmExe set $ServiceName AppParameters "node_modules\.bin\tsx src\index.ts"
        & $nssmExe set $ServiceName AppDirectory $AgentDir
        & $nssmExe set $ServiceName DisplayName "LIGHTMAN Agent"
        & $nssmExe set $ServiceName Description "LIGHTMAN kiosk agent - display management and monitoring"
        & $nssmExe set $ServiceName Start SERVICE_AUTO_START
        & $nssmExe set $ServiceName AppStdout "$AgentDir\service-stdout.log"
        & $nssmExe set $ServiceName AppStderr "$AgentDir\service-stderr.log"
        & $nssmExe set $ServiceName AppStdoutCreationDisposition 4
        & $nssmExe set $ServiceName AppStderrCreationDisposition 4
        & $nssmExe set $ServiceName AppRotateFiles 1
        & $nssmExe set $ServiceName AppRotateBytes 5242880
        & $nssmExe set $ServiceName AppRestartDelay 5000
        & $nssmExe set $ServiceName AppExit Default Restart

        Write-Host "  Service installed." -ForegroundColor Green

        # ============================================================
        # 6. START SERVICE
        # ============================================================
        Write-Host "[6/$totalSteps] Starting agent service..." -ForegroundColor Yellow

        & $nssmExe start $ServiceName

        Start-Sleep -Seconds 5
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            Write-Host "  Service is running!" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Service may not have started. Check logs at:" -ForegroundColor DarkYellow
            Write-Host "    $AgentDir\service-stdout.log"
            Write-Host "    $AgentDir\service-stderr.log"
            Write-Host "    $AgentDir\agent.log"
        }
    }
}

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Device slug:  $DeviceSlug"
Write-Host "  Server:       $ServerUrl"
Write-Host "  Display URL:  $displayUrl"
Write-Host "  Agent dir:    $AgentDir"
if (!$SkipService) {
    Write-Host "  Service:      $ServiceName (auto-start on boot)"
}
Write-Host ""
if ($SkipService) {
    Write-Host "  To start the agent manually:" -ForegroundColor Yellow
    Write-Host "    cd $AgentDir" -ForegroundColor White
    Write-Host "    npx tsx src/index.ts" -ForegroundColor White
    Write-Host ""
}
Write-Host "  IMPORTANT: Enable Wake-on-LAN in BIOS manually!" -ForegroundColor Yellow
Write-Host "  (Usually F2/Del at boot > Power Management > WOL)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Manage service:" -ForegroundColor DarkGray
Write-Host "    nssm stop $ServiceName       # Stop" -ForegroundColor DarkGray
Write-Host "    nssm start $ServiceName      # Start" -ForegroundColor DarkGray
Write-Host "    nssm restart $ServiceName    # Restart" -ForegroundColor DarkGray
Write-Host "    nssm remove $ServiceName confirm  # Uninstall" -ForegroundColor DarkGray
Write-Host ""
