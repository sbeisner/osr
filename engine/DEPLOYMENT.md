# Deploying an OSR host

This document walks through everything needed to turn a fresh Linux PC into
an OSR kiosk: a machine that boots straight into a Windows desktop, refreshes
the Windows install on every shutdown, and keeps the user's files in place.

A non-technical operator should never see the underlying Linux. The end-user
experience is "press the power button → Windows comes up → use it normally
→ shut down → next person presses power and gets a clean Windows again."

The goal of this guide is to be **boring and complete**. Follow the steps
top-to-bottom and you'll end up with a working host. If you're impatient,
skim the "TL;DR" first.

## TL;DR

```
1. Install Ubuntu 24.04 LTS Desktop on the host PC.
2. Create your own admin user during install. Skip everything optional.
3. Boot, log in, open a terminal:
       git clone https://github.com/sbeisner/osr.git ~/osr-source
       sudo ~/osr-source/engine/setup-host.sh
4. Build engine/pbosr/ and engine/Boot/ on a Windows machine; copy the
   resulting Shutdown.exe and Boot.exe to a USB stick.
5. Open VirtualBox manager. Create the Clean-2 VM, install Windows
   inside it, install Boot.exe as the auto-run, take a snapshot. Clone
   to Dirty-2, install Shutdown.exe as the GPO shutdown script.
6. Open Dirty-2 once, View → Full-screen, shut it down cleanly.
7. Reboot the host. You're done.
```

## 1. Pick the host hardware

You need a machine with hardware virtualization (VT-x / AMD-V) enabled in
the BIOS, at least 8 GB of RAM (16 GB recommended — Windows 11 wants 4 GB
minimum and Linux + VirtualBox overhead is real), and at least 128 GB of
disk (the Clean and Dirty VHDs both live on this disk; each Windows install
is ~30 GB and you need free space for snapshots).

Refurbished SFF business desktops (HP EliteDesk, Dell OptiPlex, Lenovo
ThinkCentre, anything 8th-gen Intel or newer) are ideal. Anywhere from
$150–$300 each on the used market and they all have the necessary virt
extensions. Avoid Atom-based mini PCs — VT-x is often there but performance
is rough.

## 2. Pick the host OS — Ubuntu 24.04 LTS Desktop

The host runs Linux, not Windows. Linux is cheaper (free), more stable
under continuous use, and isn't subject to the Windows update churn that
this whole project exists to insulate end-users from.

### Why Ubuntu 24.04 LTS specifically

- **LTS = "Long Term Support"**: Canonical ships security updates for
  this exact version through April 2029, with optional paid extension
  ("Ubuntu Pro" — free for personal use up to 5 machines) through 2034.
  You won't have to redo this guide for ten years.
- **VirtualBox is in the standard repos** — no third-party PPAs or manual
  signing keys.
- **Largest English-language docs and Stack Overflow corpus** of any
  desktop Linux. When something breaks, the answer is usually the first
  Google hit. This matters when the colleague's developer is the one
  troubleshooting.
- **GNOME on Ubuntu** is the default desktop and has straightforward
  auto-login configuration via GDM.

### Why not Debian, Fedora, Mint, etc.

All workable, all require small adjustments to the `setup-host.sh` script
(different package names, different GDM/SDDM/LightDM config paths). If you
have a reason to pick one of them, fine — just expect to spend an hour
adapting the setup script. Debian 12 is the closest substitute and the
adjustments are minimal.

### Wayland vs X11

VirtualBox 7 still does not handle keyboard capture cleanly on GNOME's
default Wayland session. Right-Ctrl gets eaten, fullscreen toggles
flake out, mouse integration is twitchy. **The setup script forces GDM
to use X11.** If you do nothing else, do this.

## 3. Install Ubuntu

1. Download Ubuntu 24.04 LTS Desktop ISO from https://ubuntu.com/download/desktop.
2. Flash to a USB stick (`balenaEtcher`, `Rufus`, or `dd if=ubuntu.iso of=/dev/sdX bs=4M`).
3. Boot the host machine from the USB.
4. Choose **Interactive installation → Default selection**, *not*
   Minimized — the default includes the GNOME utilities the kiosk session
   relies on.
5. **Encrypt the disk** if the host might ever be physically stolen.
   Nursing-home machines usually qualify.
6. Create your own admin user during install (something like `admin`).
   The kiosk user gets created later by the setup script.
7. Reboot when prompted, log in as the admin user, run all pending
   updates: `sudo apt update && sudo apt upgrade -y`.
8. Reboot once more.

Do not install third-party software or configure GDM yet. The setup script
does that.

## 4. Run the host setup script

```bash
git clone https://github.com/sbeisner/osr.git ~/osr-source
sudo ~/osr-source/engine/setup-host.sh
```

Read the top of `setup-host.sh` first — it tells you exactly what it will
change. In summary it:

