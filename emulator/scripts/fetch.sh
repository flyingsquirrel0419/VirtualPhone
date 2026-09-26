#!/usr/bin/env bash
# Checks out the emulator at exactly the commit deps.lock pins, then applies
# emulator/patches/series in order. Refuses a tree whose HEAD is anything else.
#
#   emulator/scripts/fetch.sh [DEST]       (default: emulator/src)
#
# Runs on Linux and macOS; Linux CI uses it to prove the patches still apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:-$ROOT/emulator/src}"
LOCK="$ROOT/tools/deps/lockfile.py"
PATCHES="$ROOT/emulator/patches"

REPO="$(python3 "$LOCK" get emulator.repository)"
COMMIT="$(python3 "$LOCK" get emulator.commit)"

if [ -d "$DEST/.git" ]; then
    have="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
    if [ "$have" = "$COMMIT" ] && [ -f "$DEST/.vp-patched" ]; then
        echo "emulator: $DEST already at ${COMMIT:0:12} with patches"
        exit 0
    fi
    echo "emulator: $DEST is at ${have:0:12}, want ${COMMIT:0:12}; refetching"
    rm -rf "$DEST"
fi

mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin "$REPO"
# GitHub serves any reachable commit by SHA, so no branch name is trusted.
for attempt in 1 2 3; do
    if git -C "$DEST" fetch -q --depth 1 origin "$COMMIT"; then break; fi
    [ "$attempt" = 3 ] && { echo "emulator: fetch failed" >&2; exit 1; }
    sleep $((attempt * 5))
done
git -C "$DEST" -c advice.detachedHead=false checkout -q FETCH_HEAD

have="$(git -C "$DEST" rev-parse HEAD)"
if [ "$have" != "$COMMIT" ]; then
    echo "emulator: checked out $have, expected $COMMIT" >&2
    exit 1
fi

count=0
if [ -f "$PATCHES/series" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        patch="${line%%#*}"
        patch="$(echo "$patch" | xargs)"
        [ -z "$patch" ] && continue
        echo "emulator: applying $patch"
        git -C "$DEST" apply --check "$PATCHES/$patch"
        git -C "$DEST" apply "$PATCHES/$patch"
        count=$((count + 1))
    done < "$PATCHES/series"
fi
# Every meson subproject must fetch exactly the commit deps.lock records:
# upstream wraps that track a branch are pinned by our patches.
while read -r name commit; do
    wrap="$DEST/subprojects/$name.wrap"
    [ -f "$wrap" ] || { echo "emulator: deps.lock lists subproject $name but $wrap is missing" >&2; exit 1; }
    rev="$(awk -F' *= *' '$1 == "revision" {print $2}' "$wrap")"
    if [ "$rev" != "$commit" ]; then
        echo "emulator: $name.wrap fetches '$rev', deps.lock pins $commit" >&2
        exit 1
    fi
done < <(python3 "$LOCK" subprojects)
for wrap in "$DEST"/subprojects/*.wrap; do
    rev="$(awk -F' *= *' '$1 == "revision" {print $2}' "$wrap")"
    if ! [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
        echo "emulator: $(basename "$wrap") is not pinned to a commit (revision = $rev)" >&2
        exit 1
    fi
done
touch "$DEST/.vp-patched"
echo "emulator: $DEST at ${COMMIT:0:12}, $count patch(es) applied"
