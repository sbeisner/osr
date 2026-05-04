# Host-side admin UI — design plan

The configuration UI today (`ui/osr_dotnet/`) lives inside the disposable
Dirty VM. That has structural problems that this plan addresses:

- It has to talk to the engine through `\\VBoxSvr\dest` shared folders.
- Every cycle wipes its install, so it has to be reinstalled inside every
  Clean VM build.
- It depends on a Windows-only stack (.NET Framework + WPF + WindowsAPICodePack).
- The actual engine state (cycles, archives, ransomware flags, snapshots)
  lives on the Linux host, which the WPF app cannot see.

The configuration UI being inside the disposable VM is structurally
backwards. The host is where engine state lives; the UI should live there
too, and the engine's whitelist should be sourced from a host-side config
file driven by that UI.

## Target shape

A small web app served by the Linux host on its Tailscale tailnet IP
only — never the public internet. Admins reach it from any device signed
into the tailnet (laptop, phone, customer-site machine).

### Auth

Tailscale's tailnet identity, via `tailscale serve --identity-headers`.
The web app trusts the headers populated by Tailscale (user email +
tailnet name), drops `bcrypt`, drops `LocalUserStore`, drops the entire
login/account-create flow. The "are you allowed to administer this
host" question is answered by "are you on this customer's tailnet."

There is no public-internet exposure at any layer — the web app binds
to `127.0.0.1` and `tailscale serve` is the only thing that exposes it.

### Stack

**Python + Flask + Jinja, served by gunicorn under systemd.** HTMX on the
frontend so the JS surface stays small and the templates render
server-side. Chosen for long-term maintainability by the current
maintainer (no prior Go experience).

A Python venv lives at `host-ui/venv/` and is created by `setup-host.sh`;
the systemd unit invokes the venv's gunicorn directly.

### File layout

```
host-ui/
├── app.py                Flask app + route handlers
├── auth.py               Tailscale identity-header middleware
├── status.py             reads ~/osr-host.log, archive contents, canary state
├── whitelist.py          read+write ~/osr-config/whitelist.txt
├── templates/
│   ├── _layout.html
│   ├── status.html       latest cycle, canary, archive count
│   ├── whitelist.html    editor with one path per line
│   └── log.html          tail of ~/osr-host.log
├── static/               minimal CSS (htmx.min.js to be vendored if/when needed)
├── requirements.txt      flask, gunicorn
├── osr-ui.service        systemd unit installed by setup-host.sh
└── README.md
```

### v1 feature scope

1. **Status page** (`/`):
   - Last cycle outcome (clean / SUSPICIOUS / failed)
   - Canary state from most recent cycle
   - Archive count + last successful archive timestamp
   - Disk space free under `~/osr-archive`
   - Live "currently running" indicator (parses the latest `cycle start`
     line from `~/osr-host.log` without a matching `cycle complete`)

2. **Whitelist editor** (`/whitelist`):
   - Reads `~/osr-config/whitelist.txt` (one absolute Windows path per line)
   - Writes back atomically (temp + rename)
   - Validation: rejects empty paths and lines containing `..`; warns on
     paths that don't begin with `C:\`
   - On save, the next cycle picks up the new whitelist (see "Engine wire-up")

3. **Recent-cycle log** (`/log`):
   - Tail (last N lines configurable, default 500) of `~/osr-host.log`
   - Color-codes RANSOMWARE_INDICATOR / WARN / ERROR / FATAL lines

4. **Canary status** (rolled into the status page rather than its own page)

Out of scope for v1 (deferred to v2):
- Manually triggering a cycle from the UI ("Run cycle now")
- Editing engine env vars (DIRTY_VM, ARCHIVE_KEEP, etc.) from the UI
- Multi-host fleet view (one UI per host for v1)
- Per-Windows-user whitelists — v1 has one whitelist per host, which
  matches how the engine's `generate_whitelist()` works today

### Engine wire-up

The current engine has a hardcoded whitelist in
`pbosr/shutdown.cpp::generate_whitelist()`. To let the host-side UI drive
the whitelist, the wire-up is:

1. Web UI writes `~/osr-config/whitelist.txt` on the host (one absolute
   Windows path per line, e.g. `C:\Users\steven\Documents`).

2. `host.sh` gains a step before "Starting $DIRTY_VM": if
   `~/osr-config/whitelist.txt` exists, copy it to
   `$DEST_DIR/whitelist.txt`. Otherwise, leave `$DEST_DIR/whitelist.txt`
   absent.

3. `shutdown.cpp::generate_whitelist()` is modified to check for
   `\\VBoxSvr\dest\whitelist.txt` first. If present, copy its contents
   into the VM-local `whitelist.txt` (the file `parse_whitelist()`
   reads). If absent, fall back to the existing hardcoded enumeration.

This gives a smooth migration: existing deployments without a host-side
config file keep working unchanged. New deployments with the web UI get
the editable whitelist.

### Deployment

`setup-host.sh` gains:
- A `python3 -m venv host-ui/venv` step plus
  `host-ui/venv/bin/pip install -r host-ui/requirements.txt`
- A systemd unit (`/etc/systemd/system/osr-ui.service`) that invokes
  `host-ui/venv/bin/gunicorn -b 127.0.0.1:8080 app:app` from the
  `host-ui/` working directory, as the kiosk user
- A `tailscale serve --bg --https=443 http://127.0.0.1:8080` invocation
  so the UI is reachable at `https://osr-<machinename>.<tailnet>.ts.net/`
- An `~/osr-config/` directory created with mode 0700, owned by the
  kiosk user

`generalize-host.sh` already strips identity for cloning; we add
`~/osr-config/` to its preserved-files list (the customer's whitelist
should survive a master-image clone if it's part of the master, or be
re-set on the cloned host if not — TBD per customer).

## What goes away (eventually)

After the web UI is live and proven:
- The entire `ui/osr_dotnet/` WPF app (preserved in git history)
- `LocalUserStore` and the per-user JSON store
- `bcrypt` dependency
- The `\\VBoxSvr\dest\snapshot-<userId>.zip` parallel-snapshot mechanism
  (the engine's `~/osr-archive/` is the canonical archive)

In the interim (during the build-out), the WPF code stays in `ui/` as a
reference for the user-facing surface (login flow → SelectUser →
FirstTimeSetup → Configure) that the host UI is replacing. We delete it
in the same commit that lands the v1 host UI deployment.

## Estimated scope

3-5 days for v1, broken down:
- Day 1: Go scaffolding, route skeleton, templates, status page reading
  the host log
- Day 2: Whitelist editor + atomic write, engine wire-up in `host.sh`
- Day 3: `shutdown.cpp` whitelist-from-shared-folder support, end-to-end
  test on a real cycle
- Day 4: Deployment plumbing (`setup-host.sh`, systemd unit, Tailscale
  serve), docs
- Day 5: Buffer for the unknowns (Tailscale identity-headers gotchas,
  systemd permissions, etc.)

## Confirmed decisions

1. **Stack**: Python + Flask. (Maintainer has no Go experience; long-term
   support cost matters more than runtime simplicity.)
2. **WPF retention**: keep as reference until v1 ships and is proven on
   a real host, then delete in a single follow-up commit.
3. **Loopback bypass**: none. The `127.0.0.1:8080` bind is for Tailscale
   serve to proxy from; direct console-recovery access is via
   `tailscale ssh` to a shell, not the web UI.
4. **Whitelist file location**: `~/osr-config/whitelist.txt`, one
   absolute Windows path per line. This is the contract between the
   web UI (writer) and `host.sh` (reader).
