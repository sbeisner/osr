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
       sudo tailscale up --ssh
4. Open VirtualBox, set Default Machine Folder to /home/kiosk/VirtualBox VMs
   (Preferences → General). Otherwise the kiosk loop won't be able to
   read the VMs.
5. Build engine/pbosr/ and engine/Boot/ on a Windows machine; copy the
   resulting Shutdown.exe and Boot.exe to a USB stick.
6. Create the Clean-2 VM, install Windows inside it, configure
   Defender's Controlled Folder Access, install Boot.exe as the
   logon-time scheduled task, take a snapshot.
7. Clone Clean-2 to Dirty-2. Install Shutdown.exe as the Group Policy
   shutdown script.
8. Open Dirty-2 once, View → Full-screen, shut it down cleanly.
9. Reboot the host. You're done.
```

## 1. Pick the host hardware

You need a machine with hardware virtualization (VT-x / AMD-V) enabled in
the BIOS, **16 GB of RAM minimum** (8 GB for the Windows VM plus
overhead for Linux and VirtualBox itself; the procedure below allocates
8 GB to the VM), and at least 128 GB of disk (Clean and Dirty VHDs
both live on this disk; each Windows install is ~30 GB, plus free space
for snapshots and the rolling 7-shift archive).

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
5. **Disk encryption** is a tradeoff to think through. LUKS full-disk
   encryption protects against drive theft, but means someone has to
   type the LUKS passphrase at every boot — defeating the unattended
   kiosk model. Three options:
   - **Skip LUKS** (acceptable when the machine is physically secured
     in a locked nurses' station or office and theft is unlikely).
   - **LUKS + TPM auto-unlock** (`clevis` + `tang` or
     `systemd-cryptenroll --tpm2`) — encrypted at rest, auto-unlocks
     on boot if the same TPM/motherboard is present. Real solution
     for production deployments; non-trivial to set up.
   - **LUKS with manual passphrase** at every boot — only viable if
     someone is on-site each morning to type it.
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
- Creates a `kiosk` user with no sudo, in the `vboxusers` group.
- Configures auto-login as `kiosk` on every boot.
- Installs `host.sh`, `kiosk-loop.sh`, and `osr-status.sh` to
  `/opt/osr/engine/` and symlinks `osr-status` onto `$PATH`.
- Drops an autostart `.desktop` entry in `~kiosk/.config/autostart/`
  pointing at `kiosk-loop.sh`.
- Locks down screensaver, power-suspend, and the GDM user list via
  `dconf` system database.
- Disables Ctrl+Alt+F1..F12 (Xorg `DontVTSwitch`), Ctrl+Alt+Backspace
  (`DontZap`), Magic SysRq, and the VirtualBox host-key combo for
  the `kiosk` user.
- Installs Tailscale (does NOT authenticate it; you do that next).

### 4a. Authenticate Tailscale right now

Once `setup-host.sh` finishes, run:

```bash
sudo tailscale up --ssh
```

This prints a URL. Open it on any device signed into your Tailscale
account. **Do this before moving on.** The kiosk lockdown takes effect
on the next graphical session, and once the kiosk loop owns the screen,
running interactive commands locally is awkward. Tailscale + SSH gets
you back in remotely from anywhere; this is the moment to set it up.

After `tailscale up` reports success, verify:

```bash
tailscale status
```

You should see this machine listed with an IP starting with `100.`.

### 4b. Pre-create the shared-folder directory

The VirtualBox shared folder you'll configure in section 6 needs to
exist on the host before the VM tries to mount it:

```bash
sudo -u kiosk mkdir -p /home/kiosk/dest
```

Do **not** reboot yet — the VMs don't exist.

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

1. **Open VirtualBox.** In Ubuntu, hit the Super (Windows) key, type
   `virtualbox`, click the icon. Or run `virtualbox` from a terminal.

2. **CRITICAL: set the default machine folder to live under the kiosk
   user's home.** VirtualBox defaults to `~/VirtualBox VMs/` of whoever
   started it — i.e., your admin user. But the `kiosk` user is the one
   that runs `host.sh` later; it has no read access to admin's home.
   If you skip this step, the kiosk loop will not find the VMs.

   In VirtualBox: **File → Preferences → General → Default Machine
   Folder → set to `/home/kiosk/VirtualBox VMs`**. Click OK. New VMs
   will land there.

3. **Machine → New** → Name `Clean-2`, Type Microsoft Windows,
   Version Windows 11 64-bit.
4. Memory: 8192 MB.
5. Hard disk: **Create a virtual hard disk now → VHD (not VDI), Dynamically
   allocated, 80 GB**. The OSR engine swaps these via `VBoxManage clonemedium`,
   which works for VHD; default VDI works too but VHD is what the included
   `host.sh` references.
6. **Settings → Storage → Empty optical drive → Choose disk file →
   point at your Windows 11 ISO**.
7. **Settings → Shared Folders → Add**:
   - Folder Path: `/home/kiosk/dest` (you pre-created this in step 4b)
   - Folder Name: `dest`
   - Auto-mount: yes; Mount point: leave blank; Make permanent.
8. **Settings → Network → Adapter 1**: confirm "Attached to: NAT"
   (the default). **Do NOT use Bridged** — see "Network configuration
   for the VMs" near the end of this doc.
9. Start the VM, install Windows.
   - **Use a local account, not a Microsoft account.** Pick a generic
     operator name (e.g. `staff`).
   - **Windows 11 hides the local-account option** in retail installers.
     Workaround: at the network setup screen, press `Shift+F10` to open
     a command prompt, type `oobe\BypassNRO`, press Enter. The system
     reboots and the next pass-through offers "I don't have internet"
     → "Continue with limited setup" which lets you create a local
     account.
10. Once Windows is up, install **VirtualBox Guest Additions**: `Devices →
    Insert Guest Additions CD image → run setup.exe`. Reboot.
11. Activate Windows with your license. Pause Windows Update for as long
    as it'll let you (Settings → Windows Update → Pause for 5 weeks). You
    do not want updates fighting the OSR cycle during the demo period.
12. Install the customer's software stack: Office, QuickBooks, Outlook,
    whatever they use. Configure it.
13. **Configure ransomware protection.** Microsoft Defender's Controlled
    Folder Access (CFA) is the highest-leverage thing you can turn on
    inside the Clean image. It blocks unauthorized apps from writing to
    user data folders, which defeats most commodity ransomware before
    encryption can land. Because CFA's policy is part of the Clean image,
    it's restored to a known-good state on every cycle — a Dirty-side
    compromise can't permanently disable it.

    Open an **admin** PowerShell (right-click Start → "Windows PowerShell
    (Admin)") and run:

    ```powershell
    # Turn on Controlled Folder Access
    Set-MpPreference -EnableControlledFolderAccess Enabled

    # Add the user data paths from the OSR whitelist as protected folders
    $u = "C:\Users\staff"   # change to whatever operator name you used
    Add-MpPreference -ControlledFolderAccessProtectedFolders @(
        "$u\Desktop",
        "$u\Documents",
        "$u\Pictures",
        "$u\Music",
        "$u\Videos",
        "$u\AppData\Roaming\Microsoft\Signatures",
        "$u\AppData\Roaming\Microsoft\UProof",
        "C:\Users\Public\Documents\Intuit\QuickBooks"
    )

    # Allow the legitimate apps that need to write to protected folders.
    # IMPORTANT: include C:\osr\Boot.exe (added in step 15) so OSR's own
    # restore step can write user files back into the protected folders.
    # Without this, Boot.exe gets blocked by CFA and the restore fails.
    Add-MpPreference -ControlledFolderAccessAllowedApplications @(
        "C:\osr\Boot.exe",
        "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
        "C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE",
        "C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE",
        "C:\Program Files\Microsoft Office\root\Office16\POWERPNT.EXE"
    )

    # Verify
    Get-MpPreference | Select-Object EnableControlledFolderAccess, `
        ControlledFolderAccessProtectedFolders, `
        ControlledFolderAccessAllowedApplications
    ```

    Also confirm that **cloud-delivered protection** and **automatic
    sample submission** are on (Settings → Update & Security → Windows
    Security → Virus & threat protection → Manage settings). These
    update Defender's definitions during each Dirty session, which is
    important since the Clean image is otherwise frozen.

    See `../docs/ransomware-defense.md` for the full threat model and
    why this is the highest-priority preventive measure.

14. **Make `C:\osr` and copy Boot.exe in.** From the same admin
    PowerShell:

    ```powershell
    New-Item -ItemType Directory -Path C:\osr -Force | Out-Null
    Copy-Item E:\Boot.exe C:\osr\Boot.exe   # adjust path to your USB drive letter
    ```

15. **Wire `Boot.exe` to run at logon as a Scheduled Task.** Boot.exe
    is what restores the user's files in the cloned Clean VM during
    each cycle — it must run automatically as soon as the operator
    logs in. Step-by-step in Task Scheduler:

    1. Start → type `Task Scheduler`, open it.
    2. Right pane: **Create Task...** (not "Create Basic Task").
    3. **General tab**:
       - Name: `OSR Boot`
       - Description: `Runs C:\osr\Boot.exe at logon to restore user files`
       - Security options: select **"Run whether user is logged on or not"**
       - Check **"Run with highest privileges"**
       - Configure for: `Windows 10` (works for Win11 too)
    4. **Triggers tab → New...**:
       - Begin the task: `At log on`
       - Specific user: select your operator account (e.g. `staff`)
       - Click OK.
    5. **Actions tab → New...**:
       - Action: `Start a program`
       - Program/script: `C:\osr\Boot.exe`
       - Click OK.
    6. **Conditions tab**: uncheck **"Start the task only if the computer
       is on AC power"** (the kiosk PC may not have a battery the OS
       recognizes).
    7. **Settings tab**: leave defaults; in particular, leave
       "Allow task to be run on demand" checked.
    8. Click OK. Windows prompts for the operator account password —
       enter it.

16. **Do not log out yet.** From this point forward, if you log out and
    log back in to Clean-2, Boot.exe will run, find no `dir_desc.txt`,
    and immediately shut the VM down (that's its designed behavior on
    a fresh Clean boot). The current logged-in session is the last one
    where you can work normally before the snapshot.

    From the current session: **Start → Power → Shut down**. Wait for
    the VM to power off in VirtualBox manager.

17. Right-click Clean-2 in the VirtualBox manager → **Snapshots → Take
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
   - **Storage**: confirm the disk is at
     `/home/kiosk/VirtualBox VMs/Dirty-2/Dirty-2.vhd`. If VirtualBox
     cloned it to a different name, either rename it so `host.sh` can
     find it, or set the `DIRTY_VHD` env var in `/opt/osr/engine/host.sh`.
   - **Shared Folders**: same as Clean-2 — `/home/kiosk/dest` named
     `dest`, auto-mount, permanent.
   - **Network**: Adapter 1 should still be NAT (inherited from clone).
     Confirm.
4. **Disable the OSR Boot scheduled task in Dirty-2.** The clone copied
   the task you created in Clean-2 step 15. On the Dirty side you do
   NOT want Boot.exe running at logon — you want the operator's
   normal Windows session.
   - Open Task Scheduler in the cloned Dirty-2 VM, find "OSR Boot",
     right-click → **Disable**.
   - Alternatively, **Delete** the task.
5. Open an admin PowerShell in Dirty-2:

   ```powershell
   # C:\osr already exists from the clone; replace Boot.exe with Shutdown.exe
   Remove-Item C:\osr\Boot.exe -ErrorAction SilentlyContinue
   Copy-Item E:\Shutdown.exe C:\osr\Shutdown.exe   # adjust drive letter
   ```

6. **Wire `Shutdown.exe` as a Group Policy shutdown script.** This
   runs Shutdown.exe whenever the user issues a shutdown, before
   Windows finishes powering off.
   1. Start → type `gpedit.msc` → Enter.
      (If gpedit is missing — Windows Home doesn't ship it — you can
      enable it via DISM, but consider upgrading the VM's Windows
      edition to Pro instead. Pro is what production should run on.)
   2. Navigate the left tree to:
      **Computer Configuration → Windows Settings → Scripts (Startup/Shutdown)**.
   3. Right pane: double-click **Shutdown**.
   4. Click **Add...** → **Browse...** → navigate to `C:\osr` →
      select `Shutdown.exe` → Open.
   5. **Script Parameters**: leave blank.
   6. Click OK on the Add dialog, then OK on the Shutdown Properties
      dialog.
   7. Verify: at the top of the Shutdown Properties dialog, with
      **PowerShell Scripts** tab, you should see... actually no,
      Shutdown.exe is a regular .exe, it shows under the **Scripts**
      tab. Confirm `C:\osr\Shutdown.exe` is listed.

7. **Test it**: from inside Dirty-2, shut Windows down (Start → Power →
   Shut down). The VM should run Shutdown.exe (a brief console window
   may flash), the whitelisted folders should appear in
   `/home/kiosk/dest/` on the Linux host, and the VM should power off.

   Verify on the Linux host (open a terminal as your admin user):

   ```bash
   sudo ls -la /home/kiosk/dest/
   ```

   You should see numbered subfolders (`0`, `1`, ...), a
   `dir_desc.txt`, a `shutdown.log`, and a `shutdown-complete.flag`.
   Also: `cat /home/kiosk/dest/shutdown.log` to see the per-entry
   log Shutdown.exe wrote.

8. **Switch Dirty-2 to fullscreen and save the preference.** Start
   Dirty-2 again. Once Windows logs in, press `Right-Ctrl + F` (the
   default VirtualBox host key for the admin user — the kiosk user's
   host key was neutered by `setup-host.sh` but yours is unchanged).
   The VirtualBox window goes fullscreen. Shut Windows down cleanly.
   VirtualBox remembers the fullscreen mode for next launch.

## 8. Test the full cycle manually

Before relying on the autostart, run one cycle by hand to make sure
everything talks to everything:

```bash
sudo -u kiosk /opt/osr/engine/host.sh
```

What you should see (also tailed live in `~kiosk/osr-host.log`):

1. Dirty-2 boots up in fullscreen, sits at the Windows login.
2. (Log in. Open a few apps, save some test files in Documents,
   shut down.)
3. Host log: "Shutdown.exe completed cleanly (sentinel present)"
4. Host log: "Ransomware scan: clean"
5. Host log: "Starting Clean-2"
6. Clean-2 boots up briefly. Boot.exe runs at logon, restores the
   whitelisted files from `/home/kiosk/dest/`, drops `osr-canary.txt`
   into each whitelisted folder, then shuts the VM down. (You should
   not need to interact with Clean-2 at all.)
7. Host log: "Replacing dirty VHD via clone-then-rename"
8. Host log: "Archiving /home/kiosk/dest -> /home/kiosk/osr-archive/<ts>"
9. Host log: "=== cycle complete ==="
10. `host.sh` exits.

If you start Dirty-2 again now, log in, and check Documents, you
should see the files you saved AND a new `osr-canary.txt` (created
by Boot.exe — that's the ransomware-detection canary; tell users
not to delete it).

If anything misbehaves at this stage, fix it before turning on the
kiosk loop — debugging is much harder once the host auto-boots into
the VM. Useful commands:

```bash
osr-status                                    # one-page health summary
tail -f ~kiosk/osr-host.log                   # live log of host.sh
sudo cat /home/kiosk/dest/shutdown.log        # last shutdown's log
ls -la /home/kiosk/osr-archive/               # archived sessions
```

## 9. Turn on the kiosk loop

Reboot the host. The kiosk user auto-logs-in, the autostart entry runs
`kiosk-loop.sh`, which calls `host.sh` repeatedly. End-users see Windows
fullscreen and never know there's a Linux underneath.

### Diagnostics over the phone — `osr-status`

When a customer calls saying "the computer's broken," the admin SSHes
in via Tailscale and runs:

```
osr-status
```

It prints a one-page health summary: most recent cycle outcome, error
and warning counts, any SUSPICIOUS-flagged sessions in the archive,
VirtualBox VM states (including a warning if the Dirty VM is on a
bridged adapter that exposes it to the customer's LAN), Tailscale
status, disk usage, and reminders for things the host can't check
(like Defender's Controlled Folder Access state inside the Clean VM).

Read-only. Safe to run any time. The non-technical operator on-site
can also run it and paste the output to support — no risk of breaking
anything.

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
| Need to update Windows / install software | Stop kiosk loop (`sudo systemctl stop gdm` or kill kiosk-loop.sh's PID over Tailscale SSH), snapshot Clean-2, do the work, retake snapshot |
| Need to add a path to the whitelist       | Edit `engine/pbosr/shutdown.cpp`, rebuild on Windows, redeploy `Shutdown.exe` to Dirty-2 |
| Suspicious archive flagged by scanner     | Investigate `~kiosk/osr-archive/<ts>/` and the matching `.SUSPICIOUS` marker; copy out any legitimate user files; the encrypted ones stay quarantined |
| Need a maintenance shell, remote          | `tailscale ssh admin@<machine>` from your laptop |
| Need a maintenance shell, on-site         | Reboot, hold `Shift` at GRUB → "Advanced options" → "recovery mode" → "root shell". Ctrl+Alt+F2 does NOT work while the kiosk session is running (lockdown disables VT switching). |

## Network configuration for the VMs

Both the Clean and Dirty VMs **must** be on a NAT or NAT-Network
adapter, not a bridged adapter. Bridged exposes the VM directly to
the customer's LAN, which means a compromised Dirty session can scan
and attack other devices on that LAN (printers, NAS, other staff
workstations). NAT mode gives the user full outbound internet access
(needed for browsing, email, Defender update lookups) while presenting
the VM as a single host behind the Linux machine's IP.

VirtualBox's default for new VMs is NAT, so this usually works out of
the box. To verify on a deployed host:

```
osr-status
```

The "VirtualBox VMs" section explicitly flags `nic1=bridged` with a
WARN line if it sees one. Fix via VBoxManage if needed:

```
VBoxManage modifyvm Dirty-2 --nic1 nat
VBoxManage modifyvm Clean-2 --nic1 nat
```

For customers with multiple kiosks that need to see each other (rare —
each machine is meant to be self-contained), use NAT-Network mode and
configure a shared NAT-Network in VirtualBox. Do not use bridged.

## What's still missing for paid customers

`host.sh` is config-driven (env vars at the top), logs to
`~/osr-host.log`, swaps disks via clone-then-rename (so a clone failure
doesn't brick the machine), and snapshots the shared-folder transit dir
for admin rollback (rolling 7-shift history under `~/osr-archive/`).
`shutdown.cpp` and `boot.cpp` log per-entry success/failure and write
canary files for tamper detection. `setup-host.sh` locks down VT
switching and the VBox host-key combo, installs Tailscale, and adds
the `osr-status` health check.

What's still blocking a paid deploy is documented in detail in
`../HANDOFF.md` under "Before deploying to real users" — the headline
remaining items being: master-image clone workflow for multi-machine
deploys, fleet-update story, license-model decision, and a couple of
design-level items (read-only host-side mount during user sessions,
VSS for locked Outlook .pst files).

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
