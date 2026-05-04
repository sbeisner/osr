# host-ui — OSR admin web UI

A small Flask app served by gunicorn under systemd, exposed onto the
host's Tailscale tailnet by `tailscale serve`. Replaces the in-VM WPF
configurator (`../ui/`); see `../docs/host-ui-plan.md` for the
architectural rationale.

## What it does

- **Status** (`/`) — last cycle outcome, recent ransomware indicators,
  canary state, archive count, free disk under `~/osr-archive`
- **Whitelist** (`/whitelist`) — reads and writes
  `~/osr-config/whitelist.txt` (the file `host.sh` stages into the
  Dirty VM's shared folder before each cycle)
- **Log** (`/log`) — tail of `~/osr-host.log`, color-coded for
  RANSOMWARE_INDICATOR / WARN / ERROR / FATAL lines

## Auth

Tailscale identity headers, only. The app refuses any request missing
the `Tailscale-User-Login` header. The intended ingress path is:

```
admin's laptop on the tailnet
   ↓ HTTPS
osr-<machinename>.<tailnet>.ts.net  (Tailscale serve)
   ↓ HTTP, with Tailscale-User-* identity headers added
127.0.0.1:8080  (gunicorn → Flask)
```

There is no public-internet exposure at any layer. Direct
console-recovery access to the host is via `tailscale ssh
admin@<machine>`, not the web UI.

## Install (production)

`engine/setup-host.sh` will eventually orchestrate this. The manual
steps:

```sh
cd host-ui
python3 -m venv venv
venv/bin/pip install -r requirements.txt

sudo cp osr-ui.service /etc/systemd/system/osr-ui.service
sudo systemctl daemon-reload
sudo systemctl enable --now osr-ui.service

# expose on the tailnet (run once after tailscale up)
tailscale serve --bg --https=443 http://127.0.0.1:8080
```

The systemd unit assumes `host-ui/` lives at `/home/kiosk/code/osr/host-ui`
and that the kiosk user is `kiosk`. Edit it if your layout differs.

## Run for development

```sh
cd host-ui
python3 -m venv venv
venv/bin/pip install -r requirements.txt
venv/bin/python app.py
```

Auth still applies. Send requests with the identity headers populated:

```sh
curl -H 'Tailscale-User-Login: you@example.com' \
     -H 'Tailscale-User-Name: You' \
     http://127.0.0.1:8080/
```

To run against fixture data instead of real engine state:

```sh
OSR_HOST_LOG=/tmp/osr-fixture/host.log \
OSR_ARCHIVE_DIR=/tmp/osr-fixture/archive \
OSR_DEST_DIR=/tmp/osr-fixture/dest \
OSR_CONFIG_DIR=/tmp/osr-fixture/config \
venv/bin/python app.py
```

## File contract with the engine

The web UI writes `~/osr-config/whitelist.txt` (one absolute Windows
path per line, blank lines and `#`-prefixed lines preserved as comments).

`engine/host.sh` reads `WHITELIST_FILE` (default
`~/osr-config/whitelist.txt`) at the start of each cycle and copies it
into `$DEST_DIR/whitelist.txt`. If the file is absent, the cycle uses
`shutdown.exe`'s hardcoded `generate_whitelist()` defaults, matching the
pre-host-ui behavior.

The `shutdown.cpp` change to read the staged file in preference to
`generate_whitelist()` is **not yet landed** — see `../HANDOFF.md`. The
new file is staged but ignored by current `shutdown.exe` builds.

## Files

| Path | What it is |
|------|-----------|
| `app.py` | Flask app + route handlers |
| `auth.py` | `Tailscale-User-Login` header check |
| `status.py` | reads `~/osr-host.log`, archive contents, canary state |
| `whitelist.py` | read+atomic-write `~/osr-config/whitelist.txt` |
| `templates/` | Jinja templates |
| `static/style.css` | inlined CSS |
| `requirements.txt` | Flask + gunicorn |
| `osr-ui.service` | systemd unit |
