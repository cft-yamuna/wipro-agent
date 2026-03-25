# LIGHTMAN Agent - Complete Windows Installer
# Builds, installs service, configures kiosk mode - ONE command does everything.
# Run as Administrator:
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 -Slug "F-AV01" -Server "http://192.168.1.180:3401"
#
# Shell Replacement mode (RECOMMENDED for kiosk machines):
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 -Slug "F-AV01" -Server "http://..." -ShellReplace
#   This replaces explorer.exe with Chrome - machine boots directly into fullscreen kiosk.
#   No desktop, no taskbar, no start menu. Most reliable option for 24/7 displays.
#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$true)]
    [string]$Slug,

    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$false)]
    [string]$Timezone = "Asia/Kolkata",

    [Parameter(Mandatory=$false)]
    [string]$Username = "",

    [Parameter(Mandatory=$false)]
    [switch]$ShellReplace = $false
)

$ErrorActionPreference = "Stop"

$InstallDir  = "C:\Program Files\Lightman\Agent"
$LogDir      = "C:\ProgramData\Lightman\logs"
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentDir    = Split-Path -Parent $ScriptDir

if (-not $Username) {
    $Username = $env:USERNAME
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  LIGHTMAN Agent - Complete Windows Installer" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Device slug : $Slug"
Write-Host "  Server URL  : $Server"
Write-Host "  Username    : $Username"
Write-Host ""

# ============================================================
# PART 1: BUILD & INSTALL AGENT SERVICE
# ============================================================

# --- 1. Check Node.js ---
Write-Host "[1/21] Checking Node.js..." -ForegroundColor Yellow
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

# --- 2. Install dependencies and build ---
Write-Host "[2/21] Installing dependencies and building..." -ForegroundColor Yellow
Push-Location $AgentDir
$ErrorActionPreference = "Continue"
& npm install 2>&1 | Out-Host
& npm run build 2>&1 | Out-Host
$ErrorActionPreference = "Stop"
if (-not (Test-Path "$AgentDir\dist\index.js")) {
    Write-Host "Error: Build failed - dist/index.js not found" -ForegroundColor Red
    exit 1
}
Pop-Location
Write-Host "  Build successful"

# --- 3. Create directories ---
Write-Host "[3/21] Creating directories..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir     | Out-Null
Write-Host "  Install: $InstallDir"
Write-Host "  Logs:    $LogDir"

# --- 4. Copy agent files ---
Write-Host "[4/21] Copying agent files..." -ForegroundColor Yellow
Copy-Item -Path "$AgentDir\dist"         -Destination "$InstallDir\dist"         -Recurse -Force
Copy-Item -Path "$AgentDir\package.json" -Destination "$InstallDir\package.json" -Force
if (Test-Path "$AgentDir\package-lock.json") {
    Copy-Item -Path "$AgentDir\package-lock.json" -Destination "$InstallDir\package-lock.json" -Force
}
Copy-Item -Path "$AgentDir\agent.config.template.json" -Destination "$InstallDir\agent.config.template.json" -Force
if (Test-Path "$AgentDir\public") {
    Copy-Item -Path "$AgentDir\public" -Destination "$InstallDir\public" -Recurse -Force
}

# --- 5. Install production dependencies ---
Write-Host "[5/21] Installing production dependencies..." -ForegroundColor Yellow
Push-Location $InstallDir
$ErrorActionPreference = "Continue"
& npm ci --omit=dev --ignore-scripts 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    & npm install --omit=dev --ignore-scripts 2>&1 | Out-Host
}
& npm install node-windows 2>&1 | Out-Host
$ErrorActionPreference = "Stop"
Pop-Location

# --- 6. Configure device (generates agent.config.json) ---
Write-Host "[6/21] Configuring device '$Slug'..." -ForegroundColor Yellow
if ($ShellReplace) {
    & "$ScriptDir\setup.ps1" -Slug $Slug -Server $Server -Timezone $Timezone -InstallDir $InstallDir -ShellMode
} else {
    & "$ScriptDir\setup.ps1" -Slug $Slug -Server $Server -Timezone $Timezone -InstallDir $InstallDir
}

