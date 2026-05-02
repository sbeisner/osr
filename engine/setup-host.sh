#!/usr/bin/env bash
# setup-host.sh — configure a fresh Ubuntu 24.04 LTS Desktop install as
# an OSR host machine.
#
# Run as root or with sudo on a clean Ubuntu 24.04 install.
# Idempotent — safe to re-run.
#
# This script handles the boring, mechanical part of provisioning. It does
# NOT create the VirtualBox VMs themselves (Clean-2 and Dirty-2) or install
# Windows in them — those steps need a Windows ISO, a license, and decisions
# about which software the customer wants. See engine/DEPLOYMENT.md for the
# full procedure.
#
# What this script does:
#   1. Verifies we're on Ubuntu 24.04
#   2. Installs VirtualBox + the Extension Pack (PUEL accepted automatically)
#   3. Forces GDM to use X11 (VirtualBox does not play well with Wayland)
#   4. Creates a 'kiosk' user with no sudo and a locked-down shell
#   5. Configures GDM to auto-login the kiosk user on boot
#   6. Drops engine/host.sh + engine/kiosk-loop.sh into /opt/osr/engine/
#   7. Creates an autostart .desktop entry that launches kiosk-loop.sh on
#      the kiosk user's graphical session
#
# What you must do manually after this script:
#   - Create the Clean-2 VirtualBox VM, install Windows, install the
#     OSR shutdown.exe and boot.exe binaries, set fullscreen as the
#     default display mode, take an initial snapshot.
#   - Clone Clean-2 to Dirty-2.
#   - Configure the \\VBoxSvr\dest shared folder pointing at ~kiosk/dest.
#   - Reboot.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo $0)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Distro check
# ---------------------------------------------------------------------------
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "This script targets Ubuntu 24.04 LTS Desktop. Detected: $PRETTY_NAME" >&2
    echo "Adapt the apt commands and gdm config paths if you are on a different distro." >&2
    exit 1
fi
echo "[ok] Detected $PRETTY_NAME"

# ---------------------------------------------------------------------------
# 2. VirtualBox + Extension Pack
# ---------------------------------------------------------------------------
echo "[*] Updating apt index"
apt-get update -y

echo "[*] Installing VirtualBox + Extension Pack"
# multiverse must be enabled for virtualbox-ext-pack
add-apt-repository -y multiverse
apt-get update -y
# Auto-accept Oracle's PUEL during ext-pack install
echo "virtualbox-ext-pack virtualbox-ext-pack/license select true" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    virtualbox \
    virtualbox-ext-pack \
    virtualbox-guest-utils \
    dconf-cli

# ---------------------------------------------------------------------------
# 3. Force X11 (Wayland breaks VirtualBox keyboard/mouse capture)
# ---------------------------------------------------------------------------
echo "[*] Forcing GDM to use X11 (disabling Wayland)"
mkdir -p /etc/gdm3
GDM_CONF=/etc/gdm3/custom.conf
touch "$GDM_CONF"
# Replace any existing WaylandEnable line, or append one
if grep -qE '^\s*#?\s*WaylandEnable=' "$GDM_CONF"; then
    sed -i 's|^\s*#\?\s*WaylandEnable=.*|WaylandEnable=false|' "$GDM_CONF"
else
    if ! grep -q '^\[daemon\]' "$GDM_CONF"; then
        printf '\n[daemon]\n' >> "$GDM_CONF"
    fi
    sed -i '/^\[daemon\]/a WaylandEnable=false' "$GDM_CONF"
fi

# ---------------------------------------------------------------------------
# 4. Kiosk user
# ---------------------------------------------------------------------------
KIOSK_USER=kiosk
if ! id -u "$KIOSK_USER" >/dev/null 2>&1; then
    echo "[*] Creating $KIOSK_USER user"
    adduser --disabled-password --gecos "OSR kiosk" "$KIOSK_USER"
    # No sudo, no extra groups beyond the default user group + vboxusers
    usermod -aG vboxusers "$KIOSK_USER"
