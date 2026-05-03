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
#   8. Locks down VT switching, Ctrl+Alt+Backspace, the VBox host key,
#      Magic SysRq, and the GDM user list so end-users can't escape the VM
#   9. Installs Tailscale for remote admin access (does NOT authenticate;
#      that needs `sudo tailscale up` interactively after this script)
#
# What you must do manually after this script:
#   - Authenticate Tailscale: `sudo tailscale up --ssh` (browser flow).
#     The --ssh flag enables Tailscale SSH so admins can shell in without
#     managing per-machine SSH keys.
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
install -m 0755 "$SRC_DIR/host.sh"               "$ENGINE_DST/host.sh"
install -m 0755 "$SRC_DIR/kiosk-loop.sh"         "$ENGINE_DST/kiosk-loop.sh"
install -m 0755 "$SRC_DIR/osr-status.sh"         "$ENGINE_DST/osr-status.sh"
install -m 0755 "$SRC_DIR/test-cycle.sh"         "$ENGINE_DST/test-cycle.sh"
# Master-image cloning support
install -m 0755 "$SRC_DIR/generalize-host.sh"    "$ENGINE_DST/generalize-host.sh"
install -m 0755 "$SRC_DIR/finalize-machine.sh"   "$ENGINE_DST/finalize-machine.sh"
install -m 0644 "$SRC_DIR/osr-finalize.service"  /etc/systemd/system/osr-finalize.service
systemctl daemon-reload
# The service is gated on /etc/osr-image-pending-finalize and is enabled
# at master-generalization time, not now — no-op to enable it here.
# Inside-the-VM helpers — copied to a path the deployer can grab from
# the Linux host (or, equivalently, just from the github repo on a USB
# stick). Stored alongside the engine for discoverability.
install -m 0644 "$SRC_DIR/prepare-clean-vm.ps1"  "$ENGINE_DST/prepare-clean-vm.ps1"
install -m 0644 "$SRC_DIR/prepare-dirty-vm.ps1"  "$ENGINE_DST/prepare-dirty-vm.ps1"
# Symlink so admins reaching the host via Tailscale SSH can just type
# `osr-status` without remembering the install path.
ln -sf "$ENGINE_DST/osr-status.sh" /usr/local/bin/osr-status

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
# 9. Kiosk lockdown — prevent end-users from escaping the VM
# ---------------------------------------------------------------------------
echo "[*] Disabling VT switching, Ctrl+Alt+Backspace, and Magic SysRq"

# Xorg: DontVTSwitch blocks Ctrl+Alt+F1..F12 (the chord that drops to a
# console). DontZap blocks Ctrl+Alt+Backspace (which kills the X server).
# Both are accessible from inside a fullscreen VirtualBox window because
# Xorg processes them before VirtualBox sees them.
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-osr-kiosk.conf <<'EOF'
Section "ServerFlags"
    Option "DontVTSwitch" "true"
    Option "DontZap"      "true"
EndSection
EOF

# Kernel: the SysRq key (Alt+PrtSc + various second keys) can sync,
# remount, kill processes, or trigger a reboot. Disable for kiosk.
cat > /etc/sysctl.d/60-osr-kiosk.conf <<'EOF'
# Disable Magic SysRq combos on kiosk machines (default in many distros
# but explicit here so future package updates can't re-enable it).
kernel.sysrq = 0
EOF
sysctl --system >/dev/null

# VirtualBox: the "host key" (default Right-Ctrl) is what lets a VM user
# leave fullscreen, switch to seamless mode, or send Ctrl+Alt+Del. Set it
# to a key that physically does not exist on standard keyboards so the
# end-user cannot escape the VM by accident or otherwise.
echo "[*] Neutralizing the VirtualBox host-key combo for $KIOSK_USER"
sudo -u "$KIOSK_USER" mkdir -p "$KIOSK_HOME/.config/VirtualBox"
# "0" disables the combo entirely. Run as the kiosk user so the setting
# lands in their per-user VirtualBox.xml.
if ! sudo -u "$KIOSK_USER" VBoxManage setextradata global GUI/Input/HostKeyCombination "0" 2>/dev/null; then
    echo "[warn] could not set VirtualBox host key now (run once as kiosk:"
    echo "       sudo -u $KIOSK_USER VBoxManage setextradata global GUI/Input/HostKeyCombination 0"
fi

# Hide the GNOME login user list (auto-login is enabled, but defense in
# depth — if auto-login fails, the kiosk user shouldn't be selectable).
cat >> /etc/dconf/db/local.d/00-osr-kiosk <<'EOF'

[org/gnome/login-screen]
disable-user-list=true
EOF
echo '/org/gnome/login-screen/disable-user-list' >> /etc/dconf/db/local.d/locks/00-osr-kiosk
dconf update

# ---------------------------------------------------------------------------
# 10. Tailscale — remote admin access for support
# ---------------------------------------------------------------------------
# Tailscale gives the admin a way to SSH into a deployed kiosk from anywhere
# without exposing SSH to the public internet, opening firewall ports on the
# customer's network, or managing per-machine SSH keys (when used with --ssh).
# Without something like this, every "the computer's broken" call requires a
# site visit.
echo "[*] Installing Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
    # Tailscale's official installer adds their apt repo with a signed key
    # and runs `apt-get install -y tailscale`. Trust chain is HTTPS-served
    # from tailscale.com plus apt's own signing-key validation.
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "[ok] tailscale already installed"
fi

# We deliberately do NOT run `tailscale up` here — it requires either a
# pre-issued auth key or an interactive browser flow, and silently waiting
# on either is a poor UX inside a setup script. Operator runs it manually.

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<'EOF'

[ok] Host setup complete.

Remaining manual steps (see engine/DEPLOYMENT.md for the full procedure):

  1. Authenticate Tailscale (do this NOW before the kiosk lockdown
     prevents you from getting back to a shell easily):

         sudo tailscale up --ssh

     A login URL prints; open it on any device, sign in with your
     Tailscale account. The --ssh flag enables Tailscale SSH so future
     admin access does not require managing SSH keys per host.

  2. Log in as the 'kiosk' user one time (Ctrl+Alt+F2, then back to F1)
     or just complete this whole sequence as your admin user — both work.

  3. Create the Clean-2 VirtualBox VM:
        - Install Windows from your licensed ISO
        - Install Microsoft Edge updates, Office, QuickBooks, etc.
        - Build and copy the Boot.exe binary to C:\osr\Boot.exe and wire
          it as the post-login autorun (see DEPLOYMENT.md)
        - Take a snapshot named 'pristine'

  4. Clone Clean-2 to Dirty-2 (right-click → Clone in VirtualBox manager;
     full clone, generate new MAC).
        - Build and copy Shutdown.exe to C:\osr\Shutdown.exe and wire it
          as a Group Policy shutdown script.

  5. Configure the shared folder for both VMs: host path = ~kiosk/dest,
     mount name = dest, automount, make permanent.

  6. Open the Dirty-2 VM once manually, switch the View to Full-screen
     mode (Right-Ctrl + F), shut it down cleanly. VirtualBox saves the
     fullscreen preference.

  7. Reboot the host. The kiosk user will auto-login and Dirty-2 will
     launch fullscreen.

EOF
