#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LIGHTMAN Agent - Kiosk Device Setup Script
.DESCRIPTION
    Installs and configures the LIGHTMAN agent on a Windows kiosk machine.
    Run this script ONCE as Administrator on each kiosk device.
.PARAMETER ServerUrl
    URL of the central LIGHTMAN server (e.g., http://192.168.1.100:3401)
.PARAMETER DeviceSlug
    Unique slug for this device (e.g., lobby-screen-01)
.PARAMETER RepoUrl
    Git repository URL to clone. Defaults to the project repo.
.PARAMETER ShutdownCron
    Cron expression for daily shutdown. Default: "0 19 * * *" (7 PM)
.PARAMETER StartupCron
    Cron expression for daily startup (reference only). Default: "0 8 * * *" (8 AM)
.PARAMETER Timezone
    Timezone for schedules. Default: "Asia/Kolkata"
.EXAMPLE
    .\setup-device.ps1 -ServerUrl "http://192.168.1.100:3401" -DeviceSlug "lobby-screen-01"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerUrl,

    [Parameter(Mandatory=$true)]
    [string]$DeviceSlug,

    [string]$RepoUrl = "https://github.com/your-org/lightman-app01.git",

    [string]$ShutdownCron = "0 19 * * *",
    [string]$StartupCron = "0 8 * * *",
    [string]$Timezone = "Asia/Kolkata"
)

$ErrorActionPreference = "Stop"
$InstallDir = "C:\ProgramData\Lightman"
$AgentDir = "$InstallDir\agent"
$NssmDir = "$InstallDir\nssm"
$ServiceName = "LightmanAgent"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  LIGHTMAN Agent - Device Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Server:     $ServerUrl"
Write-Host "  Device:     $DeviceSlug"
Write-Host "  Install to: $InstallDir"
Write-Host ""

# ============================================================
# 1. CONFIGURE WAKE-ON-LAN
# ============================================================
Write-Host "[1/7] Configuring Wake-on-LAN..." -ForegroundColor Yellow

# Disable Fast Startup (breaks WOL)
Write-Host "  - Disabling Fast Startup..."
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null

# Enable WOL on all Ethernet/Wi-Fi adapters
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and ($_.InterfaceDescription -match "Ethernet|Wi-Fi|Wireless|Realtek|Intel") }
foreach ($adapter in $adapters) {
    Write-Host "  - Enabling WOL on: $($adapter.Name) ($($adapter.InterfaceDescription))"
    try {
        # Enable Wake on Magic Packet
        Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName "Wake on Magic Packet" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
        # Enable Wake on Pattern Match (some adapters need this)
        Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName "Wake on Pattern Match" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
        # Allow device to wake computer
        $pnpDevice = Get-PnpDevice | Where-Object { $_.FriendlyName -eq $adapter.InterfaceDescription }
        if ($pnpDevice) {
            powercfg /deviceenablewake "$($adapter.InterfaceDescription)" 2>$null
        }
    } catch {
        Write-Host "    Warning: Could not configure WOL on $($adapter.Name): $_" -ForegroundColor DarkYellow
    }
}

# Report MAC address
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
Write-Host "[2/7] Checking Node.js..." -ForegroundColor Yellow

$nodeVersion = $null
try {
    $nodeVersion = (node --version 2>$null)
} catch {}

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

    # Refresh PATH
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
# 3. CHECK/INSTALL GIT
# ============================================================
Write-Host "[3/7] Checking Git..." -ForegroundColor Yellow

$gitVersion = $null
try {
    $gitVersion = (git --version 2>$null)
} catch {}

if ($gitVersion) {
    Write-Host "  $gitVersion already installed." -ForegroundColor Green
} else {
    Write-Host "  Git not found. Installing..."
    $gitInstaller = "$env:TEMP\git-setup.exe"
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe"
    Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing
    Start-Process $gitInstaller -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /COMPONENTS=`"icons,ext\reg\shellhere,assoc,assoc_sh`"" -Wait -NoNewWindow
    Remove-Item $gitInstaller -Force

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Host "  Git installed." -ForegroundColor Green
}

