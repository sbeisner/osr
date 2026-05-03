#Requires -RunAsAdministrator

<#
.SYNOPSIS
Prepares a Clean-2 VirtualBox VM for use with OSR.

.DESCRIPTION
Run this once inside the Clean-2 VM AFTER Windows is installed and the
customer's app stack (Office, QuickBooks, etc.) is in place. It:

  1. Copies Boot.exe to C:\osr\Boot.exe.
  2. Enables Microsoft Defender's Controlled Folder Access (CFA) on the
     OSR whitelist paths, with Boot.exe and Office apps allowed.
  3. Registers a Scheduled Task that runs Boot.exe at logon with highest
     privileges.
  4. Best-effort pauses Windows Update for 5 weeks (so updates don't
     fight the OSR cycle during initial deployment).

Idempotent — safe to re-run.

After this finishes, do NOT log out (Boot.exe will fire on next logon
and shut the VM down). Shut down from the current session, then take
the "pristine" snapshot in VirtualBox.

.PARAMETER OperatorUsername
The Windows local-account name the kiosk uses (e.g. "staff"). Defaults
to the currently logged-in user.

.PARAMETER BootExe
Path to the Boot.exe binary you compiled with Visual Studio. Defaults
to Boot.exe in the same directory as this script (so you can drop both
on a USB stick and run from there).

.PARAMETER ExtraAllowedApps
Additional .exe paths to allow through CFA. Add the customer's
specialty apps (QuickBooks, payroll software, etc.) so they can write
to the protected folders.

.EXAMPLE
.\prepare-clean-vm.ps1
# Defaults: current user, Boot.exe alongside this script, Office apps only

