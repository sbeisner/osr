#!/usr/bin/env bash
# generalize-host.sh — strip per-machine identity from a fully-configured
# OSR host so its disk can be imaged and the image restored to additional
# machines.
#
# Run as root on the master machine ONLY, after the master is configured
# end-to-end (Ubuntu installed, setup-host.sh complete, Tailscale
# authenticated, VMs created, prepared, tested with at least one full
# host.sh cycle). When this script finishes, the host powers off and the
# disk is ready to be imaged with dd or Clonezilla.
#
# After power-off, image the disk to a file:
#   sudo dd if=/dev/sda of=/path/to/master.img bs=4M status=progress conv=fsync
# or use Clonezilla, which has a friendlier UI for non-technical users.
#
# IMPORTANT: also Sysprep the Clean VM inside the master before running
# this — see docs/master-image-workflow.md. Without Sysprep, every cloned
# machine's Clean Windows install ends up with the same SID, which causes
# real problems if the machines ever see each other on a network.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo $0)" >&2
    exit 1
fi

# Confirm — this is destructive in the sense that it removes per-machine
# secrets. If run on the wrong machine, that machine's identity is gone.
if [ "${OSR_FORCE_GENERALIZE:-0}" -ne 1 ]; then
    cat <<EOF
This will:
  - Log this machine out of Tailscale
  - Clear SSH host keys, machine-id, D-Bus machine-id
  - Truncate systemd journal and several log files
  - Clear /tmp, /var/tmp, all bash histories
  - Clear DHCP leases
  - Mark the system for first-boot finalization
  - Power the system off

After this, the disk can be imaged and restored to additional machines.

Run again with OSR_FORCE_GENERALIZE=1 to skip this prompt.

EOF
    read -r -p "Proceed? [type GENERALIZE to confirm]: " confirm
    if [ "$confirm" != "GENERALIZE" ]; then
        echo "Aborted."
        exit 1
    fi
fi

log() { printf '[*] %s\n' "$*"; }

log "Stopping services that hold per-machine state"
systemctl stop tailscaled.service 2>/dev/null || true
systemctl stop ssh.service 2>/dev/null || true

log "Logging out of Tailscale (each cloned machine will re-auth fresh)"
if command -v tailscale >/dev/null 2>&1; then
    tailscale logout 2>/dev/null || true
fi

log "Clearing SSH host keys (regenerated on first boot)"
rm -f /etc/ssh/ssh_host_*

log "Clearing machine-id (systemd regenerates on first boot)"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

log "Vacuuming systemd journal"
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
rm -rf /var/log/journal/*

log "Truncating common log files"
for f in /var/log/syslog /var/log/auth.log /var/log/wtmp /var/log/btmp \
         /var/log/dpkg.log /var/log/kern.log /var/log/lastlog; do
    [ -f "$f" ] && : > "$f"
done

log "Clearing tempdirs"
rm -rf /tmp/* /tmp/.??* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true

log "Clearing bash histories"
for h in /root/.bash_history /home/*/.bash_history; do
    [ -f "$h" ] && : > "$h"
done

log "Clearing DHCP leases"
rm -f /var/lib/dhcp/dhclient.* 2>/dev/null || true
rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true

log "Truncating the OSR host log"
: > /home/kiosk/osr-host.log 2>/dev/null || true

log "Truncating the kiosk loop log"
: > /home/kiosk/osr-kiosk.log 2>/dev/null || true

log "Removing archived sessions (the cloned machine starts with no history)"
rm -rf /home/kiosk/osr-archive/* 2>/dev/null || true

log "Marking image as pending-finalize"
touch /etc/osr-image-pending-finalize
chmod 0644 /etc/osr-image-pending-finalize

log "Enabling osr-finalize.service for first boot"
systemctl enable osr-finalize.service 2>/dev/null || true

log "Generalization complete. Powering off in 5 seconds."
sleep 5
systemctl poweroff
