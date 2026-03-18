#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configure Wake-on-LAN on a Windows device.
.DESCRIPTION
    Run this script ONCE as Administrator on each slave device.
    It configures all necessary Windows settings for WOL to work.
    You must ALSO enable WOL in BIOS manually (F2/Del at boot > Power Management).
.EXAMPLE
    .\configure-wol.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Wake-on-LAN Configuration Script" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 1. DISABLE FAST STARTUP (breaks WOL)
# ============================================================
Write-Host "[1/6] Disabling Fast Startup..." -ForegroundColor Yellow
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 2. DISABLE HIBERNATE (can interfere with WOL)
# ============================================================
Write-Host "[2/6] Disabling Hibernate..." -ForegroundColor Yellow
powercfg /hibernate off 2>$null
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 3. FIND ACTIVE ETHERNET ADAPTERS
# ============================================================
Write-Host "[3/6] Finding active network adapters..." -ForegroundColor Yellow

$adapters = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and
    $_.InterfaceDescription -notmatch "Virtual|Hyper-V|WSL|Bluetooth|VPN"
}

if (!$adapters -or $adapters.Count -eq 0) {
    Write-Host "  ERROR: No active physical network adapters found!" -ForegroundColor Red
    Write-Host "  Make sure the Ethernet cable is plugged in." -ForegroundColor Red
    exit 1
}

foreach ($adapter in $adapters) {
    Write-Host "  Found: $($adapter.Name) - $($adapter.InterfaceDescription)" -ForegroundColor Green
    Write-Host "    MAC: $($adapter.MacAddress)" -ForegroundColor Green
    Write-Host "    Status: $($adapter.Status)" -ForegroundColor Green
}

# ============================================================
# 4. ENABLE WOL ADAPTER PROPERTIES
# ============================================================
Write-Host "[4/6] Enabling WOL on adapter advanced properties..." -ForegroundColor Yellow

foreach ($adapter in $adapters) {
    Write-Host "  Configuring: $($adapter.Name)"

    # Common WOL property names vary by manufacturer
    $wolProperties = @(
        "Wake on Magic Packet",
        "Wake on magic packet",
        "Wake on Magic Packet from power off state",
        "Wake on Pattern Match",
        "Wake on pattern match",
        "WakeOnMagicPacket",
        "Wake On Magic Packet",
        "PME Wakeup",
        "Energy Efficient Ethernet",
        "Green Ethernet"
    )

    $enableProperties = @(
        "Wake on Magic Packet",
        "Wake on magic packet",
        "Wake on Magic Packet from power off state",
        "Wake on Pattern Match",
        "Wake on pattern match",
        "WakeOnMagicPacket",
        "Wake On Magic Packet",
        "PME Wakeup"
    )

    $disableProperties = @(
        "Energy Efficient Ethernet",
        "Green Ethernet"
    )

    foreach ($prop in $enableProperties) {
        try {
            $current = Get-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $prop -ErrorAction SilentlyContinue
            if ($current) {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $prop -DisplayValue "Enabled" -ErrorAction SilentlyContinue
                Write-Host "    Enabled: $prop" -ForegroundColor Green
            }
        } catch {}
    }

    # Disable energy-saving features that can block WOL
    foreach ($prop in $disableProperties) {
        try {
            $current = Get-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $prop -ErrorAction SilentlyContinue
            if ($current) {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $prop -DisplayValue "Disabled" -ErrorAction SilentlyContinue
                Write-Host "    Disabled: $prop (interferes with WOL)" -ForegroundColor Green
            }
        } catch {}
    }
}

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 5. ENABLE POWER MANAGEMENT (Allow device to wake computer)
# ============================================================
Write-Host "[5/6] Enabling Power Management wake settings..." -ForegroundColor Yellow

foreach ($adapter in $adapters) {
    # Enable wake via powercfg
    try {
        powercfg /deviceenablewake "$($adapter.InterfaceDescription)" 2>$null
        Write-Host "  Enabled wake for: $($adapter.InterfaceDescription)" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not enable wake for $($adapter.InterfaceDescription)" -ForegroundColor DarkYellow
    }

    # Enable via WMI (Power Management tab in Device Manager)
    try {
        $pnpDevice = Get-PnpDevice | Where-Object { $_.FriendlyName -eq $adapter.InterfaceDescription } | Select-Object -First 1
        if ($pnpDevice) {
            $deviceId = $pnpDevice.InstanceId
            # Enable "Allow this device to wake the computer"
            $power = Get-CimInstance -ClassName MSPower_DeviceWakeEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceName -match ($deviceId -replace '\\', '\\\\' -replace '&', '&') }
            if ($power) {
                Set-CimInstance -InputObject $power -Property @{ Enable = $true } -ErrorAction SilentlyContinue
                Write-Host "  WMI wake enabled for: $($adapter.Name)" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "  Warning: WMI wake config skipped for $($adapter.Name)" -ForegroundColor DarkYellow
    }
}

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 6. SET POWER PLAN TO PREVENT DEEP SLEEP
# ============================================================
Write-Host "[6/6] Configuring power plan for WOL compatibility..." -ForegroundColor Yellow

# Set active power plan to High Performance (avoids deep sleep states that break WOL)
$highPerf = powercfg /list | Select-String "High performance"
if ($highPerf -match "([0-9a-f\-]{36})") {
    powercfg /setactive $Matches[1]
    Write-Host "  Set power plan: High Performance" -ForegroundColor Green
} else {
    Write-Host "  High Performance plan not found, keeping current plan." -ForegroundColor DarkYellow
}

# Ensure NIC stays powered in sleep/shutdown
powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONNECTIVITYINSTANDBY 1 2>$null
powercfg /setactive SCHEME_CURRENT 2>$null

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  WOL Configuration Complete" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Adapters configured:" -ForegroundColor White
foreach ($adapter in $adapters) {
    Write-Host "    $($adapter.Name): $($adapter.MacAddress)" -ForegroundColor White
}

Write-Host ""
Write-Host "  Checklist:" -ForegroundColor Yellow
Write-Host "    [x] Fast Startup disabled" -ForegroundColor Green
Write-Host "    [x] Hibernate disabled" -ForegroundColor Green
Write-Host "    [x] Wake on Magic Packet enabled" -ForegroundColor Green
Write-Host "    [x] Power Management wake enabled" -ForegroundColor Green
Write-Host "    [x] Energy-saving features disabled" -ForegroundColor Green
Write-Host "    [x] Power plan optimized" -ForegroundColor Green
Write-Host ""
Write-Host "  STILL REQUIRED (manual steps):" -ForegroundColor Red
Write-Host "    [ ] Enable WOL in BIOS (F2/Del at boot > Power Management)" -ForegroundColor Red
Write-Host "    [ ] Use WIRED Ethernet (Wi-Fi does not support WOL)" -ForegroundColor Red
Write-Host "    [ ] Shutdown properly: shutdown /s /t 0" -ForegroundColor Red
Write-Host "    [ ] Do NOT unplug power after shutdown" -ForegroundColor Red
Write-Host ""
Write-Host "  Test WOL from server:" -ForegroundColor Yellow
Write-Host "    1. Shut down this device: shutdown /s /t 0" -ForegroundColor White
Write-Host "    2. From server, use the admin panel 'Wake Device' button" -ForegroundColor White
Write-Host "    3. Or test with: python -c ""import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1); mac=bytes.fromhex('MACHERE'); s.sendto(b'\xff'*6+mac*16,('255.255.255.255',9))""" -ForegroundColor White
Write-Host ""