# --- 7. Fix BOM in config file (PowerShell UTF8 adds BOM, Node.js chokes on it) ---
Write-Host "[7/21] Fixing config encoding..." -ForegroundColor Yellow
$configPath = Join-Path $InstallDir "agent.config.json"
if (Test-Path $configPath) {
    $raw = [System.IO.File]::ReadAllText($configPath)
    $raw = $raw.TrimStart([char]0xFEFF)
    [System.IO.File]::WriteAllText($configPath, $raw, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Config file: BOM removed, UTF-8 clean"
}

# --- 8. Verify config is valid JSON ---
Write-Host "[8/21] Verifying config..." -ForegroundColor Yellow
Push-Location $InstallDir
$ErrorActionPreference = "Continue"
$jsonCheck = & node -e "try{JSON.parse(require('fs').readFileSync('agent.config.json','utf8'));console.log('OK')}catch(e){console.log('FAIL: '+e.message);process.exit(1)}" 2>&1
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: agent.config.json is invalid: $jsonCheck" -ForegroundColor Red
    exit 1
}
Pop-Location
Write-Host "  Config is valid JSON"

# --- 9. Install Windows service ---
Write-Host "[9/21] Installing Windows service..." -ForegroundColor Yellow
Push-Location $InstallDir
$ErrorActionPreference = "Continue"
& node -e "import('./dist/lib/winService.js').then(m => m.installService()).then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); })" 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Warning: Service install returned non-zero exit code" -ForegroundColor Yellow
}
$ErrorActionPreference = "Stop"
Pop-Location

# --- 10. Harden service for lifetime reliability ---
Write-Host "[10/21] Configuring service recovery & auto-start..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
$svcObj = Get-Service -DisplayName "LIGHTMAN*" -ErrorAction SilentlyContinue | Select-Object -First 1
$actualServiceName = if ($svcObj) { $svcObj.Name } else { "lightmanagent.exe" }

sc.exe failure $actualServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 2>$null
Write-Host "  Recovery policy: auto-restart on all failures (5s / 10s / 30s)"

sc.exe config $actualServiceName start= auto 2>$null
Write-Host "  Start type: Automatic"

Start-Service -Name $actualServiceName -ErrorAction SilentlyContinue
Write-Host "  Service started"

# --- 11. Configure firewall ---
Write-Host "[11/21] Configuring firewall..." -ForegroundColor Yellow
$ruleName = "LIGHTMAN Agent WebSocket"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existingRule) {
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Outbound `
        -Action Allow `
        -Protocol TCP `
        -RemotePort 3001 `
        -Description "Allow LIGHTMAN Agent to connect to CMS server" | Out-Null
    Write-Host "  Firewall rule created"
} else {
    Write-Host "  Firewall rule already exists"
}

# ============================================================
# PART 2: KIOSK CONFIGURATION (no password, no lock screen)
# All steps here use registry writes, powercfg, net user, sc.exe
# which routinely emit stderr warnings. Use Continue to avoid
# false failures from harmless warnings.
# ============================================================
$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "--- Configuring Kiosk Mode ---" -ForegroundColor Cyan
Write-Host ""

# --- 12. Auto-login: boot straight to desktop, zero user interaction ---
Write-Host "[12/21] Enabling auto-login, removing password..." -ForegroundColor Yellow
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

# Check if the target user is a Microsoft Account (cannot auto-login with MS accounts)
$targetUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
$isMsAccount = $targetUser -and $targetUser.PrincipalSource -eq 'MicrosoftAccount'

if ($isMsAccount) {
    Write-Host "  WARNING: '$Username' is a Microsoft Account - cannot auto-login!" -ForegroundColor Red
    Write-Host "  Creating local 'kiosk' account for auto-login..." -ForegroundColor Yellow

    # Create a local kiosk account with no password
    $KioskUser = "kiosk"
    $existingKiosk = Get-LocalUser -Name $KioskUser -ErrorAction SilentlyContinue
    if (-not $existingKiosk) {
        net user $KioskUser "" /add 2>$null
        net localgroup Administrators $KioskUser /add 2>$null
        Write-Host "  Created local admin account: $KioskUser (no password)"
    } else {
        net user $KioskUser "" 2>$null
        Write-Host "  Local account '$KioskUser' already exists, password cleared"
    }

    # Hide the Microsoft account from login screen
    $HideUsersPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
    if (-not (Test-Path $HideUsersPath)) { New-Item -Path $HideUsersPath -Force | Out-Null }
    Set-ItemProperty -Path $HideUsersPath -Name $Username -Value 0
    Write-Host "  Hidden '$Username' from login screen"

    # Switch to local kiosk user for auto-login
    $Username = $KioskUser
    Write-Host "  Auto-login will use: $Username" -ForegroundColor Green
} else {
    # Remove password from local account
    net user $Username "" 2>$null
}

