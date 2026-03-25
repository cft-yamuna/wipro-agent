# LIGHTMAN Guardian - Service Health Monitor
# Runs every 5 minutes via Task Scheduler to ensure the agent service never stays down.
# This is the last line of defense - if the Windows Service recovery fails, this catches it.

$LogDir = "C:\ProgramData\Lightman\logs"
$LogFile = Join-Path $LogDir "guardian.log"

function Write-GuardianLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
        # Rotate guardian log if > 1MB
        if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 1MB) {
            $rotated = "$LogFile.old"
            if (Test-Path $rotated) { Remove-Item $rotated -Force }
            Rename-Item $LogFile $rotated -Force
        }
    } catch { }
}

try {
    # 1. Check if LIGHTMAN Agent service exists and is running
    $svc = Get-Service -DisplayName "LIGHTMAN*" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $svc) {
        Write-GuardianLog "CRITICAL: LIGHTMAN service not found! Cannot recover."
        exit 1
    }

    if ($svc.Status -ne 'Running') {
        Write-GuardianLog "WARNING: Service '$($svc.Name)' is $($svc.Status). Attempting restart..."

        # If service is stopped, start it
        if ($svc.Status -eq 'Stopped') {
            Start-Service -Name $svc.Name -ErrorAction Stop
            Start-Sleep -Seconds 5
            $svc.Refresh()
            if ($svc.Status -eq 'Running') {
                Write-GuardianLog "OK: Service restarted successfully."
            } else {
                Write-GuardianLog "ERROR: Service failed to start. Status: $($svc.Status)"
            }
        }
        # If service is stuck in Starting/Stopping, force restart
        elseif ($svc.Status -in @('StartPending', 'StopPending')) {
            Write-GuardianLog "Service stuck in $($svc.Status). Force killing node.exe..."
            Stop-Process -Name "node" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            $svc.Refresh()
            Write-GuardianLog "After force restart: $($svc.Status)"
        }
    }

    # 2. Ensure the service is set to auto-start (in case something changed it)
    $startType = (Get-WmiObject Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue).StartMode
    if ($startType -and $startType -ne 'Auto') {
        Write-GuardianLog "WARNING: Service start mode is '$startType', changing to Auto..."
        sc.exe config $svc.Name start= delayed-auto 2>$null
        Write-GuardianLog "Service start mode restored to delayed-auto."
    }

    # 3. Check if Chrome kiosk is running (for user-session health)
    $chrome = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
    if (-not $chrome) {
        # Chrome not running - the agent's KioskManager should handle this,
        # but if the agent just restarted, give it a nudge via the VBS launcher
        $vbsPath = "C:\Program Files\Lightman\Agent\launch-kiosk.vbs"
        if (Test-Path $vbsPath) {
            # Only launch if no Chrome appeared in last 30 seconds (agent might be starting it)
            Start-Sleep -Seconds 10
            $chromeRecheck = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
            if (-not $chromeRecheck) {
                Write-GuardianLog "Chrome not running after 10s wait. Launching via VBS..."
                Start-Process "wscript.exe" -ArgumentList """$vbsPath""" -WindowStyle Hidden
            }
        }
    }

} catch {
    Write-GuardianLog "Guardian error: $_"
}
