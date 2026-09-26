#!/usr/bin/env bash
# Builds the pinned emulator as a shared library for the *build host* (Linux
# or macOS), with system dependencies. Not shipped: it exists so the runtime
# bridge can be driven against the real Inferno library without a phone
# (tests/emulator/run-real.sh).
#
#   emulator/scripts/build-host.sh        -> build/emulator-host/libqemu-aarch64-softmmu.{so,dylib}
#
# Debian/Ubuntu deps: meson>=1.5 ninja-build cmake pkg-config m4 libglib2.0-dev
# libpixman-1-dev libslirp-dev libgmp-dev libtasn1-6-dev libpng-dev liblz4-dev liblzfse-dev
# Nettle comes from deps.lock (distributions ship older than the fork's >= 3.10).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${EMULATOR_SRC:-$ROOT/emulator/src}"
BUILD="${EMULATOR_HOST_BUILD:-$ROOT/build/emulator-host}"
MESON="${MESON:-meson}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

[ -f "$SRC/.vp-patched" ] || "$ROOT/emulator/scripts/fetch.sh" "$SRC"

# Nettle at the pinned version, checksum-verified, into a host prefix.
HOST_PREFIX="${HOST_PREFIX:-$BUILD/prefix}"
if [ ! -f "$HOST_PREFIX/lib/pkgconfig/nettle.pc" ] && [ ! -f "$HOST_PREFIX/lib64/pkgconfig/nettle.pc" ]; then
    read -r _ file sum url _ < <(python3 "$ROOT/tools/deps/lockfile.py" packages | awk '$1 == "nettle"')
    mkdir -p "$BUILD/src" "$HOST_PREFIX"
    curl -fsSL --retry 3 -o "$BUILD/src/$file" "$url"
    got="$( (sha256sum "$BUILD/src/$file" 2>/dev/null || shasum -a 256 "$BUILD/src/$file") | cut -d' ' -f1)"
    [ "$got" = "$sum" ] || { echo "nettle checksum mismatch: $got" >&2; exit 1; }
    rm -rf "$BUILD/src/nettle" && mkdir -p "$BUILD/src/nettle"
    tar -xf "$BUILD/src/$file" -C "$BUILD/src/nettle" --strip-components=1
    ( cd "$BUILD/src/nettle" && ./configure --prefix="$HOST_PREFIX" --libdir="$HOST_PREFIX/lib" \
        --disable-documentation --disable-openssl --enable-shared --disable-static >"$BUILD/nettle.log" 2>&1 \
      && make -j"$JOBS" >>"$BUILD/nettle.log" 2>&1 && make install >>"$BUILD/nettle.log" 2>&1 ) || { tail -20 "$BUILD/nettle.log" >&2; exit 1; }
fi
# libyuv at the commit deps.lock pins, as a PIC static library with a .pc
# file (patch 0002 makes the emulator prefer it over its CMake subproject).
if [ ! -f "$HOST_PREFIX/lib/pkgconfig/libyuv.pc" ]; then
    yuv_commit="$(python3 "$ROOT/tools/deps/lockfile.py" subprojects | awk '$1 == "libyuv" {print $2}')"
    yuv_repo="https://chromium.googlesource.com/libyuv/libyuv"
    rm -rf "$BUILD/src/libyuv" && mkdir -p "$BUILD/src/libyuv"
    git -C "$BUILD/src/libyuv" init -q
    git -C "$BUILD/src/libyuv" fetch -q --depth 1 "$yuv_repo" "$yuv_commit"
    git -C "$BUILD/src/libyuv" -c advice.detachedHead=false checkout -q FETCH_HEAD
    cmake -S "$BUILD/src/libyuv" -B "$BUILD/src/libyuv/_b" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DLIBYUV_DISABLE_JPEG=ON -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=TRUE \
        -DCMAKE_INSTALL_PREFIX="$HOST_PREFIX" > "$BUILD/libyuv.log" 2>&1
    ninja -C "$BUILD/src/libyuv/_b" yuv >> "$BUILD/libyuv.log" 2>&1 || { tail -20 "$BUILD/libyuv.log" >&2; exit 1; }
    mkdir -p "$HOST_PREFIX/lib/pkgconfig" "$HOST_PREFIX/include"
    cp "$BUILD/src/libyuv/_b/libyuv.a" "$HOST_PREFIX/lib/"
    cp -R "$BUILD/src/libyuv/include/." "$HOST_PREFIX/include/"
    cat > "$HOST_PREFIX/lib/pkgconfig/libyuv.pc" <<PC
prefix=$HOST_PREFIX
Name: libyuv
Description: libyuv at $yuv_commit (static, PIC)
Version: 0
Libs: -L\${prefix}/lib -lyuv -lstdc++
Cflags: -I\${prefix}/include
PC
fi
export PKG_CONFIG_PATH="$HOST_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$HOST_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

case "$(uname -s)" in
    Darwin) LIB=libqemu-aarch64-softmmu.dylib ;;
    *)      LIB=libqemu-aarch64-softmmu.so ;;
esac
# The fork is only ever built with Apple clang, whose optimiser removes some
# qemu_build_not_reached() calls that GCC and upstream clang 18 cannot prove
# dead, so they stop with a compile error. -fno-inline defines __NO_INLINE__,
# which turns those into runtime asserts. This library only has to run the
# bridge tests, not guests, so the lost inlining does not matter.
export CC="${CC:-clang}" CXX="${CXX:-clang++}"
HOST_CFLAGS="-fno-inline"

if [ ! -f "$BUILD/meson/build.ninja" ]; then
    "$MESON" setup "$BUILD/meson" "$SRC" \
        -Dbuildtype=release -Dshared_lib=true -Db_staticpic=true -Dwerror=false \
        -Dkvm=disabled -Dhvf=disabled -Dwhpx=disabled \
        -Dcocoa=disabled -Dgtk=disabled -Dsdl=disabled -Dcurses=disabled \
        -Dcoreaudio=disabled -Dcurl=disabled -Dlibssh=disabled -Dbzip2=disabled \
        -Dvnc=enabled -Dvnc_jpeg=disabled -Dvnc_sasl=disabled \
        -Dtools=disabled \
        -Dc_args="$HOST_CFLAGS" -Dcpp_args="$HOST_CFLAGS" \
        -Dc_link_args="-Wl,-rpath,$HOST_PREFIX/lib"
fi
ninja -C "$BUILD/meson" -j "$JOBS" "$LIB"
cp "$BUILD/meson/$LIB" "$BUILD/$LIB"
ls -l "$BUILD/$LIB"
