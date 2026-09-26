#!/usr/bin/env bash
# Prepares a Debian/Ubuntu machine for everything that runs on Linux:
# lint, unit tests, the runtime bridge tests, patch checks and release tooling.
# Idempotent. Swift is optional here (CI uses the swift container image).
set -euo pipefail

need=(git gh python3 shellcheck clang-format build-essential curl jq zip unzip)
missing=()
for pkg in "${need[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "installing: ${missing[*]}"
    SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq "${missing[@]}"
fi

python3 --version
shellcheck --version | sed -n 2p
if command -v swift >/dev/null 2>&1; then swift --version 2>&1 | sed -n 1p
else echo "swift: not installed (optional; see https://www.swift.org/install/linux/)"; fi
gh auth status >/dev/null 2>&1 && echo "gh: authenticated" || echo "gh: NOT authenticated (gh auth login)"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tools/deps/lockfile.py" validate
echo "bootstrap-linux: OK — run scripts/lint.sh"
