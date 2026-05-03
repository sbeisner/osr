# OSR — Operating System Refresh

Originally **Proactive Backup OS Refresh** (pbosr). A system that returns a
Windows workstation to a clean, known-good state on every shutdown while
preserving the user's personal files (Documents, Pictures, Outlook profile,
QuickBooks data, browser bookmarks, etc.).

Built around the use case of low-budget, high-malware-exposure environments
— originally nursing homes — where regular IT resets are not affordable but
the same machines are used by the same handful of users every day.

## Repository layout

```
osr/
├── engine/         Working VirtualBox-based "swap a clean VHD over the
│                   dirty one on shutdown" implementation. C++ + a Linux
│                   host orchestrator + a one-shot host-setup script.
│                   This is the only end-to-end working version.
├── ui/             WPF configurator/account UI written for a later, more
│                   ambitious version of the product. Builds and runs
│                   locally; partially functional. See ui/README.md.
└── docs/           Architecture decisions and rationale documents,
                    e.g. why the WindowsPE approach was rejected.
```

The single most important entry points for the next maintainer:

- **`engine/DEPLOYMENT.md`** — step-by-step guide to turning a fresh
  Linux PC into a deployed kiosk. Linux distro choice, VirtualBox
  setup, VM creation, fullscreen autostart, recovery procedures.
- **`HANDOFF.md`** — honest accounting of the codebase state, what
  works, what's stubbed, suggested next steps.
- **`docs/why-not-winpe.md`** — detailed reasoning for the
  architectural choice of VirtualBox over WindowsPE imaging.
- **`docs/ransomware-defense.md`** — threat model, defense-in-depth
  strategy, what's implemented, and what's deferred. Read this before
  any conversation with a customer about whether OSR "stops ransomware."

## What works today

The `engine/` directory contains the only end-to-end working implementation
of the concept. The pattern is:

1. **Two VirtualBox VMs** on a Linux host: `Dirty-2` (the one users log into)
   and `Clean-2` (a pristine reference image).
2. **Shutdown side** (`engine/pbosr/shutdown.cpp`): runs in the dirty VM
   when a user shuts down. Enumerates `C:\Users`, builds a whitelist
   (Desktop / Documents / Pictures / Music / Videos / Chrome bookmarks /
   Outlook signatures / Office UProof / shared QuickBooks data), copies
   matching files out via the `\\VBoxSvr\dest` shared folder, then issues
   `shutdown /s`.
3. **Host orchestration** (`engine/host.sh`): runs on the Linux host. Watches
   for the dirty VM to power off, boots the clean VM, waits for it to power
   off in turn, then atomically replaces the dirty VHD with a fresh clone of
   the clean VHD via `VBoxManage`.
4. **Boot side** (`engine/Boot/boot.cpp`): runs once on the freshly-cloned
   VM. Reads `dir_desc.txt` from the shared folder, copies user files back
   into place, then powers off so the next user gets a clean login.

This was the prototype that demonstrated the concept worked. It is functional
but rough. See `engine/README.md` for build instructions and
`engine/DEPLOYMENT.md` for the full end-to-end host setup procedure
(`setup-host.sh` automates the Linux side; manual steps cover VM creation
and Windows install).

## What does not work today

The `ui/` directory is a WPF (Windows Presentation Foundation) desktop app
that was the start of a more ambitious productized version: per-user
accounts, license tracking, a configurable whitelist, and a plan to build
clean ISO images via the `DiscUtils` library so the system would not depend
on VirtualBox.

The UI **builds and runs with no cloud dependency** — users persist to a
local JSON file at `%LOCALAPPDATA%\osr\users.json`. You can create accounts,
log in, and configure a whitelist. The two pieces that are still incomplete:
`DiscUtilsController` is a stub (the actual ISO-build logic was never
written) and `Configure.xaml.cs` is empty (the post-setup screen never got
wired up). See `ui/README.md` and `HANDOFF.md` for the full state.

## Project history

This repo is a consolidation of multiple earlier prototype repos:

| Original repo        | Approach                                    | Outcome             |
|----------------------|---------------------------------------------|---------------------|
| `proactive_backup`   | C++ + libssh, Linux host with WSL clients   | Worked partially; superseded |
| `pbosr_windows`      | Qt GUI shell on Windows                     | Empty UI scaffold   |
| `pbosr_windows_sdk`  | VS port of `proactive_backup`               | Incomplete          |
| `os_refresh`         | VirtualBox VM swap                          | **Worked end-to-end → `engine/`** |
| `filesystem_refresh` | ASP.NET Core + Angular                      | Mostly scaffolding  |
| `osr_dotnet`         | WPF + Azure Cosmos + DiscUtils ISO builder  | **Best UI direction → `ui/`**    |

The two preserved code paths represent the two strongest directions: the
working VBox swap, and the WPF productization that was meant to replace it.

## Approaches considered and rejected

Documented for the next maintainer's benefit, so these conversations don't
have to be re-litigated:

- **libssh transport** (`proactive_backup`): worked, but introduced a network
  hop and credential management for a problem that's local to the machine.
  Replaced by `\\VBoxSvr` shared folders.
- **Booting into WindowsPE on shutdown to image-replace the system
  partition**: prototyped and rejected. Microsoft's monthly patch cadence
  and feature-update churn make image-replace approaches a dedicated-team
  problem; the VirtualBox abstraction insulates the host from anything
  Microsoft does inside the VM. See `docs/why-not-winpe.md` for the full
  rationale, including how OSR's architecture compares against the
  existing market (Faronics Deep Freeze, Windows UWF).
- **ASP.NET Core + Angular UI** (`filesystem_refresh`): wrong shape for a
  per-machine local-control-panel app. WPF replaced it.

## License

Apache License 2.0 — see `LICENSE`.
