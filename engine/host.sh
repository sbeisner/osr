#!/usr/bin/env bash
# host.sh — one cycle of the OSR refresh loop.
#
# Sequence:
#   1. Start the dirty VM, wait for the user's session to power off.
#   2. Start the clean VM (which auto-runs Boot.exe to restore the user's
#      whitelisted files, then powers itself off).
#   3. Atomically replace the dirty VHD with a fresh clone of the clean
#      VHD (clone-then-rename, never delete-then-clone).
#   4. Archive the shared-folder transit dir under ~/osr-archive so an
#      admin can roll back if a user reports lost or corrupted files.
#
# kiosk-loop.sh wraps this in an infinite loop for deployed kiosks.
#
# Configuration via environment variables (or edit defaults below):
#   DIRTY_VM, CLEAN_VM     VirtualBox VM names
#   DIRTY_VHD, CLEAN_VHD   Paths to the .vhd files
#   STORAGE_CTL, PORT      VirtualBox storage controller name + port
#   DEST_DIR               Shared-folder transit dir on the host
#   ARCHIVE_DIR            Where archived dest snapshots are kept
#   ARCHIVE_KEEP           Number of past sessions to retain (default 7)
#   POLL_INTERVAL_SEC      Seconds between VM-state polls (default 5)
#   MAX_WAIT_SEC           Max seconds to wait for a VM to power off
#                          before forcibly killing it (default 1800)
#   LOG_FILE               Where to log (default ~/osr-host.log)

set -uo pipefail

DIRTY_VM=${DIRTY_VM:-Dirty-2}
CLEAN_VM=${CLEAN_VM:-Clean-2}
DIRTY_VHD=${DIRTY_VHD:-$HOME/VirtualBox VMs/Dirty-2/Dirty-2.vhd}
CLEAN_VHD=${CLEAN_VHD:-$HOME/VirtualBox VMs/Clean-2/Clean-2.vhd}
STORAGE_CTL=${STORAGE_CTL:-SATA}
PORT=${PORT:-0}
DEST_DIR=${DEST_DIR:-$HOME/dest}
ARCHIVE_DIR=${ARCHIVE_DIR:-$HOME/osr-archive}
ARCHIVE_KEEP=${ARCHIVE_KEEP:-7}
POLL_INTERVAL_SEC=${POLL_INTERVAL_SEC:-5}
MAX_WAIT_SEC=${MAX_WAIT_SEC:-1800}
LOG_FILE=${LOG_FILE:-$HOME/osr-host.log}

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s  %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "FATAL: $*"
    exit 1
}

# Wait for the named VM to leave the running state. Force-poweroff if it
# overruns MAX_WAIT_SEC. Returns 0 if the VM stopped cleanly (or after a
# clean ACPI shutdown), 1 if we had to force it off.
wait_for_vm_off() {
    local vm=$1
    local elapsed=0
    while VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null \
        | grep -q '^VMState="running"$'; do
        sleep "$POLL_INTERVAL_SEC"
        elapsed=$(( elapsed + POLL_INTERVAL_SEC ))
        if (( elapsed >= MAX_WAIT_SEC )); then
            log "WARN: $vm exceeded MAX_WAIT_SEC=${MAX_WAIT_SEC}; forcing power-off"
            VBoxManage controlvm "$vm" poweroff || true
            sleep 5
            return 1
        fi
    done
    return 0
}

