# ui/ — WPF configurator (`osr_dotnet`)

A Windows desktop application that was the start of a productized version
of OSR: per-user accounts, license tracking, and a configurable whitelist.

The codebase **builds and runs with no cloud dependency**. Users persist to
a local JSON file (see "Where data lives" below). You can create an account,
log in, and configure a whitelist out of the box.

This UI is not currently wired to the `engine/` code in any way. The
broader architectural plan is to replace this in-VM WPF app with a small
web admin UI served by the Linux host on its Tailscale tailnet IP — see
`../HANDOFF.md` for the rationale and the migration plan. The WPF code is
preserved here as a working reference to the user-facing surface (login,
whitelist editor, snapshot trigger) that the host-side replacement will
need to provide.

## Build

Requires Visual Studio 2019+ and .NET Framework 4.7.2.

```
cd ui
nuget restore osr-ui.sln          # or open the .sln in Visual Studio,
                                  # which restores automatically
```

Then build / run from Visual Studio (F5).

No external services or accounts are required to run.

## Where data lives

Users are stored as JSON at:

```
%LOCALAPPDATA%\osr\users.json
```

(typically `C:\Users\<you>\AppData\Local\osr\users.json`). The file is
created on first save. To reset state, delete it.

## What the screens do today

| Screen            | State                                            |
|-------------------|--------------------------------------------------|
| `Login`           | Looks up `email + password` in the local user store. Plaintext password comparison — flagged in HANDOFF. |
| `AccountCreate`   | Appends a new `User` to the local user store with plaintext password and a `Random.Next()` ID. |
| `SelectUser`      | Enumerates Windows local accounts via WMI. Writes choice to user record. |
| `FirstTimeSetup`  | Folder-picker over the chosen Windows user dir. Writes whitelist back to the local user store. Triggers `FileSystemController.createZipArchive()`. |
| `Configure`       | Two buttons wired: **Update Whitelist** navigates back to `FirstTimeSetup`; **Run Update** awaits a fresh local snapshot and reports completion via `MessageBox`. |
| `MainWindow`      | Hosts the page navigation. Async-initializes the user store and the FileSystem controller on construct. |

## Structural notes

- The .sln (`osr-ui.sln`) lives at this directory's root and references the
  project at `osr_dotnet\osr_dotnet.csproj`. The project subfolder name
  must remain `osr_dotnet/` for the .sln to find it (the namespace and
  project ID inside the .csproj are also `osr_dotnet`).
- An identical duplicate of the entire source tree existed at the root of
  the original repo, alongside the canonical subdirectory. Only the
  canonical copy is preserved here.
