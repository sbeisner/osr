# Why we did not use WindowsPE

This document records, in detail, why an alternative architecture — booting
into Windows Preinstallation Environment (WinPE) on shutdown to image-replace
the Windows partition — was considered, prototyped, and rejected. Future
engineers picking up this project will find the WinPE idea intuitively
appealing and will want to revisit it. This document exists so they don't
have to re-learn the same lessons.

The TL;DR is at the bottom. Skip there if you already know what WinPE is.

## What WinPE is

Windows Preinstallation Environment (WinPE) is a stripped-down version of
Windows that Microsoft ships as part of the Windows Assessment and
Deployment Kit (ADK). Its intended purpose is to run during OS deployment
and recovery: boot from a USB stick or PXE network image, run a few
installer/imaging tools (DISM, ImageX, BCDedit, diskpart), then reboot
into the freshly-installed real Windows. It is essentially a thin Windows
that knows how to manipulate other Windows installations from the outside.

Because WinPE has full Windows-style access to NTFS, the registry, and the
component store, you *can* in principle:

- boot into it from a recovery partition;
- mount the system disk and the data disk;
- DISM-apply a clean WIM image over the system partition;
- leave the data partition (Documents, Pictures, Outlook profile, etc.)
  alone;
- reboot into the now-clean Windows, with user files preserved.

This sounds elegant — no Linux host, no VirtualBox layer, no two-VM swap
dance. One machine, one boot, one disk, runs at native speed, no
virtualization overhead. The customer support story is also tidier: when
something breaks, you're debugging Windows imaging tools, not a multi-layer
abstraction stack.

## Why it does not actually work

In contact with the real world the approach falls apart for eight
specific reasons, in roughly increasing order of how much they hurt.

### 1. Drivers

WinPE ships with a tiny built-in driver set. To run on production
hardware — modern NVMe SSDs, vendor-specific SATA controllers, particular
network cards if you want network access from PE, USB 3 controllers — you
have to inject drivers into the WinPE image (`Dism /Add-Driver`) for each
hardware platform you intend to deploy on.

For a single nursing home with one make and model of PC this is a small
cost. For the deployment story we'd actually want — selling this to many
small institutions, each with whatever hardware they happened to buy —
the driver tax compounds. Every new customer is a new image build.

### 2. Secure Boot, BitLocker, and modern Windows attestation

Modern Windows installations enforce a stack of integrity checks the
WinPE approach has to navigate around:

- **Secure Boot**: shipping a custom WinPE image requires either a
  Microsoft signature on every revision of your customizations (a real
  process, not a casual one) or disabling Secure Boot in firmware on
  every customer machine. Many compliance regimes (HIPAA-adjacent
  contexts, including healthcare-affiliated facilities like nursing
  homes) increasingly require Secure Boot remain on.
