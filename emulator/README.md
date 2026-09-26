# Emulator

VirtualPhone builds the emulator from source at the commit pinned in [`deps.lock`](../deps.lock):
MakrSas/Inferno branch `ios`, a fork of ChefKiss Inferno (QEMU) that runs as a library inside an
iOS app. Why that fork: [docs/UPSTREAM.md](../docs/UPSTREAM.md).

| Path | Purpose |
|---|---|
| `scripts/fetch.sh` | check out the pinned SHA into `emulator/src`, verify it, apply `patches/series` |
| `scripts/build-ios-deps.sh` | build the arm64 iOS dependency prefix from checksummed tarballs |
| `scripts/build-ios.sh` | build `libqemu-aarch64-softmmu.dylib`, verify its exports |
| `patches/` | our patches on top of the pin (none yet) |

`emulator/src` and `build/` are generated and ignored.

## Patches

None. The pinned fork already exports what the runtime bridge needs; the bridge's view of that ABI
(`app/Runtime/vp_inferno_abi.h`) is checked against the tree on every CI run by
`tools/deps/check_abi.py`.
