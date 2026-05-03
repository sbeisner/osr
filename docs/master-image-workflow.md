# Master-image cloning workflow

This document describes how to deploy OSR to N machines without redoing
the full DEPLOYMENT.md procedure on each one. After the first machine
("the master"), each additional machine takes ~30 minutes of
mostly-waiting-on-disk-imaging, instead of the ~3 hours of focused
work that DEPLOYMENT.md walks through.

## When to use this

- Three or more machines for the same customer (a library, a small
  nursing home, a community-center bank of public terminals).
- Multiple customer sites with the same hardware and customer-app stack.
- Re-imaging the fleet after a major Clean-VM update (Windows update,
  new software for the customer, etc.).

For one-off single-machine deploys, just follow `engine/DEPLOYMENT.md`
directly. The master-image workflow has fixed setup overhead that
isn't worth it below ~3 machines.

## What the workflow does

```
                                                   ┌──────────────┐
   ┌──────────────┐         ┌────────────────┐     │  Target #2   │
   │   Master     │  image  │  master.img    │ dd  │ (fresh disk) │
   │  (machine 0) │────────>│ (file or USB)  │────>│              │
   └──────────────┘         └────────────────┘     └──────────────┘
        │                            │                    │
   build out per                     │              first boot
   DEPLOYMENT.md                     ├─────dd──────>┌──────────────┐
        │                            │              │  Target #3   │
        ▼                            │              │   ...        │
   generalize-host.sh                ▼              └──────────────┘
   (strips identity)            ... etc                   │
                                                          ▼
                                                   finalize-machine.sh
                                                   runs once, then
                                                   self-disables
```

## Phase 1 — Build the master end-to-end

Follow `engine/DEPLOYMENT.md` exactly, on the machine that will become
the master. By the end of that procedure, the master should:

