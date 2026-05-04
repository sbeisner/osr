"""Read and atomically write the host-side whitelist.

Contract with the engine (see docs/host-ui-plan.md):
- File lives at ~/osr-config/whitelist.txt
- One absolute Windows path per line (e.g. `C:\\Users\\steven\\Documents`)
- Blank lines and lines starting with `#` are comments and preserved
  on round-trip so admins can annotate
- host.sh copies this file into $DEST_DIR/whitelist.txt before booting
  the Dirty VM. shutdown.cpp reads it from \\VBoxSvr\\dest\\whitelist.txt
  in preference to its hardcoded fallback.

Atomicity: writes go to a sibling .tmp file then os.replace() into place.
"""

import os
import re
from pathlib import Path
from typing import List, Tuple


HOME = Path(os.path.expanduser("~"))
CONFIG_DIR = Path(os.environ.get("OSR_CONFIG_DIR", HOME / "osr-config"))
WHITELIST_PATH = CONFIG_DIR / "whitelist.txt"


# A path is considered acceptable if:
#   - it begins with a drive letter and `:\` (e.g. `C:\`)
#   - it does not contain `..` (no path traversal smuggled past the C++
#     side, which uses SHFileOperation and is not designed to handle that)
#   - it does not contain quotes or newline-equivalent characters
WIN_PATH_RE = re.compile(r"^[A-Za-z]:\\[^\r\n\t\"<>|*?]*$")


def read_whitelist() -> str:
    """Return raw file contents, or "" if the file does not yet exist."""
    if not WHITELIST_PATH.exists():
        return ""
    try:
        return WHITELIST_PATH.read_text(encoding="utf-8")
    except OSError:
        return ""


def validate_whitelist(text: str) -> Tuple[List[str], List[str]]:
    """Returns (errors, warnings). Empty errors list = safe to save.

    Errors are conditions that would make the file useless or unsafe to
    feed into shutdown.cpp's parse_whitelist; warnings are merely
    suspicious (e.g. a non-`C:\\` drive letter, or a missing user
    directory).
    """
    errors: List[str] = []
    warnings: List[str] = []
    seen = set()

    for i, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ".." in line:
            errors.append(f"Line {i}: path traversal '..' is not allowed: {line!r}")
            continue
        if not WIN_PATH_RE.match(line):
            errors.append(
                f"Line {i}: not a valid Windows absolute path "
                f"(must start with a drive letter, e.g. C:\\\\Users\\\\you\\\\Documents): {line!r}"
            )
            continue
        if not line.upper().startswith("C:\\"):
            warnings.append(
                f"Line {i}: drive letter is not C:; the engine targets the Dirty VM's "
                f"system drive, this entry will silently no-op: {line!r}"
            )
        if line in seen:
            warnings.append(f"Line {i}: duplicate entry: {line!r}")
        seen.add(line)

    return errors, warnings


def write_whitelist(text: str) -> None:
    """Atomic write. Caller is expected to have already called validate_whitelist."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Normalize line endings to \n on disk; shutdown.cpp reads with std::getline
    # which strips both \n and \r, so this is a stylistic choice not a correctness
    # one. \n keeps the file readable from any Linux tool.
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.endswith("\n"):
        normalized += "\n"

    tmp = WHITELIST_PATH.with_suffix(WHITELIST_PATH.suffix + ".tmp")
    tmp.write_text(normalized, encoding="utf-8")
    os.replace(tmp, WHITELIST_PATH)
    try:
        WHITELIST_PATH.chmod(0o600)
    except OSError:
        pass
