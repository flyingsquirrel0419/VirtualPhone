#!/usr/bin/env bash
# Builds the emulator's dependencies for arm64 iOS into one prefix, from the
# exact tarballs deps.lock pins (each one checked against its SHA-256).
#
#   PREFIX=$PWD/prefix emulator/scripts/build-ios-deps.sh
#
# macOS with Xcode only; needs meson ninja pkg-config autoconf automake libtool m4
# (scripts/bootstrap-macos.sh). Adapted from Inferno-iOS scripts/build-ios-deps.sh
# (GPL-3.0, MakrSas) — the per-package flags and the reasons for them are theirs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="$ROOT/tools/deps/lockfile.py"
PREFIX="${PREFIX:-$ROOT/prefix}"
WORK="${WORK:-$ROOT/.deps-build}"
DEPLOY="${DEPLOY:-$(python3 "$LOCK" get toolchain.ios_deployment_target)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
FLAGS="-arch arm64 -isysroot $SDK -mios-version-min=$DEPLOY"

export CC="clang $FLAGS"
export CXX="clang++ $FLAGS"
export CPP="clang -E $FLAGS"
AR="$(xcrun --sdk iphoneos --find ar)"
RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
STRIP="$(xcrun --sdk iphoneos --find strip)"
export AR RANLIB STRIP
export CFLAGS="$FLAGS -O2 -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$FLAGS -L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
HOST=aarch64-apple-darwin

mkdir -p "$PREFIX" "$WORK/src"
cd "$WORK"

CROSS="$WORK/cross-deps.txt"
cat > "$CROSS" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
ar = '$AR'
strip = '$STRIP'
ranlib = '$RANLIB'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-I$PREFIX/include']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-L$PREFIX/lib', '-framework', 'CoreFoundation']
cpp_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-I$PREFIX/include']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-L$PREFIX/lib', '-framework', 'CoreFoundation']
objc_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY']
prefix = '$PREFIX'
[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$PREFIX/lib/pkgconfig']
EOF

# "name file sha256 url..." per package. No associative arrays: macOS ships bash 3.2.
PACKAGES="$(python3 "$LOCK" packages)"
pkg_entry() { echo "$PACKAGES" | awk -v n="$1" '$1 == n { $1 = ""; sub(/^ /, ""); print }'; }

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# fetch <name>: download into src/, verify, unpack into <name>/
fetch() {
    local name="$1" file sum urls url ok="" entry
    entry="$(pkg_entry "$name")"
    [ -n "$entry" ] || { echo "$name is not in deps.lock" >&2; exit 1; }
    read -r file sum urls <<<"$entry"
    local tar="$WORK/src/$file"
    if [ -f "$tar" ] && [ "$(sha256_of "$tar")" != "$sum" ]; then rm -f "$tar"; fi
    if [ ! -f "$tar" ]; then
        for url in $urls; do
            echo "    fetch $url"
            if curl -fsSL --connect-timeout 20 --retry 3 --speed-limit 1024 --speed-time 30 -o "$tar.part" "$url"; then
                ok=1; break
            fi
            echo "    ...failed, next mirror" >&2
        done
        [ -n "$ok" ] || { echo "could not download $name" >&2; exit 1; }
        mv "$tar.part" "$tar"
    fi
    local got
    got="$(sha256_of "$tar")"
    if [ "$got" != "$sum" ]; then
        echo "$name: checksum mismatch: got $got, deps.lock says $sum" >&2
        rm -f "$tar"
        exit 1
    fi
    rm -rf "${WORK:?}/${name:?}"
    mkdir -p "$WORK/$name"
    tar -xf "$tar" -C "$WORK/$name" --strip-components=1
}

meson_build() { # meson_build <srcdir> [opts...]
    local src="$1"; shift
    meson setup "$src/_b" "$src" --cross-file "$CROSS" --prefix "$PREFIX" \
        --buildtype release --default-library static --wrap-mode default "$@"
    meson compile -C "$src/_b" -j "$JOBS"
    meson install -C "$src/_b"
}

conf_build() { # conf_build <srcdir> [configure opts...]
    local src="$1"; shift
    ( cd "$src" && ./configure --host="$HOST" --prefix="$PREFIX" --enable-static --disable-shared "$@" \
      && make -j"$JOBS" && make install )
}

echo "==> prefix $PREFIX"
echo "==> SDK    $SDK (deployment $DEPLOY)"

fetch zlib
( cd zlib && ./configure --prefix="$PREFIX" --static && make -j"$JOBS" && make install )

fetch gmp
conf_build gmp --disable-assembly

fetch nettle
conf_build nettle --disable-documentation --disable-openssl --disable-assembler

fetch libtasn1
conf_build libtasn1 --disable-doc

fetch libpng
conf_build libpng --disable-tools

fetch pixman
meson_build pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled

# glib brings its own libffi, pcre2 and proxy-libintl (absent from the iOS SDK)
# as meson wraps, which pin their own checksums. pcre2's JIT uses macOS-only
# W^X APIs and does not compile for iOS, so it is off.
fetch glib
meson_build glib -Dtests=false -Ddtrace=disabled -Dintrospection=disabled \
    -Dnls=enabled -Dlibmount=disabled -Dselinux=disabled -Dpcre2:jit=disabled

fetch libslirp
meson_build libslirp

# QEMU's coroutine backend: iOS has no usable sigaltstack. freestanding=true
# avoids the SDK's deprecated <ucontext.h>.
fetch libucontext
meson_build libucontext -Dfreestanding=true

fetch lzfse
make -C lzfse -j"$JOBS" CC="$CC" INSTALL_PREFIX="$PREFIX"
make -C lzfse install INSTALL_PREFIX="$PREFIX"

python3 "$LOCK" deps-hash > "$PREFIX/.deps-lock-hash"
echo "==> done; $PREFIX/lib:"
find "$PREFIX/lib" -maxdepth 1 -type f -name "*.a" | sort | sed "s|^|    |"
