#!/usr/bin/env bash
# host.sh — one cycle of the OSR refresh loop.
#
# Sequence:
#   1. Start the dirty VM, wait for the user's session to power off.
#   2. Scan the shared folder for ransomware indicators (extension
#      blacklist, ransom-note filenames). If any hit, suppress the
#      restore for this cycle so the next user gets a fresh empty state
#      instead of an encrypted one. The dirty session's data is still
#      archived (marked SUSPICIOUS) so an admin can recover legitimate
#      files via Tailscale SSH.
#   3. Start the clean VM (which auto-runs Boot.exe to restore the user's
#      whitelisted files, then powers itself off).
#   4. Atomically replace the dirty VHD with a fresh clone of the clean
#      VHD (clone-then-rename, never delete-then-clone).
#   5. Archive the shared-folder transit dir under ~/osr-archive so an
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
#   WHITELIST_FILE         Optional. Host-side whitelist managed by the
#                          host-ui Flask app (default ~/osr-config/whitelist.txt).
#                          If present, copied into $DEST_DIR/whitelist.txt
#                          at the start of each cycle so shutdown.exe
#                          uses it in preference to its hardcoded
#                          generate_whitelist() defaults. Absent file is
#                          fine — engine falls back to the defaults.
#   DRY_RUN                If 1, log every state-changing action but skip
#                          the actual VM start/swap/mv calls. The
#                          ransomware scanner and canary check still run
#                          (they are read-only and useful for setup
#                          verification). Use this to validate the
#                          script's wiring before trusting it with a
#                          real Dirty VHD. Default 0.

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
WHITELIST_FILE=${WHITELIST_FILE:-$HOME/osr-config/whitelist.txt}
DRY_RUN=${DRY_RUN:-0}

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s  %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "FATAL: $*"
    exit 1
}

# run <cmd> <args...>: execute <cmd> normally, OR if DRY_RUN=1, log
# what would have run and skip the call. Use for any state-changing
# operation (VBoxManage start/clone/storageattach, mv, rm of files
# we'd want to keep around for forensic inspection, etc.).
# In live mode, stdout+stderr of <cmd> go to LOG_FILE so VBoxManage
# noise doesn't spam the operator's terminal. Callers should NOT add
# their own >>"$LOG_FILE" 2>&1 redirect — run handles that.
# Returns the underlying command's exit code, or 0 in dry-run.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN  would execute: $*"
        return 0
    fi
    "$@" >>"$LOG_FILE" 2>&1
}

