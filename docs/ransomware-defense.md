# Ransomware defense

This document captures the threat model, the defenses currently in place,
the defenses that should land before any paying customer, and the defenses
that are research-tier or not worth the engineering effort. Future
maintainers picking up this project will need to revisit this question;
this document exists so the conversation starts from a known baseline.

The TL;DR: with the host-side scanner (`host.sh`) and Defender's
Controlled Folder Access configured inside the Clean VM, OSR catches
the bulk of commodity ransomware. With canary files added, it catches
most of the rest. The remaining gap is targeted attacks by adversaries
with budget — out of scope for the kinds of customers OSR is built for.

## The structural problem

OSR's value proposition is "the OS resets to a clean state on every
shutdown, but the user's personal files are preserved." The mechanism
is straightforward: at shutdown the engine copies the whitelisted user
folders out to a host-side shared folder; the OS image is then replaced
with a clean clone; on next boot the user's files are copied back into
the new clean OS.

If a user's files are encrypted by ransomware before the shutdown step
runs, the engine dutifully copies the encrypted bytes to the shared
folder, then dutifully restores them onto the next clean OS. The OS
reset works perfectly. The user data persistence works perfectly. The
combination means the very mechanism designed to insulate users from
infections is what propagates this one.

This is structurally identical to why `rsync ~ /backup/` is not a
backup — without versioning, your "backup" is just whichever state
the source happens to be in, including encrypted-by-ransomware state.

## Threat model

OSR is built for low-budget institutional environments — nursing homes,
small libraries, community centers. Realistic threats:

- **Commodity ransomware** delivered via email attachment, malicious
  download, drive-by web exploit, or USB stick. Generic, opportunistic,
  hits whoever opens the wrong file.
- **Living-off-the-land attacks** that use legitimate Windows tools
  (PowerShell, certutil, BITS) to download payloads.
- **Social-engineering of staff** into running an "IT support" tool
  that's actually a remote-access trojan.

Out of scope:

- **Targeted intrusions by funded attackers** (nation-state, organized
  crime targeting a specific institution). These require an EDR product
  with a 24/7 SOC behind it; OSR is not that and is not aspiring to be.
- **Physical attacks** (boot-from-USB, drive removal, firmware-level
  compromise). The lockdown in `setup-host.sh` is meant to keep
  end-users from accidentally escaping the VM, not to resist focused
  hardware attacks.
- **VirtualBox guest-to-host privilege escalation**. Real bug, mature
  guest VM tech, mostly mitigated by keeping VirtualBox patched. We
  treat VirtualBox isolation as a containment boundary, not a security
  boundary.

## Defense-in-depth model

Four layers, mapped to where each implementation lives:

```
Layer        | Where it lives                              | Status
-------------+---------------------------------------------+----------
Prevention   | inside the Clean VM (Defender, CFA, etc.)   | partial
Detection    | host.sh + canary files in the VMs           | partial
Containment  | VirtualBox network config + host filesystem | not started
Recovery     | host.sh archive history                     | done
```

### 1. Prevention — don't let ransomware run

The highest-leverage item is **Microsoft Defender's Controlled Folder
Access** (CFA). It's a free, built-in Windows feature that blocks
unauthorized applications from writing to a configured list of user
data folders. Most commodity ransomware fails immediately on a
CFA-protected machine — the encryption call never lands.

CFA is configured *inside the Clean VM*, gets snapshotted as part of
the Clean image, and is therefore restored to a known-good state on
every cycle. There is no opportunity for a Dirty-side compromise to
disable it permanently because the next reset undoes any in-session
tampering.

Setup procedure is in `engine/DEPLOYMENT.md` under "Configure ransomware
protection inside the Clean VM."

Other preventive measures, in decreasing ROI:

- Microsoft Defender on with cloud-delivered protection. Definitions
  update during the Dirty session (network access required); cloud
  reputation lookups catch novel malware better than offline-only.
- SmartScreen turned on (default in modern Windows; verify).
- UAC at "Always notify."
- Outlook attachment policy: block .exe, .scr, .vbs, .js, .iso, .lnk
  attachments by default.
- AppLocker / Windows Defender Application Control: allowlist
  applications. High maintenance overhead because each customer's
  app stack is different. Not recommended unless a specific customer
  asks for it.

### 2. Detection — know it happened

Two cheap signals OSR can act on:

**Host-side extension and ransom-note scan** (implemented in `host.sh`).
Before archiving the shared folder, scan for files matching a blacklist
of common ransomware-appended extensions (`.locked`, `.encrypted`,
`.crypt`, etc.) and known ransom-note filename patterns
(`HOW_TO_DECRYPT*`, `README_TO_DECRYPT*`, `!_INFO.txt`, etc.). On a
hit, the archive is marked `.SUSPICIOUS`, `dir_desc.txt` is deleted
from the shared folder before the Clean VM starts (so Boot.exe restores
*nothing* into the next clean session — the user gets a fresh empty
state instead of an encrypted one), and a loud log entry goes to
`~/osr-host.log` for the admin to find via Tailscale SSH.

**Canary files** (implemented; needs C++ rebuild before it takes
effect). Boot.exe writes an `osr-canary.txt` to each whitelisted
directory after the restore. The first line is a fixed magic string
(`OSR_CANARY_v1`); the rest is a "do not delete" notice readable by
end-users.