.EXAMPLE
.\prepare-clean-vm.ps1 -OperatorUsername staff -ExtraAllowedApps `
    "C:\Program Files (x86)\Intuit\QuickBooks 2024\QBW32.EXE"
#>

[CmdletBinding()]
param(
    [string]$OperatorUsername = $env:USERNAME,
    [string]$BootExe = (Join-Path $PSScriptRoot "Boot.exe"),
    [string[]]$ExtraAllowedApps = @()
)

$ErrorActionPreference = "Stop"

function Section($name) { Write-Host "`n=== $name ===" -ForegroundColor Cyan }
function Info($msg)     { Write-Host "  $msg" }
function Warn($msg)     { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Ok($msg)       { Write-Host "  + $msg" -ForegroundColor Green }

# ---------------------------------------------------------------------------
Section "Verifying inputs"
# ---------------------------------------------------------------------------

$os = Get-CimInstance Win32_OperatingSystem
Info "OS:        $($os.Caption) ($($os.Version))"
Info "Operator:  $OperatorUsername"

if (-not (Test-Path $BootExe)) {
    throw "Boot.exe not found at: $BootExe`nPass -BootExe with the full path, or place Boot.exe in the same folder as this script."
}
$BootExeFull = (Resolve-Path $BootExe).Path
Info "Boot.exe:  $BootExeFull"

$userHome = "C:\Users\$OperatorUsername"
if (-not (Test-Path $userHome)) {
    throw "User home not found: $userHome`n(Did you spell -OperatorUsername correctly? Currently logged-in user is $env:USERNAME.)"
}
Info "User home: $userHome"

# ---------------------------------------------------------------------------
Section "Installing Boot.exe to C:\osr\"
# ---------------------------------------------------------------------------

if (-not (Test-Path "C:\osr")) {
    New-Item -ItemType Directory -Path "C:\osr" -Force | Out-Null
    Ok "Created C:\osr"
} else {
    Info "C:\osr already exists"
}

Copy-Item $BootExeFull "C:\osr\Boot.exe" -Force
Ok "Copied Boot.exe to C:\osr\Boot.exe"

# ---------------------------------------------------------------------------
Section "Configuring Defender Controlled Folder Access"
# ---------------------------------------------------------------------------

$protectedFolders = @(
    "$userHome\Desktop",
    "$userHome\Documents",
    "$userHome\Pictures",
    "$userHome\Music",
    "$userHome\Videos",
    "$userHome\AppData\Roaming\Microsoft\Signatures",
    "$userHome\AppData\Roaming\Microsoft\UProof",
    "C:\Users\Public\Documents\Intuit\QuickBooks"
)

# C:\osr\Boot.exe is critical — without it, CFA blocks Boot.exe from
# writing user files back during restore on every cycle.
$allowedApps = @(
    "C:\osr\Boot.exe",
    "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
    "C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE",
    "C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE",
    "C:\Program Files\Microsoft Office\root\Office16\POWERPNT.EXE"
) + $ExtraAllowedApps

Set-MpPreference -EnableControlledFolderAccess Enabled
Ok "CFA enabled"

$existingFolders = $protectedFolders | Where-Object { Test-Path $_ }
$missingFolders  = $protectedFolders | Where-Object { -not (Test-Path $_) }
if ($existingFolders) {
    Add-MpPreference -ControlledFolderAccessProtectedFolders $existingFolders
    Ok "Added $($existingFolders.Count) protected folder(s)"
}
if ($missingFolders) {
    Warn "Skipped $($missingFolders.Count) folder(s) that don't exist on this VM:"
    $missingFolders | ForEach-Object { Warn "    $_" }
    Warn "  (this is fine for folders the customer doesn't use, e.g. QuickBooks)"
}

$existingApps = $allowedApps | Where-Object { Test-Path $_ }
$missingApps  = $allowedApps | Where-Object { -not (Test-Path $_) }
if ($existingApps) {
    Add-MpPreference -ControlledFolderAccessAllowedApplications $existingApps
    Ok "Added $($existingApps.Count) allowed application(s)"
}
if ($missingApps) {
    Warn "Skipped $($missingApps.Count) app(s) that don't exist on this VM:"
    $missingApps | ForEach-Object { Warn "    $_" }
    Warn "  (this is fine for apps the customer didn't install)"
}

$mp = Get-MpPreference
if ($mp.MAPSReporting -eq 'Disabled') {
    Warn "Cloud-delivered protection is OFF — recommend enabling it:"
    Warn "  Settings -> Update & Security -> Windows Security ->"
    Warn "  Virus & threat protection -> Manage settings ->"
    Warn "  Cloud-delivered protection (toggle on)"
} else {
    Ok "Cloud-delivered protection: $($mp.MAPSReporting)"
}

# ---------------------------------------------------------------------------
Section "Registering the OSR Boot scheduled task"
# ---------------------------------------------------------------------------

$taskName = "OSR Boot"
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Info "Task '$taskName' already exists; replacing"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute "C:\osr\Boot.exe"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $OperatorUsername
$principal = New-ScheduledTaskPrincipal -UserId $OperatorUsername -RunLevel Highest -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask `
    -TaskName $taskName `
    -Description "Runs C:\osr\Boot.exe at logon to restore user files" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings | Out-Null

Ok "Registered scheduled task: $taskName"

# ---------------------------------------------------------------------------
Section "Pausing Windows Update (best effort)"
# ---------------------------------------------------------------------------

try {
    $pauseUntil = (Get-Date).AddDays(35).ToString("yyyy-MM-ddTHH:mm:ssK")
    $base = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    if (-not (Test-Path $base)) {
        New-Item -Path $base -Force | Out-Null
    }
    Set-ItemProperty -Path $base -Name "PauseUpdatesExpiryTime"     -Value $pauseUntil -Type String
    Set-ItemProperty -Path $base -Name "PauseFeatureUpdatesEndTime" -Value $pauseUntil -Type String
    Set-ItemProperty -Path $base -Name "PauseQualityUpdatesEndTime" -Value $pauseUntil -Type String
    Ok "Windows Update paused until $pauseUntil"
} catch {
    Warn "Could not pause Windows Update via registry: $($_.Exception.Message)"
    Warn "  Pause manually: Settings -> Update & Security -> Windows Update"
    Warn "                  -> Pause for 5 weeks"
}

# ---------------------------------------------------------------------------
Section "Done"
# ---------------------------------------------------------------------------

Write-Host @"

Clean-2 prep complete. Next steps:

  1. Verify the scheduled task: Task Scheduler -> Task Scheduler Library
     -> 'OSR Boot' should be enabled and triggered "At log on of $OperatorUsername".
  2. DO NOT log out of this session. (Boot.exe will fire at the next logon
     and immediately shut the VM down — that's its design, but you don't
     want it firing during setup.)
  3. From the current session: Start -> Power -> Shut down.
  4. In VirtualBox manager (on the Linux host): right-click Clean-2 ->
     Snapshots -> Take Snapshot -> name it 'pristine'.
  5. Clone Clean-2 to Dirty-2.
  6. Inside Dirty-2, run prepare-dirty-vm.ps1.

See ../DEPLOYMENT.md for the full procedure.

"@
