# engine/ — VirtualBox swap implementation

The working prototype of the OSR concept. Two C++ programs that run inside
Windows guests, plus a Linux shell script that orchestrates VM lifecycle on
the host.

## Architecture

```
            +-------------------- Linux host --------------------+
            |                                                    |
            |  host.sh    (orchestrator, uses VBoxManage)        |
            |                                                    |
            |  ~/VirtualBox VMs/                                 |
            |    Clean-2/Clean-2.vhd   <-- pristine reference    |
            |    Dirty-2/Dirty-2.vhd   <-- the one users use     |
            |                                                    |
            |  Shared folder \\VBoxSvr\dest  (whitelist transit) |
            +----------------------------------------------------+
                       ^                        ^
                       | Shutdown.exe           | Boot.exe runs once
                       | runs at user shutdown  | on cleanly-cloned VM
                       v                        v
            +---- Dirty-2 (Windows) ----+   +---- Clean-2 (Windows) ----+
            |                           |   |                           |
            |  pbosr/shutdown.cpp       |   |  Boot/boot.cpp            |
            |  - enumerate C:\Users     |   |  - read dir_desc.txt      |
            |  - copy whitelist files   |   |  - copy files back        |
            |    to \\VBoxSvr\dest      |   |  - shutdown /s            |
            |  - shutdown /s            |   |                           |
            +---------------------------+   +---------------------------+
```

## End-to-end flow

1. User finishes their shift and triggers `shutdown.exe` (this should be
   wired to the Windows shutdown process — see Outstanding Work).
2. `shutdown.exe` walks `C:\Users`, builds a whitelist (hardcoded list of
   known user-data subfolders), copies each whitelisted path to
   `\\VBoxSvr\dest\<index>` on the host's shared folder, writes
   `dir_desc.txt` mapping indexes back to original paths, then issues
   `shutdown /s`.
3. `host.sh` detects Dirty-2 has powered off. It starts Clean-2, waits for
   it to power off in turn (Boot.exe shuts the clean VM down once
   restoration is complete), then atomically replaces `Dirty-2.vhd` with a
   fresh clone of `Clean-2.vhd` via `VBoxManage clonemedium`.
4. Next user logs in to a freshly-cloned dirty VM with their files restored
   to their previous locations.

## Deploying this on a real host machine

For end-to-end host setup — picking a Linux distro, installing VirtualBox,
creating the VMs, configuring auto-login and fullscreen autostart, recovery
procedures — see **[DEPLOYMENT.md](DEPLOYMENT.md)**. The `setup-host.sh`
script next to this file automates most of the Linux-side work; the manual
steps are walked through in DEPLOYMENT.

The build instructions below are for the Windows-side binaries that go
inside the VMs.

## Build

### Windows-side modules (`pbosr/`, `Boot/`)

Open `osr-engine.sln` in Visual Studio 2019 or later, x64 build target.

The .sln currently only includes the `pbosr` project (the shutdown side).
To build the boot-side binary, either:

- Right-click the solution → **Add → Existing Project** → select
  `Boot/Boot.vcxproj`, OR
- Open `Boot/Boot.vcxproj` directly.

Both produce a stand-alone `.exe` that gets deployed into the appropriate
VM (shutdown.exe → Dirty VM, boot.exe → Clean VM).

### Linux-side orchestrator (`host.sh`)

Just bash. Requires VirtualBox installed (`VBoxManage` on PATH) and the
two VMs configured with the names referenced inside the script
(`Dirty-2` and `Clean-2` — change to suit).

```bash
chmod +x host.sh
./host.sh
```

## Configuration that needs editing

These are hardcoded in source today. Pull into config / args before any
real deployment:

- VM names and VHD paths in `host.sh` (`Dirty-2`, `Clean-2`,
  `~/VirtualBox VMs/...`)
- The whitelist itself, in `pbosr/shutdown.cpp` `generate_whitelist()`
- The shared-folder path `\\VBoxSvr\dest` in both `pbosr/shutdown.cpp`
  and `Boot/boot.cpp`
- The destination directory cleanup at the bottom of `host.sh`
  (`rm -rf ~/dest/*`) — make sure this matches your VBox shared-folder
  configuration

## Outstanding work

See `../HANDOFF.md` for the full list. The most important items
specifically for the engine:

- Wire `shutdown.exe` to actually run at Windows shutdown (Group Policy
  shutdown script, or a user-initiated shortcut, depending on how locked
  down the workstation is).
- Make `host.sh` clone-then-rename instead of delete-then-clone, so a
  failure mid-`clonemedium` doesn't leave the user with no Dirty VHD at
  all.
- Verify the `Boot/boot.cpp` copy-back preserves directory structure under
  each whitelisted root (the current `for (auto& p : directory_iterator)`
  loop is flat — it iterates one level inside `\\VBoxSvr\dest\<index>` and
  copies each entry into the destination, but does not recurse into
  subdirectories of the whitelisted folders).
