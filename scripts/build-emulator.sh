#!/usr/bin/env bash
# Fetches the pinned emulator, builds the iOS dependencies (unless the prefix
# is already built from the same deps.lock) and builds the emulator dylib.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PREFIX="${PREFIX:-$ROOT/prefix}"

"$ROOT/emulator/scripts/fetch.sh"
want="$(python3 "$ROOT/tools/deps/lockfile.py" hash)"
if [ "$(cat "$PREFIX/.deps-lock-hash" 2>/dev/null || true)" != "$want" ]; then
    rm -rf "$PREFIX"
    "$ROOT/emulator/scripts/build-ios-deps.sh"
else
    echo "dependencies: prefix up to date ($PREFIX)"
fi
"$ROOT/emulator/scripts/build-ios.sh"
