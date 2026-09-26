#!/usr/bin/env bash
# Whole iOS build on a Mac: emulator + app + .ipa in dist/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-emulator.sh"
"$ROOT/app/build.sh"
