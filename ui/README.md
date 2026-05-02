# ui/ — WPF configurator (`osr_dotnet`)

A Windows desktop application that was the start of a productized version
of OSR: per-user accounts, license tracking, a configurable whitelist, and
a planned (but never finished) clean-ISO builder via the `DiscUtils`
library.

This codebase **builds** but is not end-to-end functional. Notably:

- It depends on Azure Cosmos DB and **will refuse to start** until you
  populate `osr_dotnet/App.config` with credentials of a Cosmos account you
  control.
- The ISO builder (`DiscUtilsController`) is a stub.
- It is not wired to the working `engine/` code in any way.

For the full state of every component, see `../HANDOFF.md`.

## Build

Requires Visual Studio 2019+ and .NET Framework 4.7.2.

```
cd ui
nuget restore osr-ui.sln          # or open the .sln in Visual Studio,
                                  # which restores automatically
```

Then build / run from Visual Studio (F5).

### Cosmos DB setup before first run

1. Provision an Azure Cosmos DB account (any tier; the free 1000 RU/s
   container is sufficient for development).
2. Open `osr_dotnet/App.config`.
3. Replace the placeholder values under `<appSettings>`:

   ```xml
   <add key="Cosmos:Endpoint" value="https://YOUR-ACCOUNT.documents.azure.com:443/" />
   <add key="Cosmos:Key"      value="REPLACE_WITH_YOUR_COSMOS_PRIMARY_KEY" />
   ```

4. **Do not commit your real credentials.** A `.gitignore` rule excludes
   `App.Local.config` if you'd rather keep them in a sibling file the
   project pulls in via a `<file>` attribute.

The app will throw an `InvalidOperationException` at startup if either
placeholder is detected — that's the intentional guard. If you'd rather
skip Cosmos entirely, see the "Suggested next steps" section in
`../HANDOFF.md`.

## What the screens do today

| Screen            | State                                            |
|-------------------|--------------------------------------------------|
| `Login`           | Queries Cosmos for `email + password` (now parameterized; was SQL-injectable). Plaintext password comparison. |
| `AccountCreate`   | Writes a new `User` to Cosmos with plaintext password and a `Random.Next()` ID. |
| `SelectUser`      | Enumerates Windows local accounts via WMI. Writes choice to user record. |
| `FirstTimeSetup`  | Folder-picker over the chosen Windows user dir. Writes whitelist back to Cosmos. Triggers `FileSystemController.createZipArchive()`. |
| `Configure`       | Empty. Two buttons in XAML, no click handlers wired up. |
| `MainWindow`      | Hosts the page navigation. Async-initializes Cosmos and FileSystem controllers on construct. |

## Structural notes

- The .sln (`osr-ui.sln`) lives at this directory's root and references the
  project at `osr_dotnet\osr_dotnet.csproj`. The project subfolder name
  must remain `osr_dotnet/` for the .sln to find it (the namespace and
  project ID inside the .csproj are also `osr_dotnet`).
- An identical duplicate of the entire source tree existed at the root of
  the original repo, alongside the canonical subdirectory. Only the
  canonical copy is preserved here.
