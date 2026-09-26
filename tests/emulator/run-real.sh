#!/usr/bin/env bash
# Drives the runtime bridge against the real emulator library built for this
# host (emulator/scripts/build-host.sh). No guest files, no phone.
#
#   tests/emulator/run-real.sh [path/to/libqemu-aarch64-softmmu.so]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/build/tests/emulator}"
CC="${CC:-cc}"
case "$(uname -s)" in
    Darwin) LIB="${1:-$ROOT/build/emulator-host/libqemu-aarch64-softmmu.dylib}"; DL="" ;;
    *)      LIB="${1:-$ROOT/build/emulator-host/libqemu-aarch64-softmmu.so}"; DL="-ldl" ;;
esac
[ -f "$LIB" ] || { echo "no emulator library at $LIB (run emulator/scripts/build-host.sh)" >&2; exit 1; }

mkdir -p "$OUT"
# No sanitizers: QEMU is not built with them and leaks by design at exit.
# shellcheck disable=SC2086
$CC -std=c11 -O1 -g -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-unused-parameter \
    -I"$ROOT/app/Runtime" -o "$OUT/test_real" \
    "$ROOT/tests/emulator/test_real.c" "$ROOT/app/Runtime/vp_runtime.c" -lpthread $DL

PORT="${QMP_PORT:-$((20000 + RANDOM % 20000))}"
"$OUT/test_real" "$LIB" "$PORT" "$ROOT/tests/emulator/qmp_probe.py"
