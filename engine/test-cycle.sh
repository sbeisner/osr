#!/usr/bin/env bash
# test-cycle.sh — local correctness tests for host.sh's pure-bash logic.
#
# Useful on a Mac (no VirtualBox) to catch regressions in:
#   - the ransomware scanner (extension + ransom-note patterns)
#   - archive_dest's mv + .SUSPICIOUS marker placement
#   - the prune-to-ARCHIVE_KEEP rolling-history logic
#
# Does NOT test the VM lifecycle or the VHD swap — those need VirtualBox
# and are exercised by host.sh itself in DRY_RUN mode (see "DRY-RUN
# would execute" lines in osr-host.log) or by an actual deployment.
#
# Run: bash engine/test-cycle.sh
# Exit: 0 if all tests pass, non-zero otherwise.

set -uo pipefail

# All sandboxed under one tempdir.
SANDBOX=$(mktemp -d -t osr-test.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# Override host.sh's defaults to point inside the sandbox.
DEST_DIR="$SANDBOX/dest"
ARCHIVE_DIR="$SANDBOX/archive"
LOG_FILE="$SANDBOX/host.log"
ARCHIVE_KEEP=3
export DEST_DIR ARCHIVE_DIR LOG_FILE ARCHIVE_KEEP
mkdir -p "$DEST_DIR"

# Source host.sh as a library. The gate at the bottom of host.sh detects
# the source-vs-execute distinction and skips the main cycle flow.
SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$0")")"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/host.sh"

PASSED=0
FAILED=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n'  "$1"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local actual=$1 expected=$2 desc=$3
    if [ "$actual" = "$expected" ]; then pass "$desc"; else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

reset_dest() {
    rm -rf "$DEST_DIR" "$ARCHIVE_DIR"
    mkdir -p "$DEST_DIR" "$ARCHIVE_DIR"
}

section() {
    printf '\n--- %s ---\n' "$1"
}

# ===========================================================================
section "Scanner — clean session"
# ===========================================================================
reset_dest
mkdir -p "$DEST_DIR/0/Documents" "$DEST_DIR/1/Pictures"
echo "report draft" > "$DEST_DIR/0/Documents/quarterly-report.docx"
echo "spreadsheet" > "$DEST_DIR/0/Documents/budget.xlsx"
echo "JFIF data" > "$DEST_DIR/1/Pictures/vacation.jpg"
echo "C:\\Users\\staff\\Documents" > "$DEST_DIR/dir_desc.txt"

if scan_for_ransomware_signs "$DEST_DIR" >/dev/null 2>&1; then
    pass "scanner reports clean dir as clean"
else
    fail "scanner false-positive on clean dir"
fi

# ===========================================================================
section "Scanner — extension blacklist"
# ===========================================================================
reset_dest
mkdir -p "$DEST_DIR/0"
echo "encrypted by ransomware" > "$DEST_DIR/0/document.docx.locked"
echo "another" > "$DEST_DIR/0/photos.zip.encrypted"

if scan_for_ransomware_signs "$DEST_DIR" >/dev/null 2>&1; then
    fail "scanner missed .locked + .encrypted files"
else
    pass "scanner flags .locked + .encrypted"
fi

# ===========================================================================
section "Scanner — ransom-note patterns"
# ===========================================================================
reset_dest
mkdir -p "$DEST_DIR/0"
echo "user file" > "$DEST_DIR/0/document.docx"
echo "ransom message" > "$DEST_DIR/0/HOW_TO_DECRYPT.txt"

if scan_for_ransomware_signs "$DEST_DIR" >/dev/null 2>&1; then
    fail "scanner missed HOW_TO_DECRYPT.txt"
else
    pass "scanner flags HOW_TO_DECRYPT.txt"
fi

# ===========================================================================
section "Scanner — case-insensitive"
# ===========================================================================
reset_dest
mkdir -p "$DEST_DIR/0"
echo "varied casing in real ransomware" > "$DEST_DIR/0/file.LOCKED"

if scan_for_ransomware_signs "$DEST_DIR" >/dev/null 2>&1; then
    fail "scanner did not match .LOCKED (case-insensitive expected)"
