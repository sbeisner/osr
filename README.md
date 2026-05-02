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
├── engine/   Working VirtualBox-based "swap a clean VHD over the dirty one
│             on shutdown" implementation. C++ + a Linux host orchestrator.
│             This is the only end-to-end working version.
└── ui/       WPF configurator/account UI written for a later, more ambitious
              version of the product. Builds; partially functional. See
              ui/README.md for current state and missing pieces.
```

`HANDOFF.md` is the honest accounting for the next maintainer.

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
but rough. See `engine/` for build instructions.

## What does not work today

The `ui/` directory is a WPF (Windows Presentation Foundation) desktop app
that was the start of a more ambitious productized version: per-user
accounts, license tracking, a configurable whitelist, and a plan to build
clean ISO images via the `DiscUtils` library so the system would not depend
on VirtualBox.

The UI **builds** and you can navigate the screens, but it requires an Azure
Cosmos DB account for user/license storage that is no longer accessible.
`DiscUtilsController` is a stub — the actual ISO-build logic was never
written. See `ui/README.md` and `HANDOFF.md` for the full state.

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
- **Booting into WindowsPE on shutdown to image partitions**: discussed but
  never built. Equivalent to what Faronics Deep Freeze and Windows Unified
  Write Filter (UWF) already provide off-the-shelf — see `HANDOFF.md`.
- **ASP.NET Core + Angular UI** (`filesystem_refresh`): wrong shape for a
  per-machine local-control-panel app. WPF replaced it.

## License

Apache License 2.0 — see `LICENSE`.
