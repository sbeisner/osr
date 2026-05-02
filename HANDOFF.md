# Handoff Notes

This document is for the next person to pick up the project. It is an honest
accounting of the state of each component, the known issues, and the
suggested order of work — not a sales pitch.

## Bottom line

The `engine/` directory contains a working prototype of the core concept.
The `ui/` directory contains the start of a productized WPF app on top of
that concept; it builds and runs out of the box (no cloud dependency) but
the ISO builder and the post-setup configuration screen are unfinished.

If you want to revive this project, the highest-value path is probably:
1. Decide whether to keep the VirtualBox-based `engine/` approach at all,
   or replace it with one of the off-the-shelf tools listed at the bottom.
2. Either way, decide what role (if any) the `ui/` codebase plays — and
   how (if at all) you want to wire it to the engine.
3. Address the security and design issues called out below before any
   real-user deployment.

## Origins / what was removed

`ui/osr_dotnet/Controllers/CosmosController.cs` originally hosted user data
in Azure Cosmos DB, with a hardcoded endpoint and primary key for an
`osr-dev` instance. That whole controller has been replaced with
`LocalUserStore.cs`, which persists users as JSON at
`%LOCALAPPDATA%\osr\users.json`. The public surface of the class
(`startAsync`, `AddUsersToContainerAsync`, `UpdateUser`, `QueryUsersAsync`)
is the same shape, so swapping in a real backend later is a focused change.

The original Cosmos DB account on Azure is still alive — neither original
owner has access credentials anymore — but the leaked key is no longer
referenced from this codebase or its history. If you want a real backend
later, the cleanest pattern is to extract `LocalUserStore`'s public surface
into an `IUserStore` interface and provide a second implementation; nothing
else in the UI binds to the storage type.

## Component-by-component state

### `engine/` — VirtualBox swap implementation

Status: **functional prototype with kiosk-grade plumbing**. The orchestrator
loop, error reporting, and Linux-host setup are fleshed out enough to run
unattended in the field for a soak test, but a few items in
"Before deploying to real users" below need to land before paying customers.

Recent hardening:

- `host.sh` is now config-driven (env vars at the top of the file) with
  structured logging, wait-loop timeouts, clone-then-rename disk swap,
  shared-folder snapshot history (rolling N=7 cycles), and Shutdown.exe
  completion-sentinel checking.
- `shutdown.cpp` and `boot.cpp` log per-entry success/failure to the
  shared folder (`shutdown.log`, `boot.log`), surface SHFileOperation
  return codes and aborted-state, and write completion sentinels that
  the host can verify.
- `boot.cpp` writes `osr-canary.txt` files into each whitelisted
  directory after restore; `shutdown.cpp` verifies them and writes
  `canary-failure.flag` if any are tampered (host.sh treats this as a
  SUSPICIOUS signal alongside its own extension scanner).
- Note: all `shutdown.cpp` and `boot.cpp` source changes have been
  edited but **not recompiled** — this needs to happen on a Windows
  box with VS before redeploy. If the colleague's developer hasn't
  rebuilt the binaries, the deployed `.exe` files are still the old
  versions and the host-side improvements alone won't help.
