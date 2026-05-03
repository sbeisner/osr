#Requires -RunAsAdministrator

<#
.SYNOPSIS
Prepares a Dirty-2 VirtualBox VM for use with OSR.

.DESCRIPTION
Run this once inside the Dirty-2 VM AFTER cloning from Clean-2. It:

  1. Removes the cloned 'OSR Boot' scheduled task (correct for Clean,
     wrong for Dirty — would shut the VM down on every logon).
  2. Removes the leftover C:\osr\Boot.exe.
  3. Copies Shutdown.exe to C:\osr\Shutdown.exe.
  4. Wires Shutdown.exe as a local Group Policy shutdown script by
     writing C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini
     directly. This works on Windows Home (which lacks gpedit.msc) as
     well as Pro/Enterprise.
  5. Runs gpupdate /force so the change takes effect without a reboot.

Idempotent — safe to re-run.

.PARAMETER ShutdownExe
Path to the Shutdown.exe binary you compiled with Visual Studio.
Defaults to Shutdown.exe in the same directory as this script.

.EXAMPLE
.\prepare-dirty-vm.ps1
# Defaults: Shutdown.exe alongside this script
#>

[CmdletBinding()]
param(
    [string]$ShutdownExe = (Join-Path $PSScriptRoot "Shutdown.exe")
)

$ErrorActionPreference = "Stop"

function Section($name) { Write-Host "`n=== $name ===" -ForegroundColor Cyan }
function Info($msg)     { Write-Host "  $msg" }
function Warn($msg)     { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Ok($msg)       { Write-Host "  + $msg" -ForegroundColor Green }

# ---------------------------------------------------------------------------
Section "Verifying inputs"
# ---------------------------------------------------------------------------

if (-not (Test-Path $ShutdownExe)) {
    throw "Shutdown.exe not found at: $ShutdownExe`nPass -ShutdownExe with the full path, or place Shutdown.exe in the same folder as this script."
}
$ShutdownExeFull = (Resolve-Path $ShutdownExe).Path
Info "Shutdown.exe: $ShutdownExeFull"

# ---------------------------------------------------------------------------
Section "Removing cloned 'OSR Boot' scheduled task"
# ---------------------------------------------------------------------------

# Dirty-2 is a clone of Clean-2 and inherited Clean's logon-time Boot
# scheduled task. On the Dirty side that task would shut the VM down
# the moment the user logs in. Remove it.
$task = Get-ScheduledTask -TaskName "OSR Boot" -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName "OSR Boot" -Confirm:$false
    Ok "Removed cloned 'OSR Boot' scheduled task"
} else {
    Info "No 'OSR Boot' scheduled task found (already removed?)"
}

# ---------------------------------------------------------------------------
Section "Installing Shutdown.exe to C:\osr\"
# ---------------------------------------------------------------------------

if (-not (Test-Path "C:\osr")) {
    New-Item -ItemType Directory -Path "C:\osr" -Force | Out-Null
    Ok "Created C:\osr"
}

if (Test-Path "C:\osr\Boot.exe") {
    Remove-Item "C:\osr\Boot.exe" -Force
    Info "Removed leftover C:\osr\Boot.exe (Dirty side doesn't need it)"
}

Copy-Item $ShutdownExeFull "C:\osr\Shutdown.exe" -Force
Ok "Copied Shutdown.exe to C:\osr\Shutdown.exe"

# ---------------------------------------------------------------------------
Section "Registering Shutdown.exe as a Group Policy shutdown script"
# ---------------------------------------------------------------------------

$gpRoot      = "C:\Windows\System32\GroupPolicy\Machine"
$scriptsRoot = "$gpRoot\Scripts"
$shutdownDir = "$scriptsRoot\Shutdown"
$scriptsIni  = "$scriptsRoot\scripts.ini"

# These directories may not exist in a fresh Windows install.
foreach ($d in @($gpRoot, $scriptsRoot, $shutdownDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}
Ok "GroupPolicy script directories present"

# scripts.ini format reference:
#   https://learn.microsoft.com/windows/win32/policy/scripts-ini
# Each script is referenced as <N>CmdLine= and <N>Parameters=, where N is
# the priority order. We always write index 0, replacing any prior entry.
$iniBody = @(
    "[Shutdown]",
    "0CmdLine=C:\osr\Shutdown.exe",
    "0Parameters="
) -join "`r`n"

# scripts.ini is conventionally hidden+system; clear attributes if it
# already exists so we can overwrite, then restore.
if (Test-Path $scriptsIni) {
    Set-ItemProperty $scriptsIni -Name Attributes -Value Normal
}
Set-Content -Path $scriptsIni -Value $iniBody -Encoding ASCII -Force -NoNewline
$file = Get-Item $scriptsIni
$file.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
Ok "Wrote $scriptsIni"

# Force a Group Policy refresh so the new shutdown script is loaded.
$gpupdateOut = & gpupdate.exe /force /target:computer 2>&1 | Out-String
Info "gpupdate output:"
$gpupdateOut.Trim().Split("`n") | ForEach-Object {
    $line = $_.Trim()
    if ($line) { Info "    $line" }
}

# ---------------------------------------------------------------------------
Section "Done"
# ---------------------------------------------------------------------------

Write-Host @"

Dirty-2 prep complete. Next steps:

  1. (If on Pro/Enterprise) verify the GPO:
       Start -> Run -> gpedit.msc
       Computer Configuration -> Windows Settings -> Scripts (Startup/Shutdown)
       -> Shutdown -> double-click. You should see C:\osr\Shutdown.exe listed.
     (Home edition: gpedit.msc is not present, but the policy still applies
     because we wrote scripts.ini and ran gpupdate.)
  2. Test it: Start -> Power -> Shut down.
     A brief console window may flash as Shutdown.exe runs.
     The VM should power off normally.
  3. On the Linux host (admin terminal):
       sudo ls -la /home/kiosk/dest/
       sudo cat /home/kiosk/dest/shutdown.log
     You should see numbered subfolders (0, 1, ...), dir_desc.txt,
     shutdown.log, and shutdown-complete.flag.
  4. Start Dirty-2 again, log in, press Right-Ctrl + F to enter
     fullscreen, shut down cleanly. VirtualBox saves the fullscreen
     preference for next launch.
  5. Run a full cycle by hand to confirm everything works:
       sudo -u kiosk /opt/osr/engine/host.sh

See ../DEPLOYMENT.md sections 7-9 for the full procedure.

"@
