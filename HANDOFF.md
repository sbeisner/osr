# Handoff Notes

This document is for the next person to pick up the project. It is an honest
accounting of the state of each component, the known issues, and the
suggested order of work — not a sales pitch.

## Bottom line

- `engine/` — working prototype of the core concept.
- `host-ui/` — Flask admin UI on the Linux host (status, whitelist editor,
  log viewer), reachable via the host's Tailscale tailnet. Replaces the
  in-VM WPF approach. Phase-1 scaffold is done; remaining wire-up is
  documented in tasks below.
- `ui/` — original WPF productization. Preserved as a reference for the
  user-facing surface (login flow, whitelist editor, snapshot trigger)
  while `host-ui/` is being built out. Will be deleted once `host-ui/`
  has run a real cycle end-to-end on a deployed host.

If you want to advance this project, the highest-value path is:
1. Land the remaining `host-ui/` wire-up: modify `pbosr/shutdown.cpp`
   to read the host-staged whitelist from `\\VBoxSvr\dest\whitelist.txt`
   in preference to its hardcoded `generate_whitelist()`; wire
   `setup-host.sh` to install the venv + systemd unit + `~/osr-config`
   directory; `tailscale serve` the UI onto the tailnet.
2. Address the security and design issues called out below before any
   real-user deployment (the items under "Before deploying to real
   users").
3. Build a fleet-update mechanism (push Clean VHDs to deployed
   machines remotely, with staged rollout and rollback) so updates
   don't require on-site visits.

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

### `host-ui/` — Linux-host admin UI (Flask)

Status: **scaffold done, file contract established with engine, not yet
deployed end-to-end**. Replaces the in-VM WPF configurator (see below).
See `docs/host-ui-plan.md` for design rationale and `host-ui/README.md`
for layout and deploy steps.

What works:

- Flask app under gunicorn-via-systemd. Auth via Tailscale identity
  headers (`Tailscale-User-Login` etc.). Refuses any request missing
  the headers — the only ingress path is `tailscale serve` →
  `127.0.0.1:8080`.
- Status page reads `~/osr-host.log` for cycle markers + recent
  ransomware indicators, and `~/osr-archive/` for retained-session
  count + SUSPICIOUS-marked sessions. Detects an in-flight cycle
  (cycle-start without a matching cycle-complete in the tail).
- Whitelist editor reads/writes `~/osr-config/whitelist.txt` with
  validation (rejects `..` traversal and non-Windows-path entries;
  warns on non-`C:\` drives). Atomic write via temp + `os.replace`.
- Log viewer tails `~/osr-host.log` (configurable line count via `?n=`),
  color-codes RANSOMWARE_INDICATOR / WARN / ERROR / FATAL.
- `engine/host.sh` reads `WHITELIST_FILE` (default
  `~/osr-config/whitelist.txt`) and stages it into
  `$DEST_DIR/whitelist.txt` at the start of each cycle.
  `engine/test-cycle.sh` still passes.

What is broken or missing:

- **`shutdown.cpp` does not yet read the staged whitelist.** The C++
  binary still calls `generate_whitelist()` to build a hardcoded list.
  Until `shutdown.cpp` is changed to read `\\VBoxSvr\dest\whitelist.txt`
  in preference, the file the UI writes is staged but ignored. Tracked
  as a separate task — needs a Windows VS box to recompile.
- **`setup-host.sh` does not yet install the venv or the systemd unit.**
  Today, deployers must follow the manual steps in `host-ui/README.md`.
- **No production HTTPS yet.** Plan is `tailscale serve --https=443
  http://127.0.0.1:8080`. Not wired into setup-host.sh.

### `ui/osr_dotnet/` — WPF configurator (legacy, slated for removal)

Status: **builds, runs, partial functionality, replaced by `host-ui/`
in plan**. No external service dependencies. Preserved as a reference
for the user-facing surface (login → SelectUser → FirstTimeSetup →
Configure) until `host-ui/` is proven end-to-end on a deployed host;
will be deleted in a follow-up commit at that point.

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

- (Removed: `DiscUtilsController` was a stub for building clean ISO
  images so OSR could eventually deploy on bare metal without VirtualBox.
  Deleted because the same Microsoft patch-cadence problems that killed
  the WindowsPE-imaging direction — see `docs/why-not-winpe.md` —
  apply equally to DiscUtils-built ISOs. The `Discutils` NuGet package
  and the controller file have been removed; `DotNetZip` stays in the
  package set since `FileSystemController` uses `System.IO.Compression`.)
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
- **`Microsoft.WindowsAPICodePack`**: the original Microsoft package was
  unlisted from NuGet years ago, so `packages.config` references the
  community-maintained `Microsoft.WindowsAPICodePack-Core` and
  `-Shell` forks (still on NuGet, drop-in compatible — the assembly
  names `Microsoft.WindowsAPICodePack` and `.Shell` are unchanged, so
  the .csproj `Reference` entries didn't need to change). The only
  consumer is the folder-picker dialog in `FirstTimeSetup.xaml.cs`.
- (Removed: `RhinoCommon` and `Eto` were dragged into `packages.config`
  and the .csproj years ago, never used by any code, and broke the build
  for anyone who couldn't restore the package. Cleaned out.)
- No tests, no input validation on the AccountCreate form beyond
  empty-field and password-match checks.
- Top-level WPF event handlers remain `async void` (the WPF event-handler
  model requires this — converting them swallows the binding). The
  chained helpers `setUserDir`, `setWhitelist`, and `finishUserInitialization`
  on `MainWindow` are now `async Task` so their callers can await them
  rather than fire-and-forget; `Save_Whitelist` and `Button_Click`
  awaits each call in turn so the navigation does not race the user-store
  write.

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

5. **Remote-support path: in place.** `setup-host.sh` installs Tailscale
   (deployer runs `sudo tailscale up --ssh` once) and an `osr-status`
   command that prints a one-page health summary on demand. Admin
   workflow on a "the computer's broken" call: `tailscale ssh
   admin@<machine>` then `osr-status`. Still nice to have eventually:
   a daily log roll-up to a central collector so an admin can see the
   fleet without polling each host, and a policy decision about who
   in the Tailscale tailnet has SSH access to which kiosks.

6. **Locked files (Outlook .pst, OneNote, etc.) skip silently.**
   `shutdown.cpp` now logs the failure. To actually copy them needs
   Volume Shadow Copy Service integration (`vssadmin create shadow`,
   then copy from the shadow). Real engineering work.

### Deployment-at-scale

7. **Master-image clone workflow: in place.** `engine/generalize-host.sh`
   strips per-machine identity (machine-id, SSH host keys, Tailscale
   auth, logs, archive history) from a configured master so its disk
   can be imaged. `engine/finalize-machine.sh` regenerates identity
   on first boot of a cloned machine, gated by a marker file and a
   systemd oneshot service (`osr-finalize.service`). The full
   procedure — including Sysprep'ing the Clean VM and supplying an
   `unattend.xml` so cloned Windows installs run OOBE non-interactively
   — is documented in `docs/master-image-workflow.md`. Brings the
   per-additional-machine cost from ~3 hours to ~30 minutes
   (mostly waiting on disk imaging).

   Open follow-on work that would simplify this further: a curated
   `unattend.xml` template in the repo (currently the deployer
   generates one with Microsoft's SIM tool); a Tailscale auth-key
   integration so cloned machines auto-join the tailnet without an
   operator-typed browser flow.

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

1. **Wire `shutdown.cpp` to read the staged whitelist.** Modify
   `pbosr/shutdown.cpp::generate_whitelist()` to first try opening
   `\\VBoxSvr\dest\whitelist.txt`; if present, copy its contents into
   the working-dir `whitelist.txt` and return. Fall back to the existing
   hardcoded enumeration only if the staged file is absent or empty.
   Recompile in VS, redeploy. This is the last piece needed to make the
   `host-ui/` whitelist editor actually drive the cycle.

2. **Integrate `host-ui/` install into `setup-host.sh`.** Today
   `setup-host.sh` does not install the venv, the systemd unit, or
   create `~/osr-config`. Until it does, `host-ui/README.md` documents
   the manual steps. Pair this with a `tailscale serve` line so the UI
   is reachable on the tailnet on first boot.

3. **Replace remaining hardcoded paths in the C++ side** —
   `\\VBoxSvr\dest`, the per-customer shutdown command. Pull into a
   config file or command-line args before shipping to a second
   customer. (`host.sh` on the Linux side is already env-driven; the
   C++ binaries are not.)

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
