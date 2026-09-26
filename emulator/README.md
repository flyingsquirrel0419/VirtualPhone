# Emulator

VirtualPhone builds the emulator from source at the commit pinned in [`deps.lock`](../deps.lock):
MakrSas/Inferno branch `ios`, a fork of ChefKiss Inferno (QEMU) that runs as a library inside an
iOS app. Why that fork: [docs/UPSTREAM.md](../docs/UPSTREAM.md).

| Path | Purpose |
|---|---|
| `scripts/fetch.sh` | check out the pinned SHA into `emulator/src`, verify it, apply `patches/series` |
| `scripts/build-ios-deps.sh` | build the arm64 iOS dependency prefix from checksummed tarballs |
| `scripts/build-ios.sh` | build `libqemu-aarch64-softmmu.dylib`, verify its exports |
| `scripts/build-host.sh` | build the library for the Linux/macOS build host (clang), for `tests/emulator/run-real.sh` |
| `patches/` | our patches on top of the pin, applied in `series` order |

`emulator/src` and `build/` are generated and ignored.

## Patches

| Patch | Why |
|---|---|
| `0001-subprojects-pin-libyuv-and-mlib-wraps.patch` | The fork's `libyuv.wrap` tracks `main` and `mlib.wrap` tracks `master`, so every build could fetch different code. Pins both to the commits recorded under `subprojects` in `deps.lock`; `fetch.sh` refuses any wrap not pinned to a full SHA. |
| `0002-hw-display-prefer-pkg-config-libyuv.patch` | `hw/display` uses a libyuv found by pkg-config before falling back to the subproject. Needed for the Linux host build (`scripts/build-host.sh` provides a PIC libyuv at the pinned commit): meson cannot tell the CMake subproject's static archive is PIC. The iOS build has no `libyuv.pc` in its prefix and is unchanged. |

The runtime bridge needs nothing patched: the fork exports the embed API, and the bridge's view of
that ABI (`app/Runtime/vp_inferno_abi.h`) is checked against the tree on every CI run by
`tools/deps/check_abi.py`.

## CMake subproject

Since 2026-09-17 the fork's display pipe links libyuv, built through meson's CMake integration.
`build-ios.sh` therefore needs `cmake` and writes a `[cmake]` section into the cross-file
(iOS system name, the iPhoneOS SDK as sysroot, JPEG disabled so Homebrew's macOS libjpeg is never
found).

## Host-only patches

`patches/host/` is applied by `scripts/build-host.sh` only, in its own tree
(`build/emulator-host/src-tree`), never to `emulator/src` or the iOS library.

| Patch | Why |
|---|---|
| `host/0001-hw-core-add-back-an-empty-none-machine.patch` | The fork removed QEMU's `none` machine; the Linux bridge test needs a machine that starts without Apple files. |