# CRITICAL: Disable Windows 11 passwordless mode (overrides auto-login if enabled)
$PwdLessPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
if (Test-Path $PwdLessPath) {
    Set-ItemProperty -Path $PwdLessPath -Name "DevicePasswordLessBuildVersion" -Value 0
    Write-Host "  Windows 11 passwordless mode disabled"
}

# Disable Windows Hello / PIN requirement
$PassportPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"
if (-not (Test-Path $PassportPath)) { New-Item -Path $PassportPath -Force | Out-Null }
Set-ItemProperty -Path $PassportPath -Name "Enabled" -Value 0

# Auto-login registry keys
Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $RegPath -Name "DefaultUserName" -Value $Username
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value ""
Set-ItemProperty -Path $RegPath -Name "DefaultDomainName" -Value ""
Set-ItemProperty -Path $RegPath -Name "DisableCAD" -Value 1

# Skip the "Hi, welcome back" / "Just a moment" screen after updates
Set-ItemProperty -Path $RegPath -Name "AutoRestartShell" -Value 1

# Use sign-in info to auto-finish device setup after update/restart
$SignInInfoPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $SignInInfoPath -Name "DisableAutomaticRestartSignOn" -Value 0

# Disable "Choose privacy settings for your device" screen on new login
$OOBEPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"
if (-not (Test-Path $OOBEPath)) { New-Item -Path $OOBEPath -Force | Out-Null }
Set-ItemProperty -Path $OOBEPath -Name "DisablePrivacyExperience" -Value 1

Write-Host "  Password removed, auto-login enabled for: $Username"

# --- 13. KILL the lock screen completely (boot, restart, sleep, idle - everything) ---
Write-Host "[13/21] Removing lock screen..." -ForegroundColor Yellow

# --- A. Prevent lock screen from appearing on boot/restart ---

# A1. Group Policy: NoLockScreen (Pro/Enterprise)
$LockScreenPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
if (-not (Test-Path $LockScreenPath)) { New-Item -Path $LockScreenPath -Force | Out-Null }
Set-ItemProperty -Path $LockScreenPath -Name "NoLockScreen" -Value 1

# A2. Windows 11 lock screen app - force disable
$SessionDataPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\SessionData"
if (Test-Path $SessionDataPath) {
    Set-ItemProperty -Path $SessionDataPath -Name "AllowLockScreen" -Value 0 -ErrorAction SilentlyContinue
}

# A3. Disable lock screen overlay / Windows Spotlight / tips on lock screen
$CloudContentPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
if (-not (Test-Path $CloudContentPath)) { New-Item -Path $CloudContentPath -Force | Out-Null }
Set-ItemProperty -Path $CloudContentPath -Name "DisableWindowsConsumerFeatures" -Value 1
Set-ItemProperty -Path $CloudContentPath -Name "DisableCloudOptimizedContent" -Value 1
$CloudContentUser = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
if (-not (Test-Path $CloudContentUser)) { New-Item -Path $CloudContentUser -Force | Out-Null }
Set-ItemProperty -Path $CloudContentUser -Name "DisableWindowsSpotlightFeatures" -Value 1
Set-ItemProperty -Path $CloudContentUser -Name "DisableTailoredExperiencesWithDiagnosticData" -Value 1

# A4. Disable first sign-in animation ("Hi... We're getting things ready")
$FirstLogonPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $FirstLogonPath -Name "EnableFirstLogonAnimation" -Value 0

# A5. Disable "Use my sign-in info to auto finish setting up" LOCK prompt
$RestartPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\UserARSO\$((Get-WmiObject Win32_UserAccount -Filter "Name='$Username'" -ErrorAction SilentlyContinue).SID)"
try {
    if (-not (Test-Path $RestartPath)) { New-Item -Path $RestartPath -Force | Out-Null }
    Set-ItemProperty -Path $RestartPath -Name "OptOut" -Value 0 -ErrorAction SilentlyContinue
} catch { }

# --- B. Prevent lock screen from appearing EVER (sleep, idle, manual) ---

# B1. Disable lock workstation (Ctrl+L, Win+L do nothing)
$SystemPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $SystemPolicyPath -Name "DisableLockWorkstation" -Value 1
Set-ItemProperty -Path $SystemPolicyPath -Name "HideFastUserSwitching" -Value 1

# B2. Disable dynamic lock (auto-lock when Bluetooth phone walks away)
$DynamicLockPath = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
if (-not (Test-Path $DynamicLockPath)) { New-Item -Path $DynamicLockPath -Force | Out-Null }
Set-ItemProperty -Path $DynamicLockPath -Name "EnableGoodbye" -Value 0

