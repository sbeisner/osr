#!/usr/bin/env bash
# finalize-machine.sh — runs on first boot of a freshly-imaged OSR host.
#
# Regenerates per-machine identity that generalize-host.sh stripped from
# the master image:
#   - hostname (default osr-<mac-suffix>; operator can override later)
#   - machine-id, D-Bus machine-id
#   - SSH host keys
#
# Two manual steps remain after this script finishes; they are printed
# at the end and require the operator to be physically present (or
# remotely connected via console):
#   1. Tailscale authentication (`sudo tailscale up --ssh`)
#   2. Sysprep specialization inside the Clean VM, if Windows OOBE
#      didn't run automatically because no unattend.xml was supplied
#
# Triggered by osr-finalize.service (oneshot, gated on the marker file
# /etc/osr-image-pending-finalize). Does nothing if the marker is absent.

set -uo pipefail

MARKER=/etc/osr-image-pending-finalize

if [ ! -f "$MARKER" ]; then
    echo "finalize-machine: marker $MARKER absent; nothing to do."
    exit 0
fi

log() { printf '[*] %s\n' "$*"; }

echo "=== OSR per-machine finalization ==="
echo

log "Detecting primary network interface MAC"
mac=$(ip link show 2>/dev/null \
      | awk '/link\/ether/ && $2 != "00:00:00:00:00:00" {print $2; exit}' \
      | tr -d ':')
if [ -z "$mac" ]; then
    log "WARN: could not detect a MAC address; falling back to random suffix"
    mac=$(head -c 3 /dev/urandom | xxd -p)
fi
new_hostname="osr-${mac: -6}"

log "Setting hostname to $new_hostname"
hostnamectl set-hostname "$new_hostname"

log "Regenerating machine-id"
if [ ! -s /etc/machine-id ]; then
    systemd-machine-id-setup
fi
# Older D-Bus copies machine-id from /var/lib/dbus; keep it in sync
mkdir -p /var/lib/dbus
cp -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

log "Regenerating SSH host keys"
if ! find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -print -quit | grep -q .; then
    ssh-keygen -A
fi
systemctl restart ssh.service 2>/dev/null || true

log "Ensuring Tailscale daemon is up (auth still pending)"
systemctl enable --now tailscaled.service 2>/dev/null || true

log "Removing finalize marker"
rm -f "$MARKER"

log "Disabling osr-finalize.service (re-enabled by generalize-host.sh next time)"
systemctl disable osr-finalize.service 2>/dev/null || true

cat <<'EOF'

=== OSR finalize complete ===

Two manual steps remain to bring this machine fully online:

  1. Authenticate Tailscale (over local console — kiosk lockdown is
     about to take over the screen):

         sudo tailscale up --ssh

     A login URL prints. Open it on any device, sign in.

  2. If your master image was built without a Windows answer file
     (unattend.xml), the Clean VM will prompt for OOBE on its next
     boot. Open the Clean-2 VM in VirtualBox once, walk through OOBE
     (local account, time zone, etc.), reach the desktop, then shut
     it down. Subsequent cycles will run unattended.

After both: reboot. The kiosk loop will take over and the machine
behaves like the original master from the operator's perspective.

EOF
