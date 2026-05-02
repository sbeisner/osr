#!/usr/bin/env bash
# kiosk-loop.sh — entry point for a deployed OSR host.
#
# host.sh runs one cycle: start the Dirty VM, wait for it to power off,
# start the Clean VM, wait, then atomically replace Dirty's disk image with
# a fresh clone of Clean's. This wrapper runs that cycle in an infinite
# loop so the host machine continuously serves users (one per "shift").
#
# Place this script in /opt/osr/engine/ alongside host.sh, or wherever you
# installed the engine. The autostart .desktop entry created by
# setup-host.sh launches it on the kiosk user's graphical session.

set -u

cd "$(dirname "$(readlink -f "$0")")"

LOG="${HOME}/osr-kiosk.log"

echo "=== osr kiosk loop starting at $(date) ===" | tee -a "$LOG"

while true; do
    echo "--- cycle starting at $(date) ---" | tee -a "$LOG"
    if ! ./host.sh 2>&1 | tee -a "$LOG"; then
        echo "host.sh exited non-zero; sleeping 30s before retry" | tee -a "$LOG"
        sleep 30
        continue
    fi
    # Brief pause between cycles to avoid pegging in case a misconfigured
    # VM powers off immediately on every boot.
    sleep 5
done