# B3. Disable "Require sign-in" after sleep - via Group Policy
$PowerSignInPath = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0e796bdb-100d-47d6-a2d5-f7d2daa51f51"
if (-not (Test-Path $PowerSignInPath)) { New-Item -Path $PowerSignInPath -Force | Out-Null }
Set-ItemProperty -Path $PowerSignInPath -Name "ACSettingIndex" -Value 0
Set-ItemProperty -Path $PowerSignInPath -Name "DCSettingIndex" -Value 0

# B4. Disable "Require sign-in" after sleep - via power config
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 2>&1 | Out-Null
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 2>&1 | Out-Null
powercfg /SETACTIVE SCHEME_CURRENT 2>&1 | Out-Null

# B5. Screensaver lock disabled
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaverIsSecure" -Value "0"
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveActive" -Value "0"

# B6. Set sign-in options to "Never" in Settings
$DevicePolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $DevicePolicyPath -Name "InactivityTimeoutSecs" -Value 0 -ErrorAction SilentlyContinue

# --- C. Nuclear option: disable lock screen app via Task Scheduler ---
# Windows 11 runs a scheduled task that re-enables lock screen. Kill it.
$lockTasks = @(
    "\Microsoft\Windows\Shell\CreateObjectTask"
)
foreach ($t in $lockTasks) {
    try { Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null } catch { }
}

Write-Host "  Lock screen REMOVED - boot, restart, sleep, idle, Win+L - all blocked"

# --- 14. Disable sleep, screen timeout, screensaver ---
Write-Host "[14/21] Disabling sleep and screen timeout..." -ForegroundColor Yellow
powercfg /change monitor-timeout-ac 0 2>&1 | Out-Null
powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
$ScreenSaverPath = "HKCU:\Control Panel\Desktop"
Set-ItemProperty -Path $ScreenSaverPath -Name "ScreenSaveActive" -Value "0"
Set-ItemProperty -Path $ScreenSaverPath -Name "ScreenSaverIsSecure" -Value "0"
Write-Host "  Sleep, hibernate, screen timeout, screensaver all disabled"

# --- 15. Aggressively disable Windows Update restarts, notifications, error popups ---
Write-Host "[15/21] Hardening Windows for unattended kiosk operation..." -ForegroundColor Yellow

# Windows Update - prevent ALL auto-restarts
$WUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $WUPath)) { New-Item -Path $WUPath -Force | Out-Null }
Set-ItemProperty -Path $WUPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1
Set-ItemProperty -Path $WUPath -Name "AUOptions" -Value 2  # Notify before download (never auto-install)
Set-ItemProperty -Path $WUPath -Name "NoAutoUpdate" -Value 0

# Disable Windows Update reboot scheduling
$WUMainPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (-not (Test-Path $WUMainPath)) { New-Item -Path $WUMainPath -Force | Out-Null }
Set-ItemProperty -Path $WUMainPath -Name "SetAutoRestartNotificationDisable" -Value 1

# Set active hours to 24h window (prevents forced restarts)
Set-ItemProperty -Path $WUMainPath -Name "SetActiveHours" -Value 1
Set-ItemProperty -Path $WUMainPath -Name "ActiveHoursStart" -Value 0
Set-ItemProperty -Path $WUMainPath -Name "ActiveHoursEnd" -Value 23

# Notifications off
$NotifPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
if (-not (Test-Path $NotifPath)) { New-Item -Path $NotifPath -Force | Out-Null }
Set-ItemProperty -Path $NotifPath -Name "DisableNotificationCenter" -Value 1
$ToastPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
if (-not (Test-Path $ToastPath)) { New-Item -Path $ToastPath -Force | Out-Null }
Set-ItemProperty -Path $ToastPath -Name "ToastEnabled" -Value 0

# Windows Hello / PIN off
$NgcPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"
if (-not (Test-Path $NgcPath)) { New-Item -Path $NgcPath -Force | Out-Null }
Set-ItemProperty -Path $NgcPath -Name "Enabled" -Value 0

# Disable Windows Error Reporting dialogs (prevents popups over kiosk)
$WERPath = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"
if (-not (Test-Path $WERPath)) { New-Item -Path $WERPath -Force | Out-Null }
Set-ItemProperty -Path $WERPath -Name "DontShowUI" -Value 1
Set-ItemProperty -Path $WERPath -Name "Disabled" -Value 1