# ============================================================
# 4. CLONE REPO & INSTALL AGENT DEPENDENCIES
# ============================================================
Write-Host "[4/7] Setting up agent files..." -ForegroundColor Yellow

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$repoDir = "$InstallDir\lightman-app01"

if (Test-Path "$repoDir\.git") {
    Write-Host "  Repo already cloned, pulling latest..."
    Push-Location $repoDir
    git pull --ff-only 2>$null
    Pop-Location
} else {
    if (Test-Path $repoDir) {
        Remove-Item $repoDir -Recurse -Force
    }
    Write-Host "  Cloning repository..."
    git clone $RepoUrl $repoDir
}

$AgentDir = "$repoDir\agent"

Write-Host "  Installing agent dependencies..."
Push-Location $AgentDir
npm install --production 2>$null
Pop-Location

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 5. GENERATE AGENT CONFIG
# ============================================================
Write-Host "[5/7] Generating agent configuration..." -ForegroundColor Yellow

$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (!(Test-Path $chromePath)) {
    $chromePath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
}
if (!(Test-Path $chromePath)) {
    # Try Edge as fallback
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

$config | Set-Content -Path "$AgentDir\agent.config.json" -Encoding UTF8
Write-Host "  Config written to: $AgentDir\agent.config.json" -ForegroundColor Green
Write-Host "  Kiosk URL: $displayUrl"
Write-Host "  Browser: $chromePath"

# ============================================================
# 6. INSTALL NSSM (SERVICE MANAGER)
# ============================================================
Write-Host "[6/7] Setting up Windows Service..." -ForegroundColor Yellow

if (!(Test-Path $NssmDir)) {
    New-Item -ItemType Directory -Path $NssmDir -Force | Out-Null
}

$nssmExe = "$NssmDir\nssm.exe"
if (!(Test-Path $nssmExe)) {
    Write-Host "  Downloading NSSM..."
    $nssmZip = "$env:TEMP\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip -UseBasicParsing
    Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm-extract" -Force
    Copy-Item "$env:TEMP\nssm-extract\nssm-2.24\win64\nssm.exe" $nssmExe
    Remove-Item $nssmZip -Force
    Remove-Item "$env:TEMP\nssm-extract" -Recurse -Force
}

# Remove existing service if present
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "  Removing existing service..."
    & $nssmExe stop $ServiceName 2>$null
    & $nssmExe remove $ServiceName confirm 2>$null
    Start-Sleep -Seconds 2
}

# Find node.exe path
$nodePath = (Get-Command node).Source

# Install service
Write-Host "  Installing service: $ServiceName"
& $nssmExe install $ServiceName $nodePath
& $nssmExe set $ServiceName AppParameters "node_modules\.bin\tsx src\index.ts"
& $nssmExe set $ServiceName AppDirectory $AgentDir
& $nssmExe set $ServiceName DisplayName "LIGHTMAN Agent"
& $nssmExe set $ServiceName Description "LIGHTMAN museum display agent - kiosk management and monitoring"
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
# 7. START SERVICE
# ============================================================
Write-Host "[7/7] Starting agent service..." -ForegroundColor Yellow

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
Write-Host "  Service:      $ServiceName (auto-start on boot)"
Write-Host "  Agent dir:    $AgentDir"
Write-Host ""
Write-Host "  IMPORTANT: Enable Wake-on-LAN in BIOS manually!" -ForegroundColor Yellow
Write-Host "  (Usually F2/Del at boot → Power Management → WOL)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. Check admin panel at $ServerUrl - device should appear"
Write-Host "  2. Assign an app to the device from admin"
Write-Host "  3. Enable WOL in BIOS for remote wake support"
Write-Host ""
