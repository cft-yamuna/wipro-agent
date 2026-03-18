# LIGHTMAN Agent — Windows Installer
# Run as Administrator:
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 -Slug "f-av01" -Server "http://192.168.1.100:3401"
#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$true)]
    [string]$Slug,

    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$false)]
    [string]$Timezone = "Asia/Kolkata"
)

$ErrorActionPreference = "Stop"

$InstallDir  = "C:\Program Files\Lightman\Agent"
$LogDir      = "C:\ProgramData\Lightman\logs"
$ServiceName = "LightmanAgent"
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentDir    = Split-Path -Parent $ScriptDir

Write-Host ""
Write-Host "=== LIGHTMAN Agent - Windows Installer ===" -ForegroundColor Cyan
Write-Host "  Device slug : $Slug"
Write-Host "  Server URL  : $Server"
Write-Host ""

# --- Check Node.js ---
Write-Host "[1/7] Checking Node.js..." -ForegroundColor Yellow
try {
    $nodeVersion = (node -v) -replace 'v', ''
    $major = [int]($nodeVersion.Split('.')[0])
    if ($major -lt 20) {
        throw "Node.js 20+ required, found v$nodeVersion"
    }
    Write-Host "  Found Node.js v$nodeVersion"
} catch {
    Write-Host "Error: Node.js 20+ is required. Install from https://nodejs.org" -ForegroundColor Red
    exit 1
}

# --- Create directories ---
Write-Host "[2/7] Creating directories..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir     | Out-Null
Write-Host "  Install: $InstallDir"
Write-Host "  Logs:    $LogDir"

# --- Copy agent files ---
Write-Host "[3/7] Copying agent files..." -ForegroundColor Yellow
Copy-Item -Path "$AgentDir\dist"         -Destination "$InstallDir\dist"         -Recurse -Force
Copy-Item -Path "$AgentDir\package.json" -Destination "$InstallDir\package.json" -Force
if (Test-Path "$AgentDir\package-lock.json") {
    Copy-Item -Path "$AgentDir\package-lock.json" -Destination "$InstallDir\package-lock.json" -Force
}
# Copy template so setup.ps1 can use it post-install
Copy-Item -Path "$AgentDir\agent.config.template.json" -Destination "$InstallDir\agent.config.template.json" -Force

# --- Install production dependencies ---
Write-Host "[4/7] Installing dependencies..." -ForegroundColor Yellow
Push-Location $InstallDir
try {
    npm ci --omit=dev --ignore-scripts 2>$null
} catch {
    npm install --omit=dev --ignore-scripts
}
# Install node-windows for service management
npm install node-windows
Pop-Location

# --- Configure this device (generates agent.config.json, clears any stale identity) ---
Write-Host "[5/7] Configuring device '$Slug'..." -ForegroundColor Yellow
& "$ScriptDir\setup.ps1" -Slug $Slug -Server $Server -Timezone $Timezone -InstallDir $InstallDir

# --- Install Windows service ---
Write-Host "[6/7] Installing Windows service..." -ForegroundColor Yellow
Push-Location $InstallDir
node -e "import('./dist/lib/winService.js').then(m => m.installService()).then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); })"
Pop-Location

# --- Configure firewall ---
Write-Host "[7/7] Configuring firewall..." -ForegroundColor Yellow
$ruleName = "LIGHTMAN Agent WebSocket"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existingRule) {
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Outbound `
        -Action Allow `
        -Protocol TCP `
        -RemotePort 3001 `
        -Description "Allow LIGHTMAN Agent to connect to CMS server" | Out-Null
    Write-Host "  Firewall rule created: $ruleName"
} else {
    Write-Host "  Firewall rule already exists"
}

Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Device slug : $Slug"
Write-Host "  Server      : $Server"
Write-Host "  Install dir : $InstallDir"
Write-Host "  Log dir     : $LogDir"
Write-Host "  Service     : $ServiceName"
Write-Host ""
Write-Host "  Start   :  Start-Service $ServiceName"
Write-Host "  Status  :  Get-Service $ServiceName"
Write-Host "  Logs    :  Get-Content $LogDir\agent.log -Wait"
Write-Host ""
Write-Host "The agent will now provision with the LIGHTMAN server." -ForegroundColor Cyan
Write-Host "If pairing is needed, a 6-digit code will appear in the logs." -ForegroundColor White
Write-Host ""
