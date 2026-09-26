#!/usr/bin/env bash
# Writes SHA256SUMS for the given files (basenames only), then verifies it.
#   scripts/checksum.sh OUT_DIR file...
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 OUT_DIR file..." >&2; exit 2; }
out="$1"; shift
mkdir -p "$out"
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
: > "$out/SHA256SUMS"
for f in "$@"; do
    [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
    ( cd "$(dirname "$f")" && sum "$(basename "$f")" ) >> "$out/SHA256SUMS"
done
check() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$@"; else shasum -a 256 -c "$@"; fi; }
for f in "$@"; do
    [ "$(cd "$(dirname "$f")" && pwd)" = "$(cd "$out" && pwd)" ] || cp "$f" "$out/"
done
( cd "$out" && check SHA256SUMS )
cat "$out/SHA256SUMS"
