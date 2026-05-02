# Handoff Notes

This document is for the next person to pick up the project. It is an honest
accounting of the state of each component, the known issues, and the
suggested order of work — not a sales pitch.

## Bottom line

The `engine/` directory contains a working prototype of the core concept.
The `ui/` directory contains the start of a productized WPF app on top of
that concept; it builds but is not feature-complete and depends on an Azure
Cosmos DB account that is no longer accessible (see "Cosmos DB situation"
below).

If you want to revive this project, the highest-value path is probably:
1. Decide whether to keep the VirtualBox-based `engine/` approach at all,
   or replace it with one of the off-the-shelf tools listed at the bottom.
2. Either way, decide what role (if any) the `ui/` codebase plays.
3. Address the security and design issues called out below before any
   real-user deployment.

## Cosmos DB situation

`ui/osr_dotnet/Controllers/CosmosController.cs` originally contained a
hardcoded Azure Cosmos DB endpoint and primary key for an `osr-dev` instance.
Those literals have been removed and replaced with a read from
`App.config <appSettings>`; the placeholders intentionally cause the app to
refuse to start until populated.

**The original Cosmos DB account is still alive on Azure** but the original
owner no longer has access credentials. The leaked primary key may continue
to work indefinitely. If you decide to keep the Cosmos-based design, you
should:

1. Provision your own Cosmos DB account and database.
2. Populate `Cosmos:Endpoint` and `Cosmos:Key` in `ui/osr_dotnet/App.config`.
3. **Do not commit real credentials.** Consider moving them to environment
   variables or a sibling `App.Local.config` (already in `.gitignore`).

A simpler alternative is to drop Cosmos entirely and persist users +
whitelist to a local JSON file under `%LOCALAPPDATA%\osr\`. The UI was
designed to support a per-machine multi-user model, but in the original
nursing-home use case there is rarely more than one "operator" identity per
station, so a local store may be sufficient.

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

Status: **builds, partial functionality**, depends on Cosmos.

What works:

- Project compiles under Visual Studio 2019+ targeting .NET Framework 4.7.2,
  after a NuGet restore.
- Page navigation through Login → AccountCreate → SelectUser → FirstTimeSetup.
- `FileSystemController.createZipArchive()` recursively zips a configured
  source directory into `C:\Program Files\osr_refresh\clean<userId>.zip`.
- `SelectUser.xaml.cs` enumerates Windows local accounts via WMI
  (`Win32_UserAccount`).

What is broken or missing:

- **`DiscUtilsController` is a stub.** The whole point of pulling in the
  `DiscUtils` NuGet package was to build clean ISO images; only the
  CDBuilder constructor is wired up. No file enumeration, no ISO write.
- **`Configure.xaml.cs`** is empty (default constructor only). The two
  buttons in `Configure.xaml` ("Update Whitelist", "Run Update") are not
  wired to anything.
- **Plaintext password storage** in Cosmos. Hash on create + on lookup
  before re-enabling for any real user. Marked `TODO(handoff)` in
  `CosmosController.QueryUsersAsync`.
- **Random user IDs** (`new Random().Next(2147483647)`). Use `Guid.NewGuid()`
  instead.
- **Hard-coded path** `C:\Program Files\osr_refresh` in
  `FileSystemController.OSR_DIR`. Move to `App.config` or
  `Environment.SpecialFolder.LocalApplicationData`.
- **`Microsoft.WindowsAPICodePack`** dependency may be hard to restore from
  modern NuGet feeds; the official package was unlisted years ago. There
  are community-maintained forks; you may need to point your local feed at
  one of those.
- No tests, no input validation on the AccountCreate form beyond
  empty-field and password-match checks.
- `async void` in event handlers swallows exceptions silently.

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
   or price point those tools don't hit.

2. **If continuing: kill the Cosmos dependency.** Replace `CosmosController`
   with a `LocalUserStore` backed by a JSON file under
   `%LOCALAPPDATA%\osr\`. This eliminates the abandoned-Azure-account
   problem and makes the app self-contained.

3. **Finish `DiscUtilsController`** — actually implement the clean-ISO
   builder. This was the architectural improvement over the VBox-swap
   approach and is the missing piece that would let the product run on
   bare metal.

4. **Address the hashing / SQL injection / random-ID issues** before any
   field deployment.

5. **Replace hardcoded paths and VM names** with config-driven values.

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
