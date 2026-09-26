#!/usr/bin/env bash
# Prepares a Mac (or a GitHub macOS runner) for the iOS build: selects the
# Xcode deps.lock pins and installs the build tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/tools/deps/lockfile.py"
XCODE_PATH="${XCODE_PATH:-$(python3 "$LOCK" get toolchain.xcode_path)}"
XCODE_WANT="$(python3 "$LOCK" get toolchain.xcode)"

if [ -d "$XCODE_PATH" ]; then
    sudo xcode-select -s "$XCODE_PATH"
elif [ -n "${CI:-}" ]; then
    echo "pinned Xcode not on this runner: $XCODE_PATH" >&2
    ls -d /Applications/Xcode*.app >&2 || true
    exit 1
else
    echo "warning: $XCODE_PATH not found; using $(xcode-select -p)" >&2
fi
have="$(xcodebuild -version | awk 'NR==1 {print $2}')"
echo "Xcode $have (pinned $XCODE_WANT) at $(xcode-select -p)"
if [ -n "${CI:-}" ] && [ "$have" != "$XCODE_WANT" ] && [ "${ALLOW_XCODE_MISMATCH:-0}" != 1 ]; then
    echo "Xcode version mismatch" >&2
    exit 1
fi
xcrun --sdk iphoneos --show-sdk-version

# Jobs that only compile the app (simulator smoke test) need no build tools.
if [ "${SKIP_BREW:-0}" = 1 ]; then exit 0; fi

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install --quiet meson ninja pkg-config cmake autoconf automake libtool m4 qemu
if [ -n "${GITHUB_PATH:-}" ]; then echo "$(brew --prefix m4)/bin" >> "$GITHUB_PATH"; fi
meson --version
cmake --version | sed -n 1p