Shutdown.exe verifies each canary on the next shutdown. The detection
logic deliberately handles the first-run / mass-nuke ambiguity:

  - All canaries intact: clean.
  - Some present, some missing or modified: definite tampering.
    Writes `canary-failure.flag` to the shared folder; host.sh
    reads it and treats the session as SUSPICIOUS.
  - All canaries absent: ambiguous (could be the first session of a
    fresh Clean VM where Boot.exe never ran, or a thorough ransomware
    sweep). Logs loudly but does NOT flag — the host-side extension
    scanner will catch the ransomware case via other signals, and
    we'd rather take the false-negative here than false-positive on
    every fresh install's first session.

What this catches that the extension scanner doesn't: ransomware that
encrypts files in place without changing extensions. That's the
cleaner end of the commodity-ransomware spectrum.

**Entropy-based detection** (not implemented). Encrypted files have
near-maximum Shannon entropy. A scanner could compare a session's
entropy distribution to the previous shift's archive — a sudden spike
in high-entropy files suggests bulk encryption. Catches ransomware
that doesn't change extensions. False positives on JPEGs,
password-protected zips, and anything else that's already compressed.
~80 lines of Python; worth doing once the simpler signals are
deployed and tuned.

### 3. Containment — limit blast radius

Not implemented. Two cheap improvements when there's time:

**Network segmentation.** Configure the Dirty VM with a NAT-only
network and explicit firewall rules so it can reach the internet (the
user needs to browse, send email) but cannot reach the host's other
network resources (printer servers, NAS, other workstations on the
LAN). VirtualBox NAT mode does most of this by default; a per-customer
firewall pass tightens it.

**Read-only host-side mount of `~kiosk/dest/` except during the
Shutdown.exe write window.** This is harder than it sounds: the Dirty
VM has the shared folder mounted for the entire user session, so we
cannot toggle host-side permissions mid-session without breaking the
mount. A clean implementation requires splitting `~kiosk/dest/` into
two directories — `dest-in/` (Shutdown writes here) and `dest-out/`
(Boot reads here) — and having `host.sh` move files between them.
That's an architectural change to both shutdown.cpp and boot.cpp;
maybe a future cycle.

### 4. Recovery — undo the damage

**Snapshot history of the shared folder** is implemented in `host.sh`.
Every successful cycle archives the previous session's data to
`~/osr-archive/<timestamp>/` (rolling 7-shift history by default,
configurable via `ARCHIVE_KEEP`). When a user reports lost or
corrupted files, an admin can copy the missing data back from a
prior archive over Tailscale SSH.

When the host-side scanner detects ransomware indicators, the
suspicious archive is marked with a `.SUSPICIOUS` flag file so an
admin reviewing archives can tell which sessions were quarantined.

Future improvements:

- **Per-file change-versus-prior-shift detection**: hash whitelisted
  files on shutdown; on the next shutdown, compare. A file whose
  content changed AND whose entropy went up is suspicious. Useful as
  a second-tier signal that catches encryption attacks where the
  attacker preserved file extensions and didn't drop a ransom note.
- **Air-gapped offsite backup**: nightly `rclone` push to a customer-
  owned S3 bucket or NAS. Operations cost; not a code feature.

## Prioritized implementation order

| # | Item | Where | Effort | Impact | Status |
|---|------|-------|--------|--------|--------|
| 1 | Defender + Controlled Folder Access in Clean VM | DEPLOYMENT.md procedure | small (config) | high | documented; deployer applies |
| 2 | Host-side extension + ransom-note scan | `host.sh` | small (~40 LOC bash) | high | **implemented** |
| 3 | Canary files | shutdown.cpp + boot.cpp | medium (~80 LOC C++) | medium | **implemented** (needs rebuild) |
| 4 | Network segmentation (Dirty VM firewall) | per-customer config | small | medium | not started |
| 5 | Read-only mount split | architectural | large | medium | not started |
| 6 | Per-file hash-versus-prior-shift detection | host.sh + new hash store | medium | low-medium | not started |
| 7 | Entropy-based detection | host.sh + Python helper | medium | low (lots of FP) | not started |
| 8 | Air-gapped offsite backup | operations | small (config) | low (recovery only) | not started |

#1 + #2 + #3 together cover the bulk of commodity ransomware:
prevention (CFA), extension/note detection, and content-tampering
detection. Below #3 the marginal returns diminish quickly versus what
you'd get by just buying Microsoft Defender for Endpoint.

## What this does not protect against

OSR's ransomware story has hard limits a customer should understand:

- **Ransomware that hits during the user session and exfiltrates data
  before encrypting** (modern double-extortion attacks). The OS reset
  prevents persistence and the host-side scanner refuses to propagate
  the encrypted state, but the data has already left the building.
  OSR is not a data-loss-prevention system.
- **Sophisticated targeted attacks** that disable Defender, drop
  legitimate-looking files, mimic user app behavior to avoid CFA,
  or skip extension changes and ransom notes. These need an EDR
  product with active threat hunting.
- **Insider threats** (a staff member intentionally encrypting files).
  Indistinguishable from a user organizing their own data.
- **Hardware attacks** (USB rubber ducky, BadUSB, firmware implants).
  OSR is a software product running on commodity hardware.

The honest framing for a customer: OSR plus Defender plus CFA stops
most opportunistic attacks. For higher assurance, pair OSR with a
managed EDR product. For environments where data loss is genuinely
catastrophic (regulated healthcare, financial services), OSR is not
a sufficient defense on its own — those customers want UWF + EDR +
network segmentation + offsite backup + 24/7 monitoring, which is
not the OSR price point.