archive_dest() {
    if [ ! -d "$DEST_DIR" ] || [ -z "$(ls -A "$DEST_DIR" 2>/dev/null)" ]; then
        return 0
    fi
    mkdir -p "$ARCHIVE_DIR"
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local target="$ARCHIVE_DIR/$ts"
    log "Archiving $DEST_DIR -> $target"
    if mv "$DEST_DIR" "$target"; then
        mkdir -p "$DEST_DIR"
    else
        log "WARN: failed to archive $DEST_DIR; falling back to rm -rf"
        rm -rf "${DEST_DIR:?}"/*
    fi
    # Prune to ARCHIVE_KEEP most recent
    ls -1t "$ARCHIVE_DIR" 2>/dev/null \
        | tail -n +"$((ARCHIVE_KEEP + 1))" \
        | while read -r old; do
            log "Pruning old archive: $old"
            rm -rf "${ARCHIVE_DIR:?}/$old"
        done
}

mkdir -p "$(dirname "$LOG_FILE")"
log "=== cycle start (DIRTY=$DIRTY_VM, CLEAN=$CLEAN_VM) ==="

# 1. Dirty VM — the user's session
log "Starting $DIRTY_VM"
if ! VBoxManage startvm "$DIRTY_VM" >>"$LOG_FILE" 2>&1; then
    die "could not start $DIRTY_VM"
fi
log "Waiting for $DIRTY_VM to power off"
wait_for_vm_off "$DIRTY_VM"

# Sanity: did Shutdown.exe write its completion sentinel to the shared
# folder? Absence is not fatal (we still have to give the user back a
# usable machine) but we log loudly so admins notice.
SENTINEL="$DEST_DIR/shutdown-complete.flag"
if [ -f "$SENTINEL" ]; then
    log "Shutdown.exe completed cleanly (sentinel present)"
    rm -f "$SENTINEL"
else
    log "WARN: $SENTINEL missing — Shutdown.exe may not have completed"
fi

# 2. Clean VM — Boot.exe restores files, then shuts itself off
log "Starting $CLEAN_VM"
if ! VBoxManage startvm "$CLEAN_VM" >>"$LOG_FILE" 2>&1; then
    log "ERROR: could not start $CLEAN_VM; user files may be stranded in $DEST_DIR"
    archive_dest
    exit 1
fi
log "Waiting for $CLEAN_VM to power off"
wait_for_vm_off "$CLEAN_VM"

# 3. Replace dirty VHD with a fresh clone of the clean VHD.
#    Clone first to a sibling .new file; only swap once that succeeds.
#    This way a partial clone never leaves the user without a Dirty disk.
log "Replacing dirty VHD via clone-then-rename"
NEW_VHD="${DIRTY_VHD%.vhd}.new.vhd"

# Detach the existing dirty VHD first so VirtualBox releases its lock
VBoxManage storageattach "$DIRTY_VM" \
    --storagectl "$STORAGE_CTL" --port "$PORT" --medium none \
    >>"$LOG_FILE" 2>&1 \
    || log "WARN: storageattach detach failed (may already be detached)"

if [ -f "$NEW_VHD" ]; then
    rm -f "$NEW_VHD"
    VBoxManage closemedium disk "$NEW_VHD" --delete >>"$LOG_FILE" 2>&1 || true
fi

if ! VBoxManage clonemedium "$CLEAN_VHD" "$NEW_VHD" --format VHD \
        >>"$LOG_FILE" 2>&1; then
    log "ERROR: clonemedium failed; leaving existing $DIRTY_VHD in place"
    # Re-attach the existing (still-good) dirty VHD so the next cycle works.
    VBoxManage storageattach "$DIRTY_VM" \
        --storagectl "$STORAGE_CTL" --port "$PORT" \
        --type HDD --medium "$DIRTY_VHD" \
        >>"$LOG_FILE" 2>&1 \
        || log "ERROR: also failed to re-attach $DIRTY_VHD"
    exit 1
fi

# Clone succeeded. Now swap.
OLD_VHD="${DIRTY_VHD%.vhd}.old.vhd"
mv -f "$DIRTY_VHD" "$OLD_VHD" 2>/dev/null || true
if mv -f "$NEW_VHD" "$DIRTY_VHD"; then
    # Tell VirtualBox the disk identity changed
    VBoxManage closemedium disk "$OLD_VHD" --delete >>"$LOG_FILE" 2>&1 || true
    rm -f "$OLD_VHD"
else
    log "ERROR: swap failed; restoring previous dirty VHD"
    mv -f "$OLD_VHD" "$DIRTY_VHD"
    exit 1
fi

if ! VBoxManage storageattach "$DIRTY_VM" \
        --storagectl "$STORAGE_CTL" --port "$PORT" \
        --type HDD --medium "$DIRTY_VHD" \
        >>"$LOG_FILE" 2>&1; then
    die "could not re-attach swapped $DIRTY_VHD; manual recovery needed"
fi

# 4. Archive the shared-folder transit dir for admin rollback
archive_dest

log "=== cycle complete ==="