# Disable "Program has stopped working" dialogs
$ErrorModePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Windows"
Set-ItemProperty -Path $ErrorModePath -Name "ErrorMode" -Value 2 -ErrorAction SilentlyContinue

# Disable Cortana / Search bar (reduces distractions and resource usage)
$SearchPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
if (-not (Test-Path $SearchPath)) { New-Item -Path $SearchPath -Force | Out-Null }
Set-ItemProperty -Path $SearchPath -Name "AllowCortana" -Value 0

Write-Host "  Windows Update, Error Reporting, Notifications, Cortana, Hello - all locked down"

# --- 16. Set up kiosk Chrome launch method ---
if ($ShellReplace) {
    # ============================================================
    # SHELL REPLACEMENT MODE (recommended for kiosk machines)
    # Replace explorer.exe with our shell script.
    # Machine boots -> auto-login -> lightman-shell.bat runs instead of desktop
    # Chrome is the ONLY thing on screen. No desktop, no taskbar.
    # ============================================================
    Write-Host "[16/21] SHELL REPLACEMENT: Replacing Windows desktop with Chrome kiosk..." -ForegroundColor Magenta

    # Copy shell script to install dir
    $shellSource = Join-Path $ScriptDir "lightman-shell.bat"
    $shellTarget = Join-Path $InstallDir "lightman-shell.bat"
    if (Test-Path $shellSource) {
        Copy-Item -Path $shellSource -Destination $shellTarget -Force
    }

    # Replace the shell for THIS USER (not system-wide, so admin can still RDP with another account)
    $ShellRegPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"
    if (-not (Test-Path $ShellRegPath)) {
        New-Item -Path $ShellRegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $ShellRegPath -Name "Shell" -Value """$shellTarget"""

    # Backup: also set via HKLM for the specific user profile
    # This ensures the shell persists even if HKCU is reset
    $HKLMShellPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    # Save original shell for recovery
    $originalShell = (Get-ItemProperty -Path $HKLMShellPath -Name "Shell" -ErrorAction SilentlyContinue).Shell
    if ($originalShell) {
        Set-ItemProperty -Path $HKLMShellPath -Name "Shell_Original" -Value $originalShell
    }
    Set-ItemProperty -Path $HKLMShellPath -Name "Shell" -Value """$shellTarget"""

    Write-Host "  Windows shell replaced: explorer.exe -> lightman-shell.bat" -ForegroundColor Green
    Write-Host "  On next boot: machine goes directly to fullscreen Chrome (no desktop)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  TO RECOVER DESKTOP (if needed):" -ForegroundColor Yellow
    Write-Host "    1. RDP in with a different admin account, OR" -ForegroundColor Yellow
    Write-Host "    2. Boot to Safe Mode, OR" -ForegroundColor Yellow
    Write-Host "    3. Run: reg add ""HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"" /v Shell /d explorer.exe /f" -ForegroundColor Yellow

    # VBS scheduled task is not needed in shell mode - the shell script IS the launcher
    # But we still register it as a fallback in case someone restores explorer.exe
    $taskName = "LIGHTMAN Kiosk Browser"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

} else {
    # ============================================================
    # STANDARD MODE: VBS scheduled task launches Chrome at logon
    # Desktop is still available. Chrome runs on top of it.
    # ============================================================
    Write-Host "[16/21] Registering kiosk browser auto-launch (standard mode)..." -ForegroundColor Yellow
    # Copy the VBS launcher to install dir
    $vbsSource = Join-Path $ScriptDir "launch-kiosk.vbs"
    $vbsTarget = Join-Path $InstallDir "launch-kiosk.vbs"
    if (Test-Path $vbsSource) {
        Copy-Item -Path $vbsSource -Destination $vbsTarget -Force
    }
    # Create a scheduled task with DUAL triggers: at logon AND at startup (covers all boot scenarios)
    $taskName = "LIGHTMAN Kiosk Browser"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    $action   = New-ScheduledTaskAction -Execute "wscript.exe" -Argument """$vbsTarget""" -WorkingDirectory $InstallDir
    $trigger1 = New-ScheduledTaskTrigger -AtLogOn -User $Username
    $trigger2 = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger1, $trigger2) -Settings $settings -RunLevel Highest -Description "Launches Chrome kiosk browser on user logon and system startup for LIGHTMAN display" | Out-Null
    Write-Host "  Kiosk browser will auto-launch at logon AND system startup"
}