- Installs VirtualBox + the Extension Pack (auto-accepting Oracle's PUEL).
- Disables Wayland in GDM.
- Creates a `kiosk` user with no sudo.
- Configures auto-login as `kiosk` on every boot.
- Installs `host.sh` and `kiosk-loop.sh` to `/opt/osr/engine/`.
- Drops an autostart `.desktop` entry in `~kiosk/.config/autostart/`
  pointing at `kiosk-loop.sh`.
- Locks down screensaver and power-suspend for the kiosk session via
  `dconf` system database.

After it finishes, do **not** reboot yet — the VMs don't exist.

## 5. Build the Windows binaries

The shutdown side (`pbosr/`) and boot side (`Boot/`) are MSVC C++ projects.
You need a Windows 10 or 11 machine with Visual Studio 2019+ (Community is
fine) to compile them. Ten minutes of work, once.

```
On a Windows machine with VS installed:
  1. Open engine/osr-engine.sln in Visual Studio.
  2. Right-click the solution → "Add → Existing Project" → select
     engine/Boot/Boot.vcxproj. The solution starts with only pbosr;
     adding Boot is one click.
  3. Build → Batch Build → Release | x64 for both projects.
  4. Copy the two .exe files (pbosr\x64\Release\Shutdown.exe and
     Boot\x64\Release\Boot.exe) to a USB stick. You'll install them
     inside each VM in the next step.
```

Customizations you may want to do at this step:

- Edit `engine/pbosr/shutdown.cpp` `generate_whitelist()` to match the
  actual software your customer uses. The current default covers
  Documents, Pictures, Outlook signatures, Chrome bookmarks, and shared
  QuickBooks data — fine for a typical office, but probably wrong for
  whatever specialty software your customer relies on.
- Edit the share path constants if you are not using `\\VBoxSvr\dest`.

## 6. Create the Clean-2 VirtualBox VM

This is the pristine reference image. Every clean session starts from a
fresh clone of this VM's disk.

1. Log in as your admin user, open VirtualBox.
2. **New → Name "Clean-2", Type Microsoft Windows, Version Windows 11 64-bit**.
3. Memory: 8192 MB minimum (more if the host has it).
4. Hard disk: **Create a virtual hard disk now → VHD (not VDI), Dynamically
   allocated, 80 GB**. The OSR engine swaps these via `VBoxManage clonemedium`,
   which works for VHD; default VDI works too but VHD is what the included
   `host.sh` references.
5. **Settings → System → Processor → Enable Nested VT-x/AMD-V**: skip,
   not needed unless Windows 11 is running WSL2 inside the guest.
6. **Settings → Storage → Empty optical drive → Choose disk file →
   point at your Windows 11 ISO**.
7. **Settings → Shared Folders → Add**:
   - Folder Path: `/home/kiosk/dest` (create the directory first:
     `sudo -u kiosk mkdir -p /home/kiosk/dest`)
   - Folder Name: `dest`
   - Auto-mount: yes; Mount point: leave blank; Make permanent.
8. Start the VM, install Windows. **Use a local account, not a Microsoft
   account.** Pick a generic operator name (e.g. `staff`).
9. Once Windows is up, install **VirtualBox Guest Additions**: `Devices →
   Insert Guest Additions CD image → run setup.exe`. Reboot.
10. Activate Windows with your license. Pause Windows Update for as long
    as it'll let you (Settings → Windows Update → Pause for 5 weeks). You
    do not want updates fighting the OSR cycle during the demo period.
11. Install the customer's software stack: Office, QuickBooks, Outlook,
    whatever they use. Configure it.
12. Copy `Boot.exe` from the USB stick to `C:\osr\Boot.exe`.
13. Wire it to run automatically on the *clean* boot (the one where
    Boot.exe restores files and shuts down). The cleanest way is a
    Scheduled Task at user-logon for the operator account, running
    `C:\osr\Boot.exe` with highest privileges.
14. **Crucially: do not run Boot.exe inside Clean-2 yet.** It will try to
    read `\\VBoxSvr\dest\dir_desc.txt` — there isn't one — and exit. That's
    fine; it just means there's nothing to restore. Leave it wired up.
15. Shut Windows down cleanly: Start → Power → Shut down. Wait for the VM
    to power off in VirtualBox.
16. Right-click Clean-2 in the VirtualBox manager → **Snapshots → Take
    Snapshot → name it "pristine"**. This is your rollback point if you
    ever need to redo the install.

## 7. Create the Dirty-2 VM

The dirty VM is the one users actually use. Its disk gets replaced with a
clean clone every shutdown.

1. In VirtualBox manager, right-click Clean-2 → **Clone**.
2. Name: `Dirty-2`. **MAC Address Policy: Generate new MAC for all
   network adapters.** Clone type: **Full clone**. Snapshots: **Current
   machine state**.
3. Once the clone finishes, open Dirty-2's settings:
   - **Storage**: confirm the disk is `~/VirtualBox VMs/Dirty-2/Dirty-2.vhd`.
     If VirtualBox cloned it to a different name, rename so `host.sh`
     can find it (or edit the path in `host.sh`).
   - **Shared Folders**: same as Clean-2 — `/home/kiosk/dest` named
     `dest`, auto-mount, permanent.
4. Start Dirty-2, log in.
5. Copy `Shutdown.exe` to `C:\osr\Shutdown.exe`.
6. Wire `Shutdown.exe` as a Group Policy shutdown script: `gpedit.msc →
   Computer Configuration → Windows Settings → Scripts → Shutdown → Add
   → C:\osr\Shutdown.exe`. This runs Shutdown.exe whenever the user
   issues a shutdown, before Windows finishes powering off.
7. **Test it**: shut Windows down. The VM should run Shutdown.exe (you'll
   see a brief console window), the whitelisted folders should appear in
   `/home/kiosk/dest/` on the Linux host, and the VM should power off.
8. **Switch Dirty-2 to fullscreen and save the preference**: with the VM
   running normally, press `Right-Ctrl + F`. The VirtualBox window goes
   fullscreen. Shut Windows down cleanly. VirtualBox remembers the
   fullscreen mode and uses it next launch.

## 8. Test the full cycle manually

Before relying on the autostart, run one cycle by hand to make sure
everything talks to everything:

```bash
sudo -u kiosk /opt/osr/engine/host.sh
```

You should see:
1. Dirty-2 boot up in fullscreen, sit at the Windows login.
2. (You log in, do something, shut down)
3. Console output: "running Clean"
4. Clean-2 boots up briefly (it auto-runs Boot.exe via the scheduled task,
   which copies the whitelisted files back, then shuts down)
5. Console output: "Replacing Dirty with Clean..."
6. `host.sh` exits.

If you log back into Dirty-2 you should see your files back.

If anything misbehaves at this stage, fix it before turning on the kiosk
loop — debugging is much harder once the host auto-boots into the VM.

## 9. Turn on the kiosk loop

Reboot the host. The kiosk user auto-logs-in, the autostart entry runs
`kiosk-loop.sh`, which calls `host.sh` repeatedly. End-users see Windows
fullscreen and never know there's a Linux underneath.

### Getting back to a Linux shell once the kiosk is locked down

`setup-host.sh` deliberately disables `Ctrl+Alt+F1..F12` (TTY switching)
and the VirtualBox host-key combo so end-users can't escape the VM by
accident. That same lockdown applies to you while the kiosk session is
running. To get a maintenance shell:

- **Over Tailscale SSH** (preferred): assuming you ran
  `sudo tailscale up --ssh` at deploy time, you can `tailscale ssh
  admin@<machine>` from anywhere your Tailscale account is signed in.
  This is the path that scales to many machines and the only way to
  troubleshoot a remote customer's machine without driving there.
- **Physically present, no network**: reboot, hold `Shift` at the
  GRUB menu, pick "Advanced options for Ubuntu" → "recovery mode" →
  "root shell". The kiosk session isn't running yet, so VT switching
  works there.

## 10. Recovery scenarios

| Symptom                                   | Fix                                              |
|-------------------------------------------|--------------------------------------------------|
| Dirty VM is corrupt and won't boot        | `cp ~kiosk/VirtualBox\ VMs/Clean-2/Clean-2.vhd ~kiosk/VirtualBox\ VMs/Dirty-2/Dirty-2.vhd` |
| Clean VM is corrupt                       | Roll back to the "pristine" snapshot in VirtualBox |
| Need to update Windows / install software | Power off the kiosk loop, snapshot Clean-2, do the work, retake snapshot |
| Need to add a path to the whitelist       | Edit `engine/pbosr/shutdown.cpp`, rebuild, redeploy `Shutdown.exe` to Dirty-2 |
| Need physical access to the host          | Ctrl+Alt+F2 → log in as admin                    |

## What's still missing for paid customers

`host.sh` is now config-driven (env vars at the top), logs to
`~/osr-host.log`, swaps disks via clone-then-rename (so a clone failure
doesn't brick the machine), and snapshots the shared-folder transit dir
for admin rollback (rolling 7-shift history under `~/osr-archive/`).
`shutdown.cpp` and `boot.cpp` log per-entry success/failure.
`setup-host.sh` locks down VT switching and the VBox host-key combo.

What's still blocking a paid deploy is documented in detail in
`../HANDOFF.md` under "Before deploying to real users" — the headline
items being: ransomware persistence by design (the engine restores
encrypted files dutifully alongside legitimate ones), no AV inside
either VM, no remote-support path, no master-image clone workflow for
multi-machine deploys, and no fleet-update story. None of these have
been started.

## Long-term: replace this with off-the-shelf tooling

This whole engine — Linux + VirtualBox + a swap script — is a
hand-rolled answer to a question that has commercial answers. Before
investing more engineering into it, evaluate:

- **Faronics Deep Freeze** ($30-50/seat/year): drops in on the bare-metal
  Windows install, no Linux/VBox layer. Reverts the system on every
  reboot, "ThawSpaces" hold whatever you want preserved.
- **Windows Unified Write Filter (UWF)**: built into Windows 10/11
  Enterprise IoT. Same idea; free if you have Enterprise licenses.

If the customer's price ceiling rules those out, the OSR engine is a
defensible "build" answer. If not, "buy" wins.
