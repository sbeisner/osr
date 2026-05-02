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

Status: **functional prototype**. Demonstrated end-to-end on the original
test bench. Two C++ projects (`pbosr/` shutdown-side and `Boot/` clean-boot
side) plus `host.sh` for the Linux orchestrator.

Known issues:

- **Hardcoded VM names** (`Dirty-2`, `Clean-2`) and paths in `host.sh`.
- **Hardcoded shared-folder path** (`\\VBoxSvr\dest`) in both .cpp files.
- **Hardcoded whitelist** in `pbosr/shutdown.cpp` `generate_whitelist()` —
  modifying the whitelist requires recompiling. The newer `ui/` codebase
  was meant to fix this.
- **Filename-only copy-back** in `Boot/boot.cpp` — directory structure under
  each whitelisted root is flattened on the way back. Acceptable for the
  named user folders (Desktop, Documents, etc.) but loses subfolder
  hierarchy inside them. Worth re-checking before relying on it.
- The `boot_rework` branch was merged into master via PR #3 in the original
  repo and is the version included here.
- `host.sh` deletes the dirty VHD with no rollback. If `clonemedium` fails
  partway the user loses everything. Add a rename-aside-then-delete-on-success
  pattern before production use.
- Builds against MSVC; the .sln only includes the `pbosr` project. `Boot`
  has its own `.vcxproj` but is not in the .sln — open it separately or add
  it to the solution.

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
- **Plaintext password storage** in `LocalUserStore`. Hash on create + on
  lookup before any real-user deployment. Marked `TODO(handoff)` in
  `LocalUserStore.QueryUsersAsync`.
- **The UI is not wired to `engine/`.** Today the WPF app and the C++
  shutdown/boot binaries are independent; the WPF "Run Update" button
  produces a local zip, while the engine's `\\VBoxSvr\dest` shared-folder
  workflow is its own thing. Decide what role the UI plays before
  wiring them together.
- **`Microsoft.WindowsAPICodePack`** dependency may be hard to restore
  from modern NuGet feeds; the official package was unlisted years ago.
  Community-maintained forks exist.
- **`RhinoCommon` is in `packages.config` and `osr_dotnet.csproj`.** It is
  not used by any code in the project — it appears to have been added by
  accident. It can be removed; left in to minimize churn during handoff.
- No tests, no input validation on the AccountCreate form beyond
  empty-field and password-match checks.
- `async void` in event handlers swallows exceptions silently (deliberate
  in the WPF event-handler model, but the chained helpers — `setUserDir`,
  `setWhitelist`, `finishUserInitialization` — could become `Task`-returning
  to give callers the option to await).

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

3. **Address the password-hashing issue** before any field deployment.
   `LocalUserStore.QueryUsersAsync` carries a `TODO(handoff)` to that
   effect.

4. **Replace hardcoded VM names and shared-folder paths** with
   config-driven values (the C++ side has hardcoded `\\VBoxSvr\dest`,
   `Dirty-2` and `Clean-2` throughout; pulling these into env vars or a
   small config file is a one-evening job and lets the engine ship to
   multiple customers).

5. **Tighten `host.sh`'s disk swap** to clone-then-rename rather than
   delete-then-clone (see `engine/DEPLOYMENT.md` known limitations).

6. **Prune unused dependencies.** `RhinoCommon` is referenced but not
   used; removing it would shrink the package restore noticeably.

7. **Resist the temptation to revisit WindowsPE-style imaging.** It will
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