else
    echo "[ok] $KIOSK_USER already exists"
    usermod -aG vboxusers "$KIOSK_USER" || true
fi

KIOSK_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)

# ---------------------------------------------------------------------------
# 5. Auto-login
# ---------------------------------------------------------------------------
echo "[*] Configuring GDM to auto-login $KIOSK_USER"
if grep -qE '^\s*#?\s*AutomaticLoginEnable=' "$GDM_CONF"; then
    sed -i 's|^\s*#\?\s*AutomaticLoginEnable=.*|AutomaticLoginEnable=true|' "$GDM_CONF"
else
    sed -i '/^\[daemon\]/a AutomaticLoginEnable=true' "$GDM_CONF"
fi
if grep -qE '^\s*#?\s*AutomaticLogin=' "$GDM_CONF"; then
    sed -i "s|^\s*#\?\s*AutomaticLogin=.*|AutomaticLogin=$KIOSK_USER|" "$GDM_CONF"
else
    sed -i "/^\[daemon\]/a AutomaticLogin=$KIOSK_USER" "$GDM_CONF"
fi

# ---------------------------------------------------------------------------
# 6. Install engine scripts
# ---------------------------------------------------------------------------
ENGINE_DST=/opt/osr/engine
echo "[*] Installing engine scripts to $ENGINE_DST"
mkdir -p "$ENGINE_DST"
SRC_DIR="$(dirname "$(readlink -f "$0")")"
install -m 0755 "$SRC_DIR/host.sh"        "$ENGINE_DST/host.sh"
install -m 0755 "$SRC_DIR/kiosk-loop.sh"  "$ENGINE_DST/kiosk-loop.sh"

# ---------------------------------------------------------------------------
# 7. Autostart entry for the kiosk session
# ---------------------------------------------------------------------------
AUTOSTART_DIR="$KIOSK_HOME/.config/autostart"
echo "[*] Creating autostart entry in $AUTOSTART_DIR"
mkdir -p "$AUTOSTART_DIR"
cat > "$AUTOSTART_DIR/osr-kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OSR kiosk loop
Comment=Boot directly into the OSR Dirty VM and run the swap cycle
Exec=$ENGINE_DST/kiosk-loop.sh
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"

# ---------------------------------------------------------------------------
# 8. System-wide kiosk dconf settings (no screensaver, no power suspend)
# ---------------------------------------------------------------------------
echo "[*] Locking down screensaver/power for the kiosk session"
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d /etc/dconf/db/local.d/locks
cat > /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
cat > /etc/dconf/db/local.d/00-osr-kiosk <<'EOF'
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
EOF
cat > /etc/dconf/db/local.d/locks/00-osr-kiosk <<'EOF'
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/desktop/session/idle-delay
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
EOF
dconf update

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<'EOF'

[ok] Host setup complete.

Remaining manual steps (see engine/DEPLOYMENT.md for the full procedure):

  1. Log in as the 'kiosk' user one time (Ctrl+Alt+F2, then back to F1)
     or just complete this whole sequence as your admin user — both work.

  2. Create the Clean-2 VirtualBox VM:
        - Install Windows from your licensed ISO
        - Install Microsoft Edge updates, Office, QuickBooks, etc.
        - Build and copy the Boot.exe binary to C:\osr\Boot.exe and wire
          it as the post-login autorun (see DEPLOYMENT.md)
        - Take a snapshot named 'pristine'

  3. Clone Clean-2 to Dirty-2 (right-click → Clone in VirtualBox manager;
     full clone, generate new MAC).
        - Build and copy Shutdown.exe to C:\osr\Shutdown.exe and wire it
          as a Group Policy shutdown script.

  4. Configure the shared folder for both VMs: host path = ~kiosk/dest,
     mount name = dest, automount, make permanent.

  5. Open the Dirty-2 VM once manually, switch the View to Full-screen
     mode (Right-Ctrl + F), shut it down cleanly. VirtualBox saves the
     fullscreen preference.

  6. Reboot the host. The kiosk user will auto-login and Dirty-2 will
     launch fullscreen.

EOF
