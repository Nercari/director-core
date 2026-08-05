#!/usr/bin/env sh
# check-example-sanitization — refuse to ship an example that carries a secret.
#
# The committed denylist is generic on purpose. A denylist naming real aliases,
# accounts, or hostnames would publish the topology it exists to protect, so
# site-specific strings belong in an untracked .sanitizer-denylist.local, which
# this script reads when present and ignores when absent. CI never depends on it.
#
# Usage: check-example-sanitization.sh [<path> ...]
#        with no argument, scans examples/executor-evidence/**
# Exit:  0 clean, 1 a pattern matched, 2 could not be checked.
set -eu

# shellcheck disable=SC1007  # CDPATH= is deliberately scoped to this cd.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for interpreter in python3 python py; do
    if command -v "$interpreter" >/dev/null 2>&1 &&
        "$interpreter" -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
        exec "$interpreter" - "$script_dir" "$@" <<'PY'
import math
import re
import sys
from pathlib import Path

script_dir = Path(sys.argv[1])
root = script_dir.parent
arguments = sys.argv[2:]
DEFAULT_SCAN = root / "examples" / "executor-evidence"
LOCAL_DENYLIST = root / ".sanitizer-denylist.local"

# Labels are part of the contract: a failure has to name what matched, so an
# operator can tell a real leak from a pattern that needs narrowing.
PATTERNS = [
    (
        "credential-shaped name (*_API_KEY, *_SECRET, *_TOKEN, *_PASSWORD)",
        re.compile(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*_(?:API_KEY|SECRET|TOKEN|PASSWORD)\b"),
    ),
    (
        "credential-like token prefix",
        re.compile(
            r"\b(?:sk-[A-Za-z0-9]{8,}|gh[posu]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}"
            r"|xox[baprs]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{12,}|AIza[0-9A-Za-z_-]{20,})"
        ),
    ),
    (
        "private key block",
        re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ),
    (
        "absolute path (POSIX home)",
        re.compile(r"(?:^|[\s\"'(=:,\[])/(?:home|Users|root)/[A-Za-z0-9._-]"),
    ),
    (
        "absolute path (Windows drive letter)",
        re.compile(r"(?:^|[\s\"'(=,\[])[A-Za-z]:[\\/]{1,2}[A-Za-z0-9._-]"),
    ),
    (
        "URL carrying credentials",
        re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@"),
    ),
    (
        "non-public hostname",
        re.compile(r"\b[a-z0-9][a-z0-9-]*\.(?:internal|corp|lan|local)\b"),
    ),
]

ENTROPY_CANDIDATE = re.compile(r"[A-Za-z0-9+/=_-]{32,}")


def shannon(text):
    counts = {}
    for character in text:
        counts[character] = counts.get(character, 0) + 1
    total = len(text)
    return -sum((n / total) * math.log2(n / total) for n in counts.values())


def entropy_hits(line):
    """Flag long, dense strings.

    Pure hexadecimal is excluded: a commit reference is the one long fixed-alphabet
    string these envelopes are supposed to contain, and flagging it would train
    readers to ignore this check.
    """
    for candidate in ENTROPY_CANDIDATE.findall(line):
        if re.fullmatch(r"[0-9a-fA-F]+", candidate):
            continue
        if shannon(candidate) >= 4.2:
            return candidate
    return None


def local_patterns():
    if not LOCAL_DENYLIST.is_file():
        return []
    compiled = []
    for number, raw in enumerate(LOCAL_DENYLIST.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            compiled.append((f"local denylist entry (line {number})", re.compile(line)))
        except re.error as error:
            print(f"  [FAIL]  {LOCAL_DENYLIST.name} line {number} is not a valid pattern: {error}")
            raise SystemExit(2)
    return compiled


def targets():
    if arguments:
        # A directory argument scans the tree under it. Without this, naming a
        # directory read as a file and exited 2, so "scan this examples tree"
        # looked like a broken checker rather than a clean scan.
        selected = []
        for argument in arguments:
            path = Path(argument)
            if path.is_dir():
                selected += sorted(child for child in path.rglob("*") if child.is_file())
            else:
                selected.append(path)
        return selected
    if not DEFAULT_SCAN.is_dir():
        print(f"cannot scan {DEFAULT_SCAN}: no such directory", file=sys.stderr)
        raise SystemExit(2)
    return sorted(path for path in DEFAULT_SCAN.rglob("*") if path.is_file())


patterns = PATTERNS + local_patterns()
findings = 0
scanned = 0

for path in targets():
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"  [FAIL]  cannot read {path}: {error}")
        raise SystemExit(2)
    except UnicodeDecodeError:
        print(f"  [SKIP]  {path}: not UTF-8 text")
        continue
    scanned += 1
    for number, line in enumerate(text.splitlines(), 1):
        for label, pattern in patterns:
            match = pattern.search(line)
            if match:
                print(f"  [FAIL]  {path}:{number}: {label} — matched {match.group(0)!r}")
                findings += 1
        candidate = entropy_hits(line)
        if candidate is not None:
            print(
                f"  [FAIL]  {path}:{number}: long high-entropy string — "
                f"matched {candidate[:12]!r}..."
            )
            findings += 1

if findings:
    print(f"REJECT — {findings} finding(s) across {scanned} file(s). Nothing ships with a secret in it.")
    raise SystemExit(1)
print(f"  [ OK ]  {scanned} file(s) scanned, no credential, absolute path, or private hostname")
raise SystemExit(0)
PY
    fi
done

printf '%s\n' 'error: no Python 3 interpreter found (searched: python3, python, py)' >&2
exit 1
