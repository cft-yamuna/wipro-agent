# LIGHTMAN Agent — Windows Uninstaller
# Run as Administrator: powershell -ExecutionPolicy Bypass -File uninstall-windows.ps1
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$InstallDir = "C:\Program Files\Lightman\Agent"
$LogDir = "C:\ProgramData\Lightman\logs"
$ServiceName = "LightmanAgent"

Write-Host "=== LIGHTMAN Agent - Windows Uninstaller ===" -ForegroundColor Cyan
Write-Host ""

# --- Stop service ---
Write-Host "[1/4] Stopping service..." -ForegroundColor Yellow
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') {
        Stop-Service -Name $ServiceName -Force
        Write-Host "  Service stopped"
    }
}

# --- Uninstall Windows service ---
Write-Host "[2/4] Removing Windows service..." -ForegroundColor Yellow
if (Test-Path "$InstallDir\dist\lib\winService.js") {
    Push-Location $InstallDir
    try {
        node -e "import('./dist/lib/winService.js').then(m => m.uninstallService()).then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); })"
    } catch {
        Write-Host "  Warning: Service removal via node-windows failed, trying sc.exe..." -ForegroundColor Yellow
        sc.exe delete $ServiceName 2>$null
    }
    Pop-Location
} else {
    sc.exe delete $ServiceName 2>$null
}

# --- Remove firewall rule ---
Write-Host "[3/4] Removing firewall rule..." -ForegroundColor Yellow
$ruleName = "LIGHTMAN Agent WebSocket"
Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
Write-Host "  Firewall rule removed"

# --- Remove directories ---
Write-Host "[4/4] Removing files..." -ForegroundColor Yellow
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "  Removed $InstallDir"
}

$removeLogsChoice = Read-Host "Remove log directory ($LogDir)? [y/N]"
if ($removeLogsChoice -eq 'y' -or $removeLogsChoice -eq 'Y') {
    if (Test-Path $LogDir) {
        Remove-Item -Path $LogDir -Recurse -Force
        Write-Host "  Removed $LogDir"
    }
}

# Remove parent Lightman directory if empty
$parentDir = "C:\Program Files\Lightman"
if ((Test-Path $parentDir) -and ((Get-ChildItem $parentDir | Measure-Object).Count -eq 0)) {
    Remove-Item -Path $parentDir -Force
}

Write-Host ""
Write-Host "=== Uninstallation Complete ===" -ForegroundColor Green
Write-Host ""