- Boot Ubuntu, auto-login the kiosk user
- Run the kiosk loop
- Have working Clean-2 and Dirty-2 VMs in `/home/kiosk/VirtualBox VMs/`
- Be authenticated to your Tailscale account
- Have run at least one full `host.sh` cycle successfully (verify with
  `osr-status` and check `~kiosk/osr-host.log` for "=== cycle complete
  ===")

Do not skip the soak test. Issues that surface only on a real cycle
(disk-swap timing, Boot.exe scheduled-task wiring, shared-folder mount
permissions) get baked into every cloned machine if the master has
them. Catch them now.

## Phase 2 — Sysprep the Clean VM

This step is what makes each cloned machine's Windows install
distinguishable on a network. Without it, every cloned machine has
the same Windows SID, hostname, and machine name — fine for kiosks
that never see each other, fragile for any environment with a domain
controller, file shares, or Windows-side licensing tied to identity.

**Inside the Clean-2 VM (open it in VirtualBox manager — kiosk loop
must be stopped):**

1. Boot Clean-2 normally. The OSR Boot scheduled task fires Boot.exe
   at logon; let it shut the VM down (~10 sec). Power Clean-2 back
   on — the snapshot rolls back any dir_desc.txt artifacts, so this
   second boot is identical to the post-first-snapshot state.

2. Once Clean-2 is logged in, open an admin PowerShell:
   ```powershell
   cd C:\Windows\System32\Sysprep
   .\sysprep.exe /generalize /shutdown /oobe /unattend:E:\unattend.xml
   ```
   (Adjust `E:\unattend.xml` to the path of your answer file — see
   the next section for what it should contain. Omit the `/unattend`
   flag if you want OOBE to run interactively on every cloned
   machine; that works but means an operator has to be present at
   each site to walk through Windows setup.)

3. Wait for the VM to power itself off. Sysprep removes the local
   user account, clears event logs, removes the Windows SID, and
   arms OOBE for next boot. Total time: a few minutes.

4. **Take a fresh snapshot** in VirtualBox: right-click Clean-2 →
   Snapshots → Take Snapshot, name it `pristine-sysprepped`. This
   is now your real rollback point for cloned machines.

### About `unattend.xml`

`unattend.xml` answers the OOBE questions Windows would otherwise
ask interactively on first boot of a sysprepped install. Microsoft's
canonical tool for generating one is **Windows System Image Manager
(SIM)**, part of the Windows ADK
(https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).

A minimal answer file for OSR's use case looks roughly like:

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" ...>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>staff</Name>
            <Group>Users</Group>
            <Password>
              <Value>...</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>staff</Username>
        <Enabled>true</Enabled>
        <Password>
          <Value>...</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <TimeZone>Eastern Standard Time</TimeZone>
    </component>
  </settings>
  ...
</unattend>
```

Generating one in SIM takes 30 minutes the first time, 5 minutes
thereafter. **Do not commit the unattend.xml to this repo** —
the Password fields contain plaintext credentials.

## Phase 3 — Generalize the host

With Sysprep done and the Clean VM snapshotted, the Linux host still
has its own per-machine identity (machine-id, SSH host keys, Tailscale
auth state, etc.). Strip those before imaging.

```bash
sudo /opt/osr/engine/generalize-host.sh
```

The script prompts for confirmation, then:

- Stops Tailscale and SSH
- Logs out of Tailscale
- Clears `/etc/machine-id`, SSH host keys, D-Bus machine-id
- Vacuums the systemd journal
- Truncates common log files (syslog, auth.log, dpkg.log, etc.)
- Clears `/tmp`, `/var/tmp`, all bash histories
- Clears DHCP leases
- Truncates `~kiosk/osr-host.log` and `osr-kiosk.log`
- Empties `~kiosk/osr-archive/` (the master's archive shouldn't
  propagate to cloned machines — those start with their own history)
- Drops a marker at `/etc/osr-image-pending-finalize`
- Enables `osr-finalize.service` to fire on first boot of a cloned
  machine
- Powers the system off

The marker file + service combo is what makes a cloned machine
self-finalize: on first boot, systemd sees the marker, fires
`finalize-machine.sh`, the script regenerates identity, the marker
goes away, the service self-disables.

After power-off, do not boot the master back up. The next boot
would self-finalize, and you'd have to re-generalize. Instead,
proceed to Phase 4.

## Phase 4 — Image the disk

Two reasonable tools:

### dd (technical, scriptable)

Boot the master from a Linux live USB stick (Ubuntu 24.04 desktop
ISO works fine — pick "Try Ubuntu" instead of installing). Identify
the master's primary disk:

```bash
sudo lsblk
```

Suppose it's `/dev/sda` and you have an external USB drive mounted
at `/mnt/external/`:

```bash
sudo dd if=/dev/sda of=/mnt/external/osr-master.img \
        bs=4M status=progress conv=fsync
```

For an 80 GB disk over USB 3, this is ~30-45 minutes. The image
file is the same size as the source disk; consider a 256 GB+
external drive.

### Clonezilla (operator-friendly UI)

Boot from a Clonezilla Live USB
(https://clonezilla.org/downloads.php). Walk through the menus:

1. start_clonezilla
2. device-image (save disk to a file)
3. local_dev → pick the destination external USB drive
4. savedisk
5. give the image a name (e.g. `osr-master-2026-05-03`)
6. select the master's primary disk as source
7. accept the defaults; let it run

Result: a folder on the external drive containing the image.

## Phase 5 — Restore to a target machine

For each new target:

1. Boot the target from the SAME live USB you imaged with (Ubuntu
   live for `dd`, Clonezilla Live for Clonezilla).
2. Plug in the external drive with the image.
3. Restore:

   **dd:**
   ```bash
   sudo dd if=/mnt/external/osr-master.img of=/dev/sda \
           bs=4M status=progress conv=fsync
   sudo sync
   ```

   **Clonezilla:** start_clonezilla → device-image → local_dev →
   restoredisk → pick the saved image → pick the target disk →
   confirm.

4. Remove the live USB, power off, power back on.

5. The target boots into Ubuntu. **Before the kiosk session starts**,
   `osr-finalize.service` fires `finalize-machine.sh`, which:
   - Sets a unique hostname (default: `osr-<MAC-suffix>`)
   - Regenerates `machine-id`, SSH host keys
   - Removes the marker file
   - Self-disables

6. The kiosk session starts. The Clean-2 VM, on its first boot,
   runs Windows OOBE (or the answer file from Phase 2 if you set
   one up). Either way, after Windows reaches the desktop and shuts
   itself down, the cycle continues.

7. **Authenticate Tailscale** as the admin user (Ctrl+Alt+F2 to
   switch to a TTY before the kiosk lockdown takes effect on the
   next reboot, OR from a recovery shell):
   ```bash
   sudo tailscale up --ssh
   ```

8. Reboot the target. It now behaves identically to the master,
   with its own unique identity.

## What the workflow does NOT handle

- **Windows licensing.** Each cloned machine still needs a valid
  Windows license. If your master used a retail key, that one key
  is now in N machines and Microsoft will eventually flag the
  duplicates. Use volume licensing if you have access, or buy
  per-machine retail/OEM keys and re-activate post-Sysprep on each
  target.
- **Hardware diversity.** If targets have different hardware than
  the master (different network chipset, different graphics, etc.),
  Windows OOBE will install drivers on first boot, which usually
  works but occasionally requires manual intervention. For a fleet
  of identical refurbished business desktops, this is rarely an
  issue.
- **Tailscale fleet membership.** Each cloned machine joins the
  tailnet as a separate node when the operator runs
  `tailscale up --ssh`. Pre-issued auth keys
  (https://tailscale.com/kb/1085/auth-keys) eliminate the per-machine
  browser flow if you want to fully automate Phase 5 step 7. For
  a small fleet, the interactive flow is fine.
- **First-boot OOBE without an unattend.xml.** If you skipped the
  unattend.xml step in Phase 2, every cloned machine's first Clean
  VM boot needs an operator present to click through Windows setup.
  This is the most common operator-time cost in cloned deploys;
  invest the unattend.xml hour up front if deploying more than ~5
  machines.

## Re-imaging the fleet (fleet update)

When the master needs to change — Windows updates, new customer
software, OSR engine updates — the cycle is:

1. Pick one machine, run `generalize-host.sh` to clear identity.
2. Boot it. (It'll self-finalize, but you can re-generalize after
   the changes you're about to make.)
3. Make the changes (apt update, Clean VM software install, OSR
   engine `git pull`, etc.).
4. Re-run setup-host.sh if needed (idempotent).
5. Sysprep the Clean VM again.
6. Generalize again.
7. Re-image to a new master image.
8. Restore to each fleet machine in turn.

Doing this remotely over Tailscale SSH is technically possible but
risky — a partial restore that doesn't complete leaves the target
unbootable. For now, fleet updates are an on-site operation. A
proper push-update mechanism (signed VHD pushes, staged rollout,
rollback support) is logged in `HANDOFF.md` as the next big
deployment-side project.