# Wait for the named VM to leave the running state. Force-poweroff if it
# overruns MAX_WAIT_SEC. Returns 0 if the VM stopped cleanly (or after a
# clean ACPI shutdown), 1 if we had to force it off.
wait_for_vm_off() {
    local vm=$1
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN  would wait for $vm to power off"
        return 0
    fi
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
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN  would archive $DEST_DIR -> $ARCHIVE_DIR/<timestamp> and prune > $ARCHIVE_KEEP"
        return 0
    fi
    mkdir -p "$ARCHIVE_DIR"
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local target="$ARCHIVE_DIR/$ts"
    log "Archiving $DEST_DIR -> $target"
    if mv "$DEST_DIR" "$target"; then
        mkdir -p "$DEST_DIR"
        if [ "${SUSPICIOUS_SESSION:-0}" -eq 1 ]; then
            touch "$target.SUSPICIOUS"
            log "Marked archive as SUSPICIOUS: $target.SUSPICIOUS"
        fi
    else
        log "WARN: failed to archive $DEST_DIR; falling back to rm -rf"
        rm -rf "${DEST_DIR:?}"/*
    fi
    # Prune to ARCHIVE_KEEP most recent. Filter the .SUSPICIOUS marker
    # files so they're counted with their archive dir; we prune both.
    ls -1t "$ARCHIVE_DIR" 2>/dev/null \
        | grep -v '\.SUSPICIOUS$' \
        | tail -n +"$((ARCHIVE_KEEP + 1))" \
        | while read -r old; do
            log "Pruning old archive: $old"
            rm -rf "${ARCHIVE_DIR:?}/$old"
            rm -f "${ARCHIVE_DIR:?}/${old}.SUSPICIOUS"
        done
}

# Patterns of files commonly created by ransomware. Lists are not
# exhaustive; cover most commodity families seen in the wild.
# See docs/ransomware-defense.md for the full threat-model context.
RANSOM_EXTENSIONS=(
    ".locked" ".lock" ".encrypted" ".encrypt" ".enc"
    ".crypt" ".crypted" ".crypto"
    ".aes" ".rsa"
    ".RYK" ".ryuk" ".ryk"
    ".conti" ".lockbit" ".crylock" ".crinf" ".crjoker"
    ".wncry" ".wcry" ".wnry" ".wnryt"
    ".babuk" ".anatova" ".lokd" ".lockd"
    ".nemty" ".sodin" ".sodinokibi"
    ".pay" ".pays" ".paymst"
    ".cerber" ".coverton" ".cryptolocker" ".cryptowall"
    ".djvu" ".stop"
    ".cuba" ".dharma" ".phobos" ".medusa" ".blackcat"
)

RANSOM_NOTE_PATTERNS=(
    "HOW_TO_DECRYPT*"
    "HOW_TO_RESTORE*"
    "README_TO_DECRYPT*"
    "DECRYPT_INSTRUCTIONS*"
    "DECRYPTION_INSTRUCTIONS*"
    "RECOVERY_INSTRUCTIONS*"
    "RECOVERY_KEY*"
    "FILES_ENCRYPTED*"
    "RESTORE_FILES*"
    "!_INFO.txt"
    "!_NOTICE.txt"
    "!INSTRUCTI0NS!*"
    "!README_DECRYPT*"
    "_readme.txt"
    "_open_.txt"
    "RYUK*.txt"
    "CONTI*.txt"
    "LOCKBIT*.txt"
)

# scan_for_ransomware_signs <dir>
# Returns 0 if clean, 1 if any indicator matched. Logs every hit and
# (capped at 5 file paths per pattern) the actual matching files.
scan_for_ransomware_signs() {
    local dir=$1
    local hits=0

    if [ ! -d "$dir" ]; then
        log "Ransomware scan: $dir does not exist; skipping"
        return 0
    fi

    for ext in "${RANSOM_EXTENSIONS[@]}"; do
        local count
        count=$(find "$dir" -type f -iname "*${ext}" 2>/dev/null | wc -l | tr -d ' ')
        if [ "${count:-0}" -gt 0 ]; then
            log "RANSOMWARE_INDICATOR  extension '${ext}': $count file(s)"
            find "$dir" -type f -iname "*${ext}" 2>/dev/null | head -5 | \
                while read -r f; do log "    $f"; done
            if [ "$count" -gt 5 ]; then
                log "    ... and $((count - 5)) more"
            fi
            hits=$((hits + 1))
        fi
    done

    for pat in "${RANSOM_NOTE_PATTERNS[@]}"; do
        local matches
        matches=$(find "$dir" -type f -iname "$pat" 2>/dev/null)
        if [ -n "$matches" ]; then
            log "RANSOMWARE_INDICATOR  ransom-note pattern '${pat}'"
            echo "$matches" | head -5 | while read -r f; do log "    $f"; done
            hits=$((hits + 1))
        fi
    done

    if [ "$hits" -eq 0 ]; then
        log "Ransomware scan: clean"
    else
        log "Ransomware scan: $hits indicator type(s) matched"
    fi

    [ "$hits" -eq 0 ]
}

# Allow this file to be sourced as a library by test-cycle.sh and similar.
# When sourced, only the env-var defaults and function definitions are
# wanted; the main cycle flow below should be skipped.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

mkdir -p "$(dirname "$LOG_FILE")"
log "=== cycle start (DIRTY=$DIRTY_VM, CLEAN=$CLEAN_VM) ==="
if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN  state-changing actions will be logged but skipped"
    log "DRY-RUN  read-only steps (sentinel check, ransomware scan, canary"
    log "DRY-RUN  flag check) DO run so wiring can be validated"
fi

# Stage the host-side whitelist (managed by host-ui) into the shared
# folder so shutdown.exe picks it up. Absence is non-fatal — shutdown.exe
# falls back to its hardcoded generate_whitelist() in that case, which
# matches the engine's pre-host-ui behavior.
if [ -f "$WHITELIST_FILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN  would copy $WHITELIST_FILE -> $DEST_DIR/whitelist.txt"
    else
        mkdir -p "$DEST_DIR"
        if cp "$WHITELIST_FILE" "$DEST_DIR/whitelist.txt"; then
            log "Staged host-side whitelist ($WHITELIST_FILE) into $DEST_DIR/whitelist.txt"
        else
            log "WARN: could not copy $WHITELIST_FILE to $DEST_DIR/whitelist.txt; cycle will use shutdown.exe's hardcoded defaults"
        fi
    fi
else
    log "No host-side whitelist at $WHITELIST_FILE; cycle will use shutdown.exe's hardcoded defaults"
fi

# 1. Dirty VM — the user's session
log "Starting $DIRTY_VM"
if ! run VBoxManage startvm "$DIRTY_VM"; then
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
    run rm -f "$SENTINEL"
else
    log "WARN: $SENTINEL missing — Shutdown.exe may not have completed"
fi

# 2. Ransomware scan on the dirty session's data BEFORE the clean VM
#    restores it. Two independent signals:
#      a) Extension/ransom-note pattern scan (catches commodity ransomware
#         that appends extensions or drops notes).
#      b) Canary verification flag from Shutdown.exe (catches
#         encryption-in-place that doesn't change extensions — the
#         cleaner ransomware families).
#    If either triggers, suppress the restore by deleting dir_desc.txt.
#    Boot.exe will then have nothing to copy back, and the next user
#    gets a fresh clean Windows. The encrypted data is preserved in the
#    archive (marked .SUSPICIOUS) so an admin can recover legitimate
#    files via Tailscale SSH.
SUSPICIOUS_SESSION=0
if ! scan_for_ransomware_signs "$DEST_DIR"; then
    SUSPICIOUS_SESSION=1
fi
CANARY_FLAG="$DEST_DIR/canary-failure.flag"
if [ -f "$CANARY_FLAG" ]; then
    log "RANSOMWARE_INDICATOR  Shutdown.exe reported canary tampering:"
    while read -r line; do log "    $line"; done < "$CANARY_FLAG"
    SUSPICIOUS_SESSION=1
    run rm -f "$CANARY_FLAG"
fi
if [ "$SUSPICIOUS_SESSION" -eq 1 ]; then
    log "WARN: dirty session flagged SUSPICIOUS; suppressing restore for this cycle"
    log "WARN: encrypted/suspicious files preserved in archive but NOT propagated"
    run rm -f "$DEST_DIR/dir_desc.txt"
fi

# 3. Clean VM — Boot.exe restores files, then shuts itself off
log "Starting $CLEAN_VM"
if ! run VBoxManage startvm "$CLEAN_VM"; then
    log "ERROR: could not start $CLEAN_VM; user files may be stranded in $DEST_DIR"
    archive_dest
    exit 1
fi
log "Waiting for $CLEAN_VM to power off"
wait_for_vm_off "$CLEAN_VM"

# 4. Replace dirty VHD with a fresh clone of the clean VHD.
#    Clone first to a sibling .new file; only swap once that succeeds.
#    This way a partial clone never leaves the user without a Dirty disk.
log "Replacing dirty VHD via clone-then-rename"
NEW_VHD="${DIRTY_VHD%.vhd}.new.vhd"

if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN  would detach $DIRTY_VHD from $DIRTY_VM"
    log "DRY-RUN  would clonemedium $CLEAN_VHD -> $NEW_VHD (--format VHD)"
    log "DRY-RUN  would mv $DIRTY_VHD aside, mv $NEW_VHD into place"
    log "DRY-RUN  would re-attach swapped $DIRTY_VHD to $DIRTY_VM"
else
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
fi

# 5. Archive the shared-folder transit dir for admin rollback. If the
#    session was flagged SUSPICIOUS earlier, archive_dest also drops a
#    sibling .SUSPICIOUS marker file so admins can find the quarantined
#    sessions.
archive_dest

log "=== cycle complete ==="