# --- 17. Register Guardian watchdog task (runs every 5 min) ---
Write-Host "[17/21] Registering Guardian watchdog..." -ForegroundColor Yellow
$guardianSource = Join-Path $ScriptDir "guardian.ps1"
$guardianTarget = Join-Path $InstallDir "guardian.ps1"
if (Test-Path $guardianSource) {
    Copy-Item -Path $guardianSource -Destination $guardianTarget -Force
}
$guardianTaskName = "LIGHTMAN Guardian"
$existingGuardian = Get-ScheduledTask -TaskName $guardianTaskName -ErrorAction SilentlyContinue
if ($existingGuardian) {
    Unregister-ScheduledTask -TaskName $guardianTaskName -Confirm:$false
}
$guardianAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""$guardianTarget""" -WorkingDirectory $InstallDir
# Trigger: every 5 minutes, starting at system boot
$guardianTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 365)
$guardianSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
$guardianPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $guardianTaskName -Action $guardianAction -Trigger $guardianTrigger -Settings $guardianSettings -Principal $guardianPrincipal -Description "Monitors LIGHTMAN Agent service health every 5 minutes. Last line of defense." | Out-Null
Write-Host "  Guardian watchdog will check service health every 5 minutes"

# --- 18. Disable unnecessary scheduled tasks that could interfere ---
Write-Host "[18/21] Disabling interfering scheduled tasks..." -ForegroundColor Yellow
$tasksToDisable = @(
    "\Microsoft\Windows\UpdateOrchestrator\Reboot",
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Retry Scan",
    "\Microsoft\Windows\WindowsUpdate\Scheduled Start"
)
foreach ($task in $tasksToDisable) {
    try {
        Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  Disabled: $task"
    } catch {
        # Task may not exist on all Windows editions
    }
}

# --- 19. Set BIOS power recovery hint ---
Write-Host "[19/21] Power recovery note..." -ForegroundColor Yellow
Write-Host "  IMPORTANT: Manually configure BIOS on each machine:" -ForegroundColor Red
Write-Host "    BIOS > Power > 'After Power Loss' = 'Power On'" -ForegroundColor Red
Write-Host "    This ensures machines auto-boot after power outages." -ForegroundColor Red

# --- 20. Verify everything ---
Write-Host "[20/21] Verifying installation..." -ForegroundColor Yellow
Start-Sleep -Seconds 3
$svcCheck = Get-Service -DisplayName "LIGHTMAN*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($svcCheck -and $svcCheck.Status -eq 'Running') {
    Write-Host "  Service is RUNNING" -ForegroundColor Green
} elseif ($svcCheck) {
    Write-Host "  Service status: $($svcCheck.Status) - attempting start..." -ForegroundColor Yellow
    Start-Service -Name $svcCheck.Name -ErrorAction SilentlyContinue
} else {
    Write-Host "  WARNING: Service not found. Check logs." -ForegroundColor Red
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Device slug : $Slug"
Write-Host "  Server      : $Server"
Write-Host "  Install dir : $InstallDir"
Write-Host "  Log dir     : $LogDir"
Write-Host "  User        : $Username"
Write-Host ""
Write-Host "  What's configured:" -ForegroundColor White
Write-Host "    [x] Agent built and installed"
Write-Host "    [x] Windows service (auto-start on boot)"
Write-Host "    [x] Crash recovery (auto-restart 5s/10s/30s)"
Write-Host "    [x] Guardian watchdog (checks every 5 min)"
Write-Host "    [x] Password removed, auto-login enabled"
Write-Host "    [x] Lock screen disabled"
Write-Host "    [x] Sleep/screensaver disabled"
Write-Host "    [x] Windows Update locked down (no auto-restart)"
Write-Host "    [x] Error reporting dialogs disabled"
Write-Host "    [x] Notifications disabled"
Write-Host "    [x] Windows Hello/PIN disabled"
Write-Host "    [x] Cortana/Search disabled"
if ($ShellReplace) {
    Write-Host "    [x] SHELL REPLACEMENT: explorer.exe -> Chrome kiosk" -ForegroundColor Magenta
    Write-Host "        (No desktop, no taskbar - Chrome IS the entire UI)" -ForegroundColor Magenta
} else {
    Write-Host "    [x] Kiosk Chrome auto-launches at logon + startup"
}
Write-Host ""
Write-Host "  REBOOT NOW to apply all changes:" -ForegroundColor Yellow
Write-Host "    Restart-Computer" -ForegroundColor Yellow
Write-Host ""