- **BitLocker**: if the customer's data partition is encrypted (and for
  any environment with PHI it should be), WinPE has to unlock it. That
  means either storing recovery keys on a network share PE can reach
  (which means PE needs network drivers and credentials, see #1) or
  baking keys into the image (a security disaster).
- **Memory Integrity / Virtualization-Based Security (VBS) / HVCI**:
  Windows 11 enables these by default. WinPE itself doesn't run any
  of them; rebooting into PE briefly drops the host out of the
  protected state. For a one-time recovery use this is fine. For a
  shutdown-time hook that runs every day, you're taking the security
  posture down twice per shift.
- **Trusted Platform Module (TPM)** binding: Windows 11 binds activation
  and BitLocker to the TPM. PE's manipulations of system files don't
  break TPM binding directly, but file timestamp resets and registry
  rewrites can confuse the activation grace logic enough to surface
  "your Windows is not activated" pop-ups for users.

### 3. Windows resource protection (WRP / Trusted Installer)

System files in `C:\Windows\System32` and `C:\Windows\WinSxS` are
protected by ACLs that grant write access only to `NT SERVICE\TrustedInstaller`.
You can override this from PE — you have full disk access there — but
on the next boot, Windows runs background scans (System File Checker
on a schedule, Windows Update reliability checks, Component Store
servicing) that **detect tampering and try to undo it**. They re-pull the
"correct" file from the component store, or trigger a Windows Update repair,
or surface a corruption error to the user.

The naive "image-replace the system partition" approach loses this race.
The system briefly looks clean, then Windows quietly reverts your
work over the next several hours of background activity.

### 4. Component Based Servicing (CBS) and the WinSxS store

The deepest and worst version of #3. Windows updates are not file replacements
— they are CBS transactions against the component store at `C:\Windows\WinSxS\`.
Every system file is hard-linked from the component store; the hash of every
file is recorded in component manifests. A clean install plus 18 months of
Patch Tuesdays is **not** the same set of bytes as a clean install: it is
the original bytes plus a delta of components, manifests, and supersedence
chains.

What this means for image-replace approaches:

- You cannot copy a "clean" set of system files over a "dirty" set without
  also overwriting the component store, the manifests, and the
  pending-transactions log in a coherent way. If you copy only files,
  CBS sees corrupt manifests and refuses to install future updates.
- You cannot save a single "clean image" and reuse it forever, because
  Windows Update will mismatch — you've held the system at one patch
  level but the customer's certificates, AV definitions, edge updates,
  and Defender signatures all keep moving forward, and the manifests
  in your image don't know about them.
- You can in theory rebuild your golden image after every Patch Tuesday,
  but now you're doing release engineering on a monthly cadence to
  follow Microsoft's patches.

This last point is the load-bearing problem. See section 6.

### 5. Failure recovery is brutal

If image-replace fails partway — disk error, driver fault during write,
power loss — the user's machine is unbootable. There is no Linux host to
log into and inspect. The first signal the customer's IT support gets is
"the computer is dead." Recovery requires a USB recovery stick, physical
access, and probably a Microsoft account to reauthenticate.

For a nursing home running 20 machines, with the engine running once per
shift per machine, you have on the order of 7000 cycles per year. Even a
0.1 % failure rate means seven dead-machine site visits per year. The
VirtualBox approach fails on the host (which is bootable Linux, you can
SSH in), and the worst case is "swap in a copy of Clean-2.vhd", which is
a one-line shell command runnable remotely.

### 6. Microsoft moves the goalposts on a monthly cadence

This is the killer.

Each second-Tuesday-of-the-month security patch can move things you'd
prefer didn't move. Each annual feature update (e.g., Windows 11 23H2
to 24H2) is a near-major-version event. Specific things that have actually
changed across recent Windows revisions and that an image-replace approach
has to track:

- **File paths**: Microsoft Edge moved from `C:\Program Files (x86)\Microsoft\Edge`
  to `C:\Program Files\Microsoft\Edge` in 2021. The Outlook *profile*
  path moved when Microsoft introduced "New Outlook" alongside classic
  Outlook in 2024 — both versions can be installed simultaneously and
  store profile state in different locations. Your "preserve Outlook
  profile" whitelist now has to know which Outlook is in use.
- **Registry keys for user data**: location of the Chrome user data
  directory, Edge user data, Office signatures cache, Windows Defender
  exclusion lists — all move occasionally enough that any "preserve
  these registry trees" list rots quickly.
- **Component store layout**: WinSxS reorganizations happen at major
  feature updates. Hard-link counts change. Reparse points get added
  and removed. Anything operating below the OS's APIs has to re-validate
  its assumptions every release.
- **WinPE itself ships with each ADK release**: WinPE for 22H2 is a
  different image from WinPE for 24H2. Microsoft's intention was that
  you'd use the matching WinPE version against the corresponding live
  Windows; using a mismatched pair triggers warnings or outright
  refuses to mount the component store.
- **Driver model changes**: WDDM major version bumps in graphics
  stacks, NVMe driver model adjustments, USB-IF stack revisions —
  each requires re-injecting drivers into your WinPE image to maintain
  hardware coverage.
- **Boot path changes**: BCD store layout has changed, the boot
  manager has gained Secure Boot variables, and Windows 11 added
  TPM-bound boot policies. Anything that wants to add itself to the
  boot menu (which a self-deployed WinPE has to) has to match the
  current state.

The honest accounting is: **maintaining a WinPE-based image-replace
appliance against a live Windows install requires a dedicated team that
follows Patch Tuesday and feature update releases, retests against the
matrix of customer hardware, and re-ships images monthly.** That is
roughly the team profile of Microsoft's own SCCM, Intune, and MDT
engineering groups, which exist for a reason — productizing this kind
of OS-image management is a many-person, full-time endeavor.

For this project, with one developer and a part-time stakeholder, that's
not a viable resource profile. Even with a small dedicated team, it would
spend most of its calendar following Microsoft rather than building
features.

### 7. License model friction

Image-replace from WinPE assumes you can store a "clean" Windows install
to copy from. Microsoft's volume licensing terms allow this for
enterprise customers via specific image-deployment licenses (KMS, MAK,
Subscription Activation). For small-customer one-off deployments under
retail or OEM licenses, the lawful position is murkier — you're not
deploying via Microsoft's blessed tools, and the activation grace logic
treats your image-replace as a hardware change.

The VirtualBox approach sidesteps this entirely. Each VM has its own
licensed Windows install; cloning the VHD is a within-customer operation
explicitly permitted by the EULA.

### 8. Patching the clean image is its own problem

Even if every other concern were free, you would need to apply Windows
Updates to the clean image, otherwise customers run on perpetually
outdated Windows. To apply updates you have to: boot the clean image
in a non-imaging mode, let Windows Update run, install the updates,
reboot, verify, snapshot. With a WinPE-on-disk approach, the clean
image lives on a partition of the customer's machine — you'd have to
either visit the machine to update it, or build out-of-band update
infrastructure (which means another component to maintain).

The VirtualBox approach makes this trivial: the clean image is a VM,
you can update it from any host, you can ship updated VHDs to customers
over the network as a normal file transfer, and rolling back a bad
update is `git revert`-easy via VirtualBox snapshots.

## Why VirtualBox is the right abstraction

The VirtualBox swap approach wins not because it's clever but because
it's stable. The Linux host is rock-solid (Debian/Ubuntu LTS, the same
shell tools and `VBoxManage` interface for the next decade). VirtualBox
is mature and changes slowly. **Microsoft cannot break our deployment
by patching Windows**, because the host knows nothing about Windows
internals — it manages a `.vhd` file as opaque bytes.

The seven failure modes above either become trivial or evaporate:

- **Drivers**: Linux runs Linux drivers. Inside the VM, Windows runs
  the drivers Windows already shipped with for "VirtualBox virtual
  hardware" — a tiny, stable, well-tested set.
- **Secure Boot / BitLocker / VBS**: orthogonal. The VM either has them
  or doesn't; the host doesn't care either way.
- **Trusted Installer / WRP / CBS**: never relevant. We don't poke at
  Windows internals; we replace a whole disk image.
- **Failure recovery**: the host is alive and reachable. `cp Clean-2.vhd
  Dirty-2.vhd` from a remote shell is the worst case.
- **Microsoft moving goalposts**: Windows can change anything inside
  the VM. The host doesn't notice. Updates to the clean VM are normal
  Windows Updates run inside the VM by an ordinary admin.
- **License model**: per-VM Windows licenses, conventionally cloned for
  the customer's own use, on the customer's own hardware — clearly within
  the EULA.
- **Patching the clean image**: a VM, updatable from any host with
  network access, snapshottable for rollback.

The cost is the virtualization layer: ~5–10 % CPU overhead, slightly
higher RAM usage, slightly slower disk I/O, and the visible "starting
the VM" handful of seconds at boot. For a nursing-home receptionist
desktop running Outlook, QuickBooks, and a browser, none of these
matter. For a CAD workstation or a video-editing rig they would.

## TL;DR

The WinPE / image-replace approach was rejected because:

1. It requires you to run inside an environment Microsoft is constantly
   reshaping — every Patch Tuesday and every annual feature update can
   break your assumptions about file paths, component-store layout,
   security-boot requirements, or driver coverage.
2. Keeping up with that churn requires a dedicated, ongoing team. That
   is the working profile of Microsoft's own SCCM / Intune / MDT
   engineering groups; it is not a feasible cost for a small product
   serving small customers.
3. Failure modes are catastrophic (unbootable machine requiring a site
   visit), where VirtualBox failures are mild (the host is alive,
   recovery is one shell command).
4. License and compliance posture (Secure Boot, BitLocker, activation)
   gets harder, not easier, with each Windows release.

The VirtualBox swap approach was chosen because **the host knows nothing
about Windows internals**. As long as VirtualBox can store a `.vhd` and
clone it, the system works — regardless of what Microsoft does inside
that VHD. That insulation is the entire point of the architecture.

## Footnote: Faronics Deep Freeze and Windows UWF

If you ever revisit the WinPE direction, also revisit the question of
whether to build the imaging machinery at all. Two off-the-shelf products
already solve most of this problem and have the dedicated team you would
otherwise have to assemble:

- **Faronics Deep Freeze**: drops in on the live Windows install, no
  WinPE, no Linux host. Reverts the system on every reboot, "ThawSpaces"
  hold whatever you want preserved. A team of engineers at Faronics
  follows every Windows revision so you don't have to.
- **Windows Unified Write Filter (UWF)**: built into Windows 10/11
  Enterprise IoT. Microsoft-supported by definition. Same revert-on-
  reboot model with a registry/file whitelist.

If the customer's per-seat budget can absorb either ($30–50/seat/year
for Deep Freeze; the cost difference between Pro and Enterprise IoT
licensing for UWF), the strongest move is to drop the in-house
maintenance burden entirely. The WinPE rejection above applies just
as forcefully to "should we keep building OSR at all" — the answer
depends on whether the customer's price ceiling rules out those
existing tools.
