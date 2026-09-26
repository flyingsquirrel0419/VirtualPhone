#!/usr/bin/env bash
# Builds the runtime bridge against the mock emulator and runs every scenario.
# Linux or macOS; sanitizers on by default (SANITIZE= to turn them off).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/build/tests/emulator}"
CC="${CC:-cc}"
SANITIZE="${SANITIZE--fsanitize=address,undefined -fno-omit-frame-pointer}"
WARN="-Wall -Wextra -Werror -Wno-unused-parameter"

case "$(uname -s)" in
    Darwin) SO=dylib; SHARED="-dynamiclib"; DL="" ;;
    *)      SO=so;    SHARED="-shared";     DL="-ldl" ;;
esac

mkdir -p "$OUT"
# shellcheck disable=SC2086
{
    $CC -std=c11 -D_GNU_SOURCE -O1 -g -fPIC -I"$ROOT/app/Runtime" $WARN $SANITIZE $SHARED -fvisibility=hidden \
        -o "$OUT/libmock_qemu.$SO" "$ROOT/tests/emulator/mock_qemu.c" -lpthread
    $CC -std=c11 -D_GNU_SOURCE -O1 -g -fPIC -I"$ROOT/app/Runtime" $WARN $SANITIZE $SHARED -fvisibility=hidden -DMOCK_MINIMAL \
        -o "$OUT/libmock_qemu_min.$SO" "$ROOT/tests/emulator/mock_qemu.c" -lpthread
    $CC -std=c11 -O1 -g -D_GNU_SOURCE $WARN $SANITIZE -I"$ROOT/app/Runtime" \
        -o "$OUT/test_runtime" "$ROOT/tests/emulator/test_runtime.c" "$ROOT/app/Runtime/vp_runtime.c" \
        -lpthread $DL
}

status=0
run() { "$OUT/test_runtime" "$@" || status=1; }
run full    "$OUT/libmock_qemu.$SO"
run spent   "$OUT/libmock_qemu.$SO"
run minimal "$OUT/libmock_qemu_min.$SO"
run bad
exit $status
