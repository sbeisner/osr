"""Status data — reads the same files host.sh and the C++ binaries write.

Read-only: nothing in here mutates engine state. The aim is to surface
"what's currently happening / what just happened" to the admin without
needing them to SSH into the host and tail logs.
"""

import os
import re
from datetime import datetime
from pathlib import Path
from typing import List, Optional


HOME = Path(os.path.expanduser("~"))

# Defaults match host.sh; overridable via env vars so tests can point at
# a fixture tree without touching the real engine state.
HOST_LOG = Path(os.environ.get("OSR_HOST_LOG", HOME / "osr-host.log"))
ARCHIVE_DIR = Path(os.environ.get("OSR_ARCHIVE_DIR", HOME / "osr-archive"))
DEST_DIR = Path(os.environ.get("OSR_DEST_DIR", HOME / "dest"))


CYCLE_START_RE = re.compile(r"=== cycle start \(")
CYCLE_DONE_RE = re.compile(r"=== cycle complete ===")
RANSOMWARE_RE = re.compile(r"RANSOMWARE_INDICATOR")
WARN_RE = re.compile(r"\bWARN\b")
ERROR_RE = re.compile(r"\bERROR\b|\bFATAL\b")


def tail_log(path: Path = HOST_LOG, n: int = 500) -> List[str]:
    """Last n lines of the host log, newest last. Empty list if no log yet."""
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return []
    return [line.rstrip("\n") for line in lines[-n:]]


def classify_log_line(line: str) -> str:
    """CSS class hint for a single log line, used by templates to color it."""
    if RANSOMWARE_RE.search(line):
        return "ransomware"
    if ERROR_RE.search(line):
        return "error"
    if WARN_RE.search(line):
        return "warn"
    return ""


def archive_summary() -> dict:
    """Counts and timestamps of past archives. Distinguishes SUSPICIOUS ones."""
    if not ARCHIVE_DIR.exists():
        return {"total": 0, "suspicious": 0, "latest": None, "free_bytes": None}

    total = 0
    suspicious = 0
    latest_mtime: Optional[float] = None
    for entry in ARCHIVE_DIR.iterdir():
        if entry.name.endswith(".SUSPICIOUS"):
            suspicious += 1
            continue
        if entry.is_dir():
            total += 1
            mtime = entry.stat().st_mtime
            if latest_mtime is None or mtime > latest_mtime:
                latest_mtime = mtime

    free_bytes: Optional[int]
    try:
        free_bytes = os.statvfs(ARCHIVE_DIR).f_bavail * os.statvfs(ARCHIVE_DIR).f_frsize
    except OSError:
        free_bytes = None

    return {
        "total": total,
        "suspicious": suspicious,
        "latest": (
            datetime.fromtimestamp(latest_mtime).isoformat(timespec="seconds")
            if latest_mtime is not None
            else None
        ),
        "free_bytes": free_bytes,
    }


def cycle_state() -> dict:
    """Walks recent log lines to determine if a cycle is currently running.

    Approach: scan the tail of the log for cycle-start / cycle-complete
    markers. If the most recent marker is a start without a matching
    complete, a cycle is in flight.
    """
    lines = tail_log(HOST_LOG, n=2000)
    last_start: Optional[str] = None
    last_complete: Optional[str] = None
    last_outcome: Optional[str] = None

    for line in lines:
        if CYCLE_START_RE.search(line):
            last_start = line
            last_outcome = "running"
        elif CYCLE_DONE_RE.search(line):
            last_complete = line
            last_outcome = "complete"

    suspicious = any(RANSOMWARE_RE.search(line) for line in lines[-200:])
    canary_failure_present = (DEST_DIR / "canary-failure.flag").exists()

    return {
        "last_start": last_start,
        "last_complete": last_complete,
        "last_outcome": last_outcome,
        "suspicious_recent": suspicious,
        "canary_failure_present": canary_failure_present,
    }


def status_snapshot() -> dict:
    return {
        "cycle": cycle_state(),
        "archive": archive_summary(),
        "host_log_path": str(HOST_LOG),
        "archive_dir_path": str(ARCHIVE_DIR),
    }
