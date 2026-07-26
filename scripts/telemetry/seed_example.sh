#!/usr/bin/env sh
set -eu

# shellcheck disable=SC1003
# shellcheck disable=SC1007
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for interpreter in python3 python py; do
    if command -v "$interpreter" >/dev/null 2>&1 &&
        "$interpreter" -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
        exec "$interpreter" "$script_dir/seed_example.py" "$@"
    fi
done

printf '%s\n' 'error: no Python 3 interpreter found (searched: python3, python, py)' >&2
exit 1
