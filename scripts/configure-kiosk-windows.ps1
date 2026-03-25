# LIGHTMAN - Configure Windows for Kiosk/Display Mode
# Removes lock screen, enables auto-login, disables sleep.
# Run as Administrator:
#   powershell -ExecutionPolicy Bypass -File configure-kiosk-windows.ps1 -Username "thest"
#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$false)]
    [string]$Username = "",

    [Parameter(Mandatory=$false)]
    [string]$Password = ""
)

$ErrorActionPreference = "Stop"

# Auto-detect current username if not provided
if (-not $Username) {
    $Username = $env:USERNAME
}

Write-Host ""
Write-Host "=== LIGHTMAN - Windows Kiosk Configuration ===" -ForegroundColor Cyan
Write-Host "  User: $Username"
Write-Host ""

# --- 1. Enable Auto-Login and remove password ---
Write-Host "[1/7] Enabling auto-login and removing password..." -ForegroundColor Yellow
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

# Remove the user's password entirely so no login is ever needed
if ($Password) {
    # If password was provided, use it for auto-login
    net user $Username $Password 2>$null
    Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value $Password
} else {
    # Remove password completely
    net user $Username "" 2>$null
    Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value ""
}

Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $RegPath -Name "DefaultUserName" -Value $Username
Set-ItemProperty -Path $RegPath -Name "DefaultDomainName" -Value ""
Write-Host "  Password removed and auto-login enabled for: $Username"

# --- 2. Disable Lock Screen ---
Write-Host "[2/7] Disabling lock screen..." -ForegroundColor Yellow
$LockScreenPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
if (-not (Test-Path $LockScreenPath)) {
    New-Item -Path $LockScreenPath -Force | Out-Null
}
Set-ItemProperty -Path $LockScreenPath -Name "NoLockScreen" -Value 1
Write-Host "  Lock screen disabled"

# --- 3. Disable screen timeout and sleep ---
Write-Host "[3/7] Disabling sleep and screen timeout..." -ForegroundColor Yellow
# When plugged in (AC): never sleep, never turn off screen
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
# Disable screensaver
$ScreenSaverPath = "HKCU:\Control Panel\Desktop"
Set-ItemProperty -Path $ScreenSaverPath -Name "ScreenSaveActive" -Value "0"
Set-ItemProperty -Path $ScreenSaverPath -Name "ScreenSaverIsSecure" -Value "0"
Write-Host "  Sleep, hibernate, screen timeout, screensaver all disabled"

# --- 4. Disable Windows Update auto-restart ---
Write-Host "[4/7] Preventing Windows Update auto-restart..." -ForegroundColor Yellow
$WUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $WUPath)) {
    New-Item -Path $WUPath -Force | Out-Null
}
# No auto-restart when users are logged in
Set-ItemProperty -Path $WUPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1
Write-Host "  Windows Update will not auto-restart while logged in"

# --- 5. Disable notifications and action center popups ---
Write-Host "[5/7] Disabling notifications..." -ForegroundColor Yellow
$NotifPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
if (-not (Test-Path $NotifPath)) {
    New-Item -Path $NotifPath -Force | Out-Null
}
Set-ItemProperty -Path $NotifPath -Name "DisableNotificationCenter" -Value 1
# Disable toast notifications
$ToastPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
if (-not (Test-Path $ToastPath)) {
    New-Item -Path $ToastPath -Force | Out-Null
}
Set-ItemProperty -Path $ToastPath -Name "ToastEnabled" -Value 0
Write-Host "  Notifications and action center disabled"

# --- 6. Disable Ctrl+Alt+Del requirement ---
Write-Host "[6/7] Disabling Ctrl+Alt+Del requirement..." -ForegroundColor Yellow
Set-ItemProperty -Path $RegPath -Name "DisableCAD" -Value 1
Write-Host "  Ctrl+Alt+Del login prompt disabled"

# --- 7. Disable Windows Hello / PIN sign-in options ---
Write-Host "[7/7] Disabling Windows Hello and PIN..." -ForegroundColor Yellow
$NgcPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"
if (-not (Test-Path $NgcPath)) {
    New-Item -Path $NgcPath -Force | Out-Null
}
Set-ItemProperty -Path $NgcPath -Name "Enabled" -Value 0
# Disable "Require Windows Hello sign-in for Microsoft accounts"
$DeviceLockPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $DeviceLockPath -Name "DontDisplayLastUserName" -Value 0
# Disable sign-in options screen
$SignInPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"
Set-ItemProperty -Path $SignInPath -Name "LastLoggedOnSAMUser" -Value $Username -ErrorAction SilentlyContinue
Write-Host "  Windows Hello and PIN disabled"

Write-Host ""
Write-Host "=== Kiosk Configuration Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  On next reboot:" -ForegroundColor White
Write-Host "    - Machine boots straight to desktop (no lock, no password)"
Write-Host "    - Screen never turns off"
Write-Host "    - LIGHTMAN Agent starts automatically as a service"
Write-Host "    - Kiosk browser launches automatically"
Write-Host ""
Write-Host "  REBOOT NOW to apply:  Restart-Computer" -ForegroundColor Yellow
Write-Host ""
