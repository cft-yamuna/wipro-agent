# LIGHTMAN Agent — Device Setup Script (Windows)
# Generates agent.config.json for this specific device.
#
# Usage (run from agent directory or scripts directory):
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Slug "f-av01" -Server "http://192.168.1.100:3401"
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Slug "f-av01" -Server "http://192.168.1.100:3401" -Timezone "Asia/Kolkata"
#
# This script MUST be run once on every new device installation.
# It clears any cached identity so the device provisions fresh.

param(
    [Parameter(Mandatory=$true)]
    [string]$Slug,

    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$false)]
    [string]$Timezone = "Asia/Kolkata",

    [Parameter(Mandatory=$false)]
    [string]$InstallDir = $null
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentDir   = Split-Path -Parent $ScriptDir

# Default install dir: the agent folder itself (for dev) or passed explicitly
if (-not $InstallDir) {
    $InstallDir = $AgentDir
}

Write-Host ""
Write-Host "=== LIGHTMAN Agent — Device Setup ===" -ForegroundColor Cyan
Write-Host "  Slug:        $Slug"
Write-Host "  Server:      $Server"
Write-Host "  Install dir: $InstallDir"
Write-Host "  Timezone:    $Timezone"
Write-Host ""

# ── 1. Clear cached identity (CRITICAL — prevents old device credentials leaking) ──
$IdentityFile = Join-Path $InstallDir ".lightman-identity.json"
if (Test-Path $IdentityFile) {
    Remove-Item $IdentityFile -Force
    Write-Host "[OK] Cleared old identity cache (.lightman-identity.json)" -ForegroundColor Green
} else {
    Write-Host "[OK] No existing identity cache found (clean install)" -ForegroundColor DarkGray
}

# ── 2. Derive kiosk display URL from server URL ──
# Server port is replaced with 3403 (display server)
$KioskBase = $Server -replace ':\d+(/.*)?$', ':3403'
$KioskUrl  = "$KioskBase/display/$Slug"

# ── 3. Detect browser path ──
$BrowserPath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $BrowserPath)) {
    $BrowserPath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
}
if (-not (Test-Path $BrowserPath)) {
    $BrowserPath = "chromium-browser"
    Write-Host "[WARN] Chrome not found — using 'chromium-browser'" -ForegroundColor Yellow
}

$ChromeDataDir = "C:\ProgramData\Lightman\chrome-kiosk"

# ── 4. Read template ──
$TemplatePath = Join-Path $AgentDir "agent.config.template.json"
if (-not (Test-Path $TemplatePath)) {
    # If running from install dir (post-install), template should have been copied there
    $TemplatePath = Join-Path $InstallDir "agent.config.template.json"
}
if (-not (Test-Path $TemplatePath)) {
    Write-Host "[ERROR] Template not found. Expected: $TemplatePath" -ForegroundColor Red
    exit 1
}

$Template = Get-Content $TemplatePath -Raw

# ── 5. Replace placeholders ──
$BrowserEscaped    = $BrowserPath  -replace '\\', '\\'
$ChromeDirEscaped  = $ChromeDataDir -replace '\\', '\\'

$Config = $Template `
    -replace '__SERVER_URL__',    $Server `
    -replace '__DEVICE_SLUG__',   $Slug `
    -replace '__KIOSK_URL__',     $KioskUrl `
    -replace '__BROWSER_PATH__',  $BrowserEscaped `
    -replace '__CHROME_DATA_DIR__', $ChromeDirEscaped `
    -replace 'Asia/Kolkata',      $Timezone

# ── 6. Write config ──
$ConfigPath = Join-Path $InstallDir "agent.config.json"
Set-Content -Path $ConfigPath -Value $Config -Encoding UTF8

Write-Host "[OK] Created agent.config.json" -ForegroundColor Green
Write-Host ""
Write-Host "  Device slug : $Slug"
Write-Host "  Server      : $Server"
Write-Host "  Kiosk URL   : $KioskUrl"
Write-Host ""
Write-Host "Setup complete. Start the agent — it will provision automatically." -ForegroundColor Cyan
Write-Host "(If IP matches, provisioning is instant. Otherwise enter pairing code shown in admin.)" -ForegroundColor DarkGray
Write-Host ""