else
    pass "scanner matches .LOCKED via -iname"
fi

# ===========================================================================
section "archive_dest — clean session"
# ===========================================================================
reset_dest
mkdir -p "$DEST_DIR/0/Documents"
echo "user file" > "$DEST_DIR/0/Documents/report.docx"
SUSPICIOUS_SESSION=0
archive_dest >/dev/null 2>&1

# DEST_DIR should now be empty (recreated)
dest_count=$(find "$DEST_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$dest_count" "0" "DEST_DIR is empty after archive"

# ARCHIVE_DIR should have exactly one timestamped subdir, no .SUSPICIOUS
archive_subdirs=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$archive_subdirs" "1" "exactly one archived session"

suspicious_markers=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -name '*.SUSPICIOUS' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$suspicious_markers" "0" "no .SUSPICIOUS marker on a clean session"

# Original file should be inside the archive
archived_file=$(find "$ARCHIVE_DIR" -name "report.docx" 2>/dev/null | head -1)
if [ -n "$archived_file" ]; then
    pass "user file preserved in archive"
else
    fail "user file lost — not found in archive"
fi

# ===========================================================================
section "archive_dest — suspicious session"
# ===========================================================================
reset_dest
mkdir -p "$DEST_DIR/0"
echo "encrypted" > "$DEST_DIR/0/file.locked"
SUSPICIOUS_SESSION=1
archive_dest >/dev/null 2>&1

suspicious_markers=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -name '*.SUSPICIOUS' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$suspicious_markers" "1" ".SUSPICIOUS marker created"

# The marker should be a sibling of the archive dir, named <ts>.SUSPICIOUS
marker_path=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -name '*.SUSPICIOUS' 2>/dev/null)
expected_archive=${marker_path%.SUSPICIOUS}
if [ -d "$expected_archive" ]; then
    pass "marker sits next to its archive directory"
else
    fail "marker has no matching archive dir (expected: $expected_archive)"
fi

# ===========================================================================
section "archive_dest — prune to ARCHIVE_KEEP"
# ===========================================================================
reset_dest

# Run 5 cycles. ARCHIVE_KEEP=3 (set above). After all 5, only the 3 most
# recent archives should remain.
SUSPICIOUS_SESSION=0
for i in 1 2 3 4 5; do
    mkdir -p "$DEST_DIR/0"
    echo "cycle $i" > "$DEST_DIR/0/data.txt"
    archive_dest >/dev/null 2>&1
    # archive_dest's timestamp is YYYYMMDD-HHMMSS at second resolution;
    # sleep 1 to ensure each archive has a unique name.
    sleep 1
done

archive_count=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$archive_count" "3" "5 cycles -> 3 archives kept (ARCHIVE_KEEP=3)"

# ===========================================================================
section "archive_dest — prune retains SUSPICIOUS markers"
# ===========================================================================
reset_dest
SUSPICIOUS_SESSION=0
for i in 1 2 3 4; do
    mkdir -p "$DEST_DIR/0"
    echo "cycle $i" > "$DEST_DIR/0/data.txt"
    if [ "$i" = "2" ]; then SUSPICIOUS_SESSION=1; else SUSPICIOUS_SESSION=0; fi
    archive_dest >/dev/null 2>&1
    sleep 1
done

# After 4 cycles with ARCHIVE_KEEP=3, only the latest 3 archives stay.
# Cycle #1 was pruned; cycle #2 (the SUSPICIOUS one) should still be
# present along with its marker.
archive_count=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$archive_count" "3" "after prune: 3 archive dirs"

suspicious_markers=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -name '*.SUSPICIOUS' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$suspicious_markers" "1" "SUSPICIOUS marker survived prune"

# ===========================================================================
section "archive_dest — empty DEST_DIR no-op"
# ===========================================================================
reset_dest
SUSPICIOUS_SESSION=0
archive_dest >/dev/null 2>&1

archive_count=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$archive_count" "0" "empty DEST_DIR -> no archive created"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n=== %d passed, %d failed ===\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then exit 1; fi
exit 0
