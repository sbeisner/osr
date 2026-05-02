#!/usr/bin/env bash
# osr-status.sh — print a one-page health summary for a deployed OSR host.
#
# Intended use: an admin SSHes into the host via Tailscale, runs this,
# and gets enough context to answer "is anything wrong?" without having
# to chase logs across multiple files. A non-technical kiosk operator
# can also run it and paste the output to support.
#
# Read-only. Never modifies anything on disk.
#
# Run as the kiosk user (or any user with read access to ~/osr-host.log
# and ~/osr-archive/). Read-only, so root is not required.

set -uo pipefail

DEST_DIR=${DEST_DIR:-$HOME/dest}
ARCHIVE_DIR=${ARCHIVE_DIR:-$HOME/osr-archive}
LOG_FILE=${LOG_FILE:-$HOME/osr-host.log}
DIRTY_VM=${DIRTY_VM:-Dirty-2}
CLEAN_VM=${CLEAN_VM:-Clean-2}

hr() { printf -- '-%.0s' {1..62}; printf '\n'; }
section() { printf '\n'; hr; printf '  %s\n' "$1"; hr; }

printf '=== OSR Status — %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf 'Host: %s   Uptime: %s\n' "$(hostname)" "$(uptime -p 2>/dev/null || uptime)"

section 'Recent cycles'
if [ -f "$LOG_FILE" ]; then
    last_complete=$(grep -E "^[0-9-]+ [0-9:]+  === cycle complete ===" "$LOG_FILE" | tail -1)
    last_start=$(grep -E "^[0-9-]+ [0-9:]+  === cycle start" "$LOG_FILE" | tail -1)
    cycles_today=$(grep -c "=== cycle start" "$LOG_FILE" 2>/dev/null || echo 0)
    printf 'Last cycle start:    %s\n' "${last_start:-(none recorded)}"
    printf 'Last cycle complete: %s\n' "${last_complete:-(none recorded)}"
    printf 'Cycles in current log: %s\n' "$cycles_today"

    err_count=$(grep -cE "(ERROR|FATAL):" "$LOG_FILE" 2>/dev/null || echo 0)
    warn_count=$(grep -c "WARN:" "$LOG_FILE" 2>/dev/null || echo 0)
    printf 'Errors logged: %s    Warnings logged: %s\n' "$err_count" "$warn_count"
    if [ "$err_count" -gt 0 ]; then
        printf '\nRecent ERROR/FATAL lines:\n'
        grep -E "(ERROR|FATAL):" "$LOG_FILE" | tail -5 | sed 's/^/  /'
    fi
else
    printf '(%s does not exist — kiosk loop may not have run yet)\n' "$LOG_FILE"
fi

section 'Suspicious sessions (ransomware indicators)'
if [ -d "$ARCHIVE_DIR" ]; then
    sus_count=$(find "$ARCHIVE_DIR" -maxdepth 1 -name '*.SUSPICIOUS' 2>/dev/null | wc -l | tr -d ' ')
    archive_count=$(find "$ARCHIVE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    printf '%s archived sessions; %s flagged SUSPICIOUS\n' "$archive_count" "$sus_count"
    if [ "${sus_count:-0}" -gt 0 ]; then
        printf '\nFlagged archives:\n'
        find "$ARCHIVE_DIR" -maxdepth 1 -name '*.SUSPICIOUS' 2>/dev/null | \
            sort | tail -10 | sed 's/^/  /'
        printf '\nFor each, the archive directory next to the .SUSPICIOUS marker holds\n'
        printf 'the user data from that session for forensic review.\n'
    fi
else
    printf '(no %s yet)\n' "$ARCHIVE_DIR"
fi

section 'VirtualBox VMs'
if command -v VBoxManage >/dev/null 2>&1; then
    for vm in "$DIRTY_VM" "$CLEAN_VM"; do
        if VBoxManage showvminfo "$vm" --machinereadable >/dev/null 2>&1; then
            state=$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null \
                    | grep '^VMState=' | head -1 | cut -d= -f2 | tr -d '"')
            net_type=$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null \
                       | grep '^nic1=' | head -1 | cut -d= -f2 | tr -d '"')
            printf '%-12s state=%-12s nic1=%s' "$vm:" "$state" "$net_type"
            case "$net_type" in
                nat|none) printf '  (ok — no LAN access)\n' ;;
                bridged) printf '  (WARN: bridged adapter exposes the VM to the LAN)\n' ;;
                *) printf '\n' ;;
            esac
        else
            printf '%-12s (VM not registered or VBoxManage failed)\n' "$vm:"
        fi
    done
else
    printf '(VBoxManage not on PATH — VirtualBox not installed?)\n'
fi

section 'Tailscale'
if command -v tailscale >/dev/null 2>&1; then
    if tailscale status --json >/dev/null 2>&1; then
        ts_self=$(tailscale status --self 2>/dev/null | head -1)
        ts_backend=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | head -1 | cut -d'"' -f4)
        printf 'Backend: %s\n' "${ts_backend:-unknown}"
        printf 'Self: %s\n' "${ts_self:-unknown}"
        if tailscale status 2>/dev/null | grep -q ' tagged-devices\| ssh '; then
            printf 'SSH: appears to be enabled (verify with `tailscale serve status` if needed)\n'
        fi
    else
        printf '(tailscale daemon not running OR not authenticated; run `sudo tailscale up --ssh`)\n'
    fi
else
    printf '(tailscale not installed)\n'
fi

section 'Disk space'
df -h / "$HOME" 2>/dev/null | awk 'NR==1 {print; next} {print}' | sed 's/^/  /'
if [ -d "$ARCHIVE_DIR" ]; then
    arch_size=$(du -sh "$ARCHIVE_DIR" 2>/dev/null | cut -f1)
    printf '\nArchive total: %s (%s)\n' "${arch_size:-?}" "$ARCHIVE_DIR"
fi
if [ -d "$HOME/VirtualBox VMs" ]; then
    vbox_size=$(du -sh "$HOME/VirtualBox VMs" 2>/dev/null | cut -f1)
    printf 'VBox VMs total: %s\n' "${vbox_size:-?}"
fi

section 'Reminders'
cat <<'TXT'
* Defender + Controlled Folder Access status lives INSIDE the Clean VM
  and cannot be checked from the host. To verify, boot Clean-2 and run
  in PowerShell:
      Get-MpPreference | Select EnableControlledFolderAccess, `
          ControlledFolderAccessProtectedFolders
* If you see SUSPICIOUS archives above, the user data is NOT lost — it
  is preserved in the matching directory next to the .SUSPICIOUS marker.
  Suppression of the bad files into the next session was intentional.
* Logs from inside the Windows binaries (Shutdown.exe, Boot.exe) are in
  each archived dest dir as shutdown.log and boot.log.
TXT

printf '\n=== End of status ===\n'
