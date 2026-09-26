#!/usr/bin/env bash
# Builds the iOS app and packages it as an ad-hoc signed .ipa.
#
#   app/build.sh                              uses build/emulator/libqemu-aarch64-softmmu.dylib
#   EMULATOR_DYLIB=/path/lib.dylib app/build.sh
#   REQUIRE_EMULATOR=0 app/build.sh           UI-only build (mock runtime), for quick checks
#   PLATFORM=simulator app/build.sh           iOS Simulator .app (mock runtime only), for smoke tests
#
# Environment: PRODUCT_NAME (VirtualPhone), BUNDLE_ID (dev.virtualphone.app),
# CHANNEL (dev|nightly|alpha|beta|stable), BUILD_NUMBER, OUT_DIR (dist).
# No Xcode project: swiftc compiles app/Sources/Core + app/Sources/App into one
# module, with the C runtime bridge linked in.
set -euo pipefail
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPSRC="$ROOT/app"
PRODUCT_NAME="${PRODUCT_NAME:-VirtualPhone}"
EXECUTABLE="${EXECUTABLE:-VirtualPhone}"
BUNDLE_ID="${BUNDLE_ID:-dev.virtualphone.app}"
CHANNEL="${CHANNEL:-dev}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
REQUIRE_EMULATOR="${REQUIRE_EMULATOR:-1}"
EMULATOR_DYLIB="${EMULATOR_DYLIB:-$ROOT/build/emulator/libqemu-aarch64-softmmu.dylib}"
KEYMAPS="${QEMU_KEYMAPS:-}"
DEPLOY="16.0"
PLATFORM="${PLATFORM:-device}"
case "$PLATFORM" in
    device)    SDK_NAME=iphoneos;        TARGET="arm64-apple-ios$DEPLOY";           PLATFORM_NAME=iPhoneOS ;;
    simulator) SDK_NAME=iphonesimulator; TARGET="arm64-apple-ios$DEPLOY-simulator"; PLATFORM_NAME=iPhoneSimulator
               # The emulator library is built for devices only; the simulator runs the mock.
               REQUIRE_EMULATOR=0; EMULATOR_DYLIB="" ;;
    *) echo "PLATFORM must be device or simulator" >&2; exit 2 ;;
esac

BUILD="$ROOT/build/app-$PLATFORM"
APP="$BUILD/Payload/$EXECUTABLE.app"
SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"

echo "==> $PRODUCT_NAME $VERSION ($BUILD_NUMBER) ${COMMIT:0:12} [$CHANNEL]"
echo "    SDK $SDK"
xcrun --sdk "$SDK_NAME" swiftc --version | sed -n 1p

if [ -z "$EMULATOR_DYLIB" ] || [ ! -f "$EMULATOR_DYLIB" ]; then
    if [ "$REQUIRE_EMULATOR" = 1 ]; then
        echo "emulator library not found: $EMULATOR_DYLIB (REQUIRE_EMULATOR=0 for a UI-only build)" >&2
        exit 1
    fi
    echo "    no emulator library — UI-only build (mock runtime only)"
    EMULATOR_DYLIB=""
fi

rm -rf "$BUILD"
mkdir -p "$APP/Frameworks" "$BUILD/obj" "$OUT_DIR"

echo "==> Runtime bridge (C)"
xcrun --sdk "$SDK_NAME" clang -target "$TARGET" -isysroot "$SDK" -std=c11 -O2 -Wall -Wextra -Werror \
    -Wno-unused-parameter -c "$APPSRC/Runtime/vp_runtime.c" -o "$BUILD/obj/vp_runtime.o"

echo "==> Swift"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find "$APPSRC/Sources/Core" "$APPSRC/Sources/App" -name '*.swift' -print0 | sort -z)
xcrun --sdk "$SDK_NAME" swiftc \
    -target "$TARGET" -sdk "$SDK" \
    -swift-version 5 -O -wmo -parse-as-library \
    -module-name "$EXECUTABLE" \
    -import-objc-header "$APPSRC/Runtime/vp_runtime.h" \
    -o "$APP/$EXECUTABLE" \
    "${SOURCES[@]}" "$BUILD/obj/vp_runtime.o"

echo "==> Bundle"
sed -e "s|__PRODUCT_NAME__|$PRODUCT_NAME|g" \
    -e "s|__EXECUTABLE__|$EXECUTABLE|g" \
    -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    -e "s|__GIT_COMMIT__|$COMMIT|g" \
    -e "s|__CHANNEL__|$CHANNEL|g" \
    "$APPSRC/Resources/Info.plist" > "$APP/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json "[\"$PLATFORM_NAME\"]" "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

echo "==> Icon"
# actool compiles the catalog into Assets.car and returns the Info.plist keys
# the icon needs in a partial plist, merged here rather than transcribed.
if xcrun actool --compile "$APP" --platform "$SDK_NAME" --minimum-deployment-target "$DEPLOY" \
        --app-icon AppIcon --output-partial-info-plist "$BUILD/icon.plist" \
        "$APPSRC/Resources/Assets.xcassets" > "$BUILD/actool.log" 2>&1; then
    python3 - "$APP/Info.plist" "$BUILD/icon.plist" <<'PY'
import plistlib, sys
target, partial = sys.argv[1], sys.argv[2]
with open(target, "rb") as f: info = plistlib.load(f)
with open(partial, "rb") as f: extra = plistlib.load(f)
extra.pop("com.apple.actool.compilation-results", None)
info.update(extra)
with open(target, "wb") as f: plistlib.dump(info, f)
PY
else
    echo "    warning: actool failed, building without an icon" >&2
    cat "$BUILD/actool.log" >&2
fi

if [ -n "$EMULATOR_DYLIB" ]; then
    cp "$EMULATOR_DYLIB" "$APP/Frameworks/"
fi
# QEMU's data directory: keymaps only (VNC is compiled in and wants them).
mkdir -p "$APP/qemu-data"
if [ -z "$KEYMAPS" ] && command -v brew >/dev/null 2>&1; then
    KEYMAPS="$(brew --prefix qemu 2>/dev/null)/share/qemu/keymaps"
fi
if [ -n "$KEYMAPS" ] && [ -d "$KEYMAPS" ]; then
    cp -R "$KEYMAPS" "$APP/qemu-data/keymaps"
else
    echo "    no QEMU keymaps found (QEMU_KEYMAPS=); only the VNC fallback needs them"
fi
cp "$ROOT/LICENSE" "$APP/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/THIRD_PARTY_NOTICES.md"

echo "==> Sign (ad-hoc)"
# The dylib first: the app's seal covers it.
if [ -n "$EMULATOR_DYLIB" ]; then
    codesign --force --sign - --timestamp=none "$APP/Frameworks/$(basename "$EMULATOR_DYLIB")"
fi
codesign --force --sign - --timestamp=none --entitlements "$APPSRC/Entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" >/dev/null

if [ "$PLATFORM" = simulator ]; then
    echo "$APP"
    exit 0
fi

echo "==> Package"
IPA="$OUT_DIR/$PRODUCT_NAME-$VERSION.ipa"
rm -f "$IPA"
( cd "$BUILD" && zip -qry -X "$IPA" Payload -x '*.DS_Store' )

echo "==> Verify"
VERIFY=(python3 "$ROOT/tools/ipa/verify_ipa.py" "$IPA" --expect-version "$VERSION" --require-signature)
[ -n "$EMULATOR_DYLIB" ] && VERIFY+=(--require-emulator)
"${VERIFY[@]}"
python3 "$ROOT/tools/release/forbidden_scan.py" archive "$IPA"
ls -lh "$IPA"
echo "$IPA"