- `shutdown.cpp` was carrying a count-vs-dir_desc alignment bug (count
  was incremented even on copy failure, leaving gaps that boot.cpp
  couldn't detect); fixed.
- `setup-host.sh` now locks down VT switching, Ctrl+Alt+Backspace,
  Magic SysRq, and the VirtualBox host-key combo so an end-user can't
  accidentally escape the fullscreen VM.

Remaining engine-level known issues:

- **Hardcoded shared-folder path** (`\\VBoxSvr\dest`) in both .cpp files.
- **Hardcoded whitelist** in `pbosr/shutdown.cpp` `generate_whitelist()` —
  modifying the whitelist requires recompiling. The newer `ui/` codebase
  was meant to fix this.
- **`MAX_PATH` truncation**: paths longer than 260 characters silently
  truncate inside `SHFileOperation`. `shutdown.cpp` now logs a warning
  when it sees one but doesn't fix the underlying behavior. Long-path
  support requires switching to the `\\?\` prefix and the `*W` API
  variants throughout.
- **Locked files (Outlook .pst/.ost, etc.)**: SHFileOperation skips
  files that are open with a deny-share-write lock. The new logging
  surfaces the failure but doesn't fix the cause. A real fix needs
  Volume Shadow Copy Service (VSS) integration — meaningful engineering.
- **Builds against MSVC**: the .sln only includes the `pbosr` project.
  `Boot` has its own `.vcxproj` but is not in the .sln — open it
  separately or add it to the solution.

PREVIOUSLY claimed and now retracted: "Boot/boot.cpp flattens directory
structure under each whitelisted root". On a closer read this was wrong.
`SHFileOperation` with `FO_COPY` recurses, and `boot.cpp` invokes it on
each top-level entry of the transit dir, so subdirectory structure is
preserved. Mentioning here so a future reader who sees the old claim in
git history doesn't go chasing a phantom bug.

### `ui/osr_dotnet/` — WPF configurator

Status: **builds, runs, partial functionality**. No external service
dependencies.

What works:

- Project compiles under Visual Studio 2019+ targeting .NET Framework 4.7.2,
  after a NuGet restore.
- Page navigation: `Login` → (returning user) `Configure`,
  (new user) `AccountCreate` → `SelectUser` → `FirstTimeSetup` → `Configure`.
- `LocalUserStore` persists users to `%LOCALAPPDATA%\osr\users.json`
  (atomic write via temp-then-rename).
- Login fails closed with a `MessageBox` if no matching user is found
  (the original code dereferenced a null user, NRE-ing on first attempt).
- `User.Id` is a fresh `Guid.NewGuid()` per account (was `Random.Next()`).
- `FileSystemController.createZipArchive()` reads `User.Whitelist`,
  splits on newlines, and recursively archives each entry to
  `%LOCALAPPDATA%\osr\snapshot-<userId>.zip`. Preserves directory
  structure within each whitelist root via `<rootName>\<remainder>`
  entry names; permission-denied files are logged and skipped. Returns
  `Task` so callers can `await` it (was `async void`).
- `Configure.xaml`'s two buttons are wired: **Update Whitelist**
  navigates back to `FirstTimeSetup`; **Run Update** awaits a fresh
  snapshot and reports completion via `MessageBox`.
- `SelectUser.xaml.cs` enumerates Windows local accounts via WMI
  (`Win32_UserAccount`).

What is broken or missing:

- **`DiscUtilsController` is a stub.** The `DiscUtils` NuGet dependency
  was pulled in for building clean ISO images — the eventual idea being
  that OSR could deploy on bare metal without VirtualBox. Only the
  `CDBuilder` constructor is wired; no file enumeration, no ISO write.
  *Read `docs/why-not-winpe.md` before pursuing this — the same
  Microsoft-patch-cadence problems that killed the WindowsPE-imaging
  approach apply here, and DiscUtils-built ISOs hit them too.*
- **Password hashing now uses bcrypt** (`BCrypt.Net-Next` 4.0.3, default
  work factor 11). `AccountCreate` hashes on create; `LocalUserStore.QueryUsersAsync`
  verifies on lookup, with a one-shot auto-migration path for any plaintext
  entries left over in `users.json` from before this change. The
  migration: when a stored password doesn't begin with `$2`, fall back to
  plaintext compare, and on a successful match re-hash and persist before
  returning the user. Subsequent logins for that user use bcrypt verify.
  Drop the `users.json` file to start clean if you'd rather skip the
  migration path.
- **The UI is not wired to `engine/`.** Today the WPF app and the C++
  shutdown/boot binaries are independent; the WPF "Run Update" button
  produces a local zip, while the engine's `\\VBoxSvr\dest` shared-folder
  workflow is its own thing. Decide what role the UI plays before
  wiring them together.
- **`Microsoft.WindowsAPICodePack`** dependency may be hard to restore
  from modern NuGet feeds; the official package was unlisted years ago.
  Community-maintained forks exist.
- (Removed: `RhinoCommon` and `Eto` were dragged into `packages.config`
  and the .csproj years ago, never used by any code, and broke the build
  for anyone who couldn't restore the package. Cleaned out.)
- No tests, no input validation on the AccountCreate form beyond
  empty-field and password-match checks.
- `async void` in event handlers swallows exceptions silently (deliberate
  in the WPF event-handler model, but the chained helpers — `setUserDir`,
  `setWhitelist`, `finishUserInitialization` — could become `Task`-returning
  to give callers the option to await).

## Before deploying to real users

Engine plumbing is now solid enough to run unattended for soak testing.
What remains, ordered by how badly it would hurt a real customer, is a
mix of design-level issues and deployment-at-scale issues. Treat these
as gating items for paid customers, not for a friendly soak deployment.

### Design-level

1. **Ransomware persistence by design.** The architecture preserves
   user files across the OS reset; if a user's files get encrypted in
   one shift, the next shift dutifully restores the encrypted versions.
   The `host.sh` snapshot history (`~/osr-archive/<timestamp>/`, 7
   shifts by default) gives an admin a manual rollback path, but does
   not prevent the encryption from happening or from re-propagating
   on the next cycle. Real fixes:
   - Run an AV scan inside the Dirty VM as part of the shutdown
     procedure, refuse to commit files to the shared folder if a
     scanner flags them. Defender + a scheduled task that completes
     before `Shutdown.exe` runs is a starting point.
   - Or, accept that the snapshot history is the recovery story, and
     give an admin a one-button "roll a user back to N shifts ago"
     workflow.

2. **No AV inside the Clean VM.** Even if Dirty-side AV catches stuff,
   the Clean image is pulled forward forever and any malware that
   landed in it once is permanent. Microsoft Defender by default plus
   a scheduled clean-image update workflow is the minimum.

3. **Customer data sits unencrypted on the Linux host filesystem**
   (`~kiosk/dest/` and `~/osr-archive/`). For HIPAA-adjacent contexts
   (nursing homes, healthcare clinics) this fails the obvious
   compliance asks. Mitigations:
   - LUKS full-disk encryption on the host install (the Ubuntu
     installer offers this; not currently called out as required in
     `engine/DEPLOYMENT.md`).
   - Encrypt `~/osr-archive` with `gocryptfs` or `eCryptfs`.

4. **Shared folder is bidirectional with full write access** between
   the Dirty VM and the host. A compromised VM can stomp the host's
   home directory or attempt VirtualBox-driver privilege escalation.
   Mitigations: mount read-only on the host side except during the
   brief copy-back window; or use a different transport (e.g., a
   guest-side SMB share to a dedicated host volume).

5. **Remote-support path: partial.** `setup-host.sh` now installs
   Tailscale and prompts the deployer to run `sudo tailscale up --ssh`
   as a post-install step. The admin can `tailscale ssh
   admin@<machine>` from anywhere afterward. Still missing: a daily
   log roll-up (so a customer's "it's broken" call finds existing
   diagnostics rather than requiring a live shell session), and a
   policy decision about who in the Tailscale tailnet has SSH access
   to which kiosks.

6. **Locked files (Outlook .pst, OneNote, etc.) skip silently.**
   `shutdown.cpp` now logs the failure. To actually copy them needs
   Volume Shadow Copy Service integration (`vssadmin create shadow`,
   then copy from the shadow). Real engineering work.

### Deployment-at-scale

For a single-installer-on-many-machines scenario (one library,
one nursing home), the current setup process is approximately
2–3 hours per machine, on-site. This does not scale: a 20-machine
deployment is a person-week.

7. **Build a master-image clone workflow.** The realistic answer is:
   set up one machine end-to-end, image its drive (Clonezilla or
   `dd`), restore the image to each additional machine's drive,
   then run a per-machine `finalize-machine.sh` first-boot script
   that:
   - regenerates SSH host keys
   - regenerates `/etc/machine-id`
   - sets a unique hostname (e.g. derived from MAC)
   - re-runs `sysprep /generalize` inside the Clean VM and triggers
     a fresh Windows OOBE / activation pass
   - prompts the installer for Wi-Fi credentials and customer-specific
     config (printer drivers, etc.)

   None of this exists today. It is roughly 1–2 weeks of focused
   work; it transforms 20-machine deploys from a person-week to a
   person-day.

8. **License model.** OEM Windows licenses are tied to the original
   hardware; cloning a Sysprepped image to fresh hardware needs
   either volume licensing (not generally available to small
   customers) or a fresh retail/OEM license per Clean VM. At
   ~$200/seat × N seats × M customers, this is real procurement
   friction. Pick a position before the first customer.

9. **Fleet-update story.** The Clean VHD ages; Windows Updates accumulate;
   the clean image needs to be replaced periodically across the deployed
   fleet. Right now: a person visits each site. A realistic answer:
   the host pulls a signed VHD from a central server during off-hours,
   verifies the signature, and queues it for the next swap. Engineering
   work, not yet started.

10. **Diagnostics over the phone.** When a non-technical customer calls
    saying "it's broken," there is currently no way to send logs back.
    `host.sh` writes to `~/osr-host.log`; `shutdown.cpp` and `boot.cpp`
    write to `\\VBoxSvr\dest\*.log`; nothing aggregates these or
    surfaces them remotely. Pair with #5 (Tailscale) and a daily
    `journalctl --until=24h ago | curl …` upload to a central
    collector.

### Files NOT included from the original prototypes

- `proactive_backup/ssh_handler.cpp` had a hardcoded SSH password. The
  whole libssh-based transport was superseded by `\\VBoxSvr` shared folders
  and is not preserved here.
- `osr_dotnet`'s `bin/`, `obj/`, `packages/` directories (133 MB of build
  artifacts and NuGet binaries) are excluded by `.gitignore`. NuGet restore
  rebuilds `packages/`; Visual Studio rebuilds `bin/`+`obj/`.
- An identical second copy of every UI source file existed at the root of
  the original `osr_dotnet` repo alongside the canonical
  `osr_dotnet/osr_dotnet/` subdirectory. Only the canonical copy is here.

## Suggested next steps, in priority order

1. **Decide whether to build or buy.** The original product target — clean a
   public-access Windows machine on every shutdown — is solved off-the-shelf
   by:
   - **Faronics Deep Freeze** (cheap per-seat license, the de-facto industry
     standard for libraries / kiosks / public terminals).
   - **Windows Unified Write Filter (UWF)**, built into Win 10/11
     Enterprise and IoT — redirects all writes to a discardable overlay,
     with a whitelist for files/registry to persist.
   - **Folder redirection + FSLogix profile containers** to a small NAS,
     making the system disk genuinely disposable.
   The strongest case for continuing this project is if there is a feature
   or price point those tools don't hit. Read `docs/why-not-winpe.md` —
   most of its argument applies just as forcefully to the question of
   whether to keep building OSR at all.

2. **Wire the UI to the engine.** The two halves currently know nothing
   about each other. The most natural integration: the WPF
   `Configure.xaml` "Run Update" button shells out to the `engine/pbosr`
   shutdown binary with a path to the user's whitelist file.
   `FirstTimeSetup` already produces something close to that whitelist
   shape; it just doesn't write it where the engine looks.

3. **Replace remaining hardcoded paths in the C++ side** —
   `\\VBoxSvr\dest`, the whitelist contents in `generate_whitelist()`,
   the per-customer shutdown command. Pull into a config file or
   command-line args before shipping to a second customer. (`host.sh`
   on the Linux side is already env-driven; the C++ binaries are not.)

4. **Resist the temptation to revisit WindowsPE-style imaging.** It will
   feel like the obvious next architectural improvement — bare metal,
   no VirtualBox layer, native performance. `docs/why-not-winpe.md`
   walks through why it was prototyped and rejected, with specific
   attention to the maintenance burden of tracking Microsoft's monthly
   patch cadence and feature updates.

## Original product context

Target customer: nursing homes and similar small-budget institutions where
the same machines get used by the same small group of staff every day, are
prone to malware infection (often via email or USB), and where the cost of
in-person IT remediation is disproportionate to the value of the machines.

The selling proposition was: "press the power button at the end of your
shift, walk away, come back tomorrow to a known-good machine with all your
files where you left them." The QuickBooks-shared-folder, Outlook
signatures, and Office UProof entries in the whitelist reflect the actual
software stack of that user base.
