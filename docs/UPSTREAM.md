# Upstream

Surveyed 2026-09-26. The exact commits VirtualPhone builds from are in
[`deps.lock`](../deps.lock); this page explains them. Updating a pin is its own
PR (`chore: update Inferno to <SHA>`, see [CONTRIBUTING](../CONTRIBUTING.md)).

## Projects

| Project | Role for us | Branch | Commit (pinned / surveyed) | Licence |
|---|---|---|---|---|
| [ChefKissInc/Inferno](https://github.com/ChefKissInc/Inferno) | The emulator: QEMU fork with Apple T8030 (iPhone 11) machine | `master` | `cc4302a99167abec69b714cfd00c38caece7e7de` (2026-07-29) — reference | GPL-3.0; ChefKiss's own code AGPL-3.0; branding restricted |
| [MakrSas/Inferno](https://github.com/MakrSas/Inferno/tree/ios) | Inferno fork that runs as a library inside an iOS app | `ios` | **`b76fa575831d94a80db169ffb3c76d9094a648bd`** (2026-09-24) — **built** | same as Inferno; fork's additions AGPL-3.0-or-later |
| [MakrSas/Inferno-iOS](https://github.com/MakrSas/Inferno-iOS) | Prior art: SwiftUI app around the fork (the "Inferno for iPhone" app) | `main` | `4bc39702871f5a118d96acbad4df7a675ddf14e0` (2026-09-25) — reference | GPL-3.0 |
| QEMU | Base of both | — | fork reports `QEMU-10.2.2_10.1.3_hybrid` | GPL-2.0-or-later (mostly), see QEMU's `LICENSE` |

The fork's `VERSION` is `InfernoiOS-1.0.0rc1_QEMU-10.2.2_10.1.3_hybrid`; ChefKiss's is
`ChefKissInferno-1.0.0rc1_QEMU-10.2.2_10.1.3_hybrid`. ChefKissInc/Inferno is itself a fork of
TrungNguyen1909/qemu-t8030.

## Why the MakrSas `ios` fork

ChefKiss Inferno builds `qemu-system-aarch64` as a program. iOS cannot fork/exec, so the
emulator has to be a library in the app's own process, and several things had to change for
that. The `ios` fork carries them (from its README and tree):

- `-Dshared_lib=true` — builds `libqemu-aarch64-softmmu.dylib` exporting `qemu_init`,
  `qemu_main_loop`, `qemu_cleanup` with default symbol visibility.
- **In-process display** (`ui/inferno-embed.c`, `include/ui/inferno-embed.h`): a display change
  listener tracks damaged rows; the app copies them straight out of the surface. No VNC encoding.
- **Input**: `inferno_input_touch(x, y, pressed)` for the multitouch panel in absolute pixels;
  `inferno_input_function_key(n, pressed)` for device buttons wired to F1–F10
  (`hw/input/buttons.c`: F1 force-shutdown, F2 ringer toggle, F3 volume down, F4 volume up,
  F5 hold/side, F6 menu/home).
- **USB-NCM host** (`hw/net/apple-ncm-host.c`): the app is its own USB host; the guest's
  CDC-NCM link goes out through slirp. `inferno_net_link_up()` reports the link.
- **SMC battery** (`inferno_battery_set`), **haptics** stream, reset hold for restores.
- Coalesced UART, an address-space memory patch, an extra NVMe namespace in the device tree
  (fast file transfer channel).
- Migration run states removed: in the fork `RunState` is
  `debug, internal-error, io-error, paused(3), …`; in ChefKiss master `paused` is index 4.
  `tools/deps/check_abi.py` checks the values the bridge relies on against the pinned tree.

VirtualPhone therefore **pins the fork**. The only patch pins two meson subprojects the fork
tracks by branch — `libyuv` (`main`, a CMake subproject added 2026-09-17 for the display scaler)
and `mlib` (`master`) — to exact commits (`emulator/patches/0001-…`, `deps.lock` → `subprojects`).
`keycodemapdb` is already pinned upstream. Inferno-iOS's own CI last built successfully on
2026-09-11, before libyuv arrived, so its build recipe predates the CMake requirement.
Our own changes live in the runtime bridge (`app/Runtime`).

## Build instructions (as established upstream)

- Dependencies for arm64 iOS, static, in one prefix: zlib 1.3.1, GMP 6.3.0, nettle 3.10.2,
  libtasn1 4.20.0, libpng 1.6.58, pixman 0.44.2, glib 2.84.3 (+ bundled libffi, pcre2 with JIT
  off, proxy-libintl), libslirp 4.9.1, libucontext 1.3.2 (`freestanding=true`), lzfse 1.0.
  Our [`emulator/scripts/build-ios-deps.sh`](../emulator/scripts/build-ios-deps.sh) is adapted
  from Inferno-iOS's script, with every tarball verified against a SHA-256 in `deps.lock`.
- Meson cross-file for `darwin/ios/aarch64`, deployment target 16.0.
- Meson options: `-Dshared_lib=true -Db_staticpic=true -Dcoroutine_backend=ucontext`
  (iOS has no usable `sigaltstack`), accelerators/UI backends disabled, `-Dvnc=enabled`
  (kept as upstream builds it; VNC wants keymaps from a stock QEMU at runtime), `-Dtools=disabled`.
- Target: `ninja libqemu-aarch64-softmmu.dylib`.
- Upstream app build uses `swiftc` directly (no Xcode project), ad-hoc signs, zips `Payload/`.
  Upstream built with Xcode 27.0 locally and `macos-26` in CI.

## Runtime facts learned upstream (we rely on them)

- **JIT**: TCG needs executable memory. A sideloaded app gets it only when a debugger is attached
  (StikDebug etc.) or with the JIT entitlement. With a debugger, `MAP_JIT` is typically refused
  but `mprotect` RW→RX works, so TCG runs with `split-wx=on`. Without JIT the emulator wedges on
  the first translated block — so the app refuses to start instead. See [JIT.md](JIT.md).
- **Memory**: iOS kills an app at about 3 GiB regardless of entitlements. Upstream gives the
  guest 2 GB. Translation buffer: 64 MB → 8–11 fps, 256 MB → 21–25 fps measured on a phone;
  128 MB default.
- **Threading**: `qemu_init` returns holding the BQL; `qemu_main_loop` must run on that same
  thread; the display listener may only be attached in that gap. After cleanup the thread must
  drop the BQL or exit notifiers deadlock.
- **One machine per process**: QEMU keeps global state; a second `qemu_init` in one process is
  not supported. The app must be relaunched to boot again.
- **`qemu_init` calls `exit()`** on a bad command line or a missing/empty/directory file —
  taking the app down. Upstream issue #5. We validate every file before starting.
- **Multi-threaded TCG only**: single-threaded TCG makes the SEP panic initialising its key store.
- **Panel sizes**: a framebuffer row must be a multiple of 16 bytes; presets 828×1792,
  752×1336, 640×1136 at scale 2. At 750 wide the guest never finishes booting.
- **Boot mode** must be given explicitly (`boot-mode=exit_recovery`) or stale NVRAM can send the
  machine to recovery.
- **Audio**: off unless asked for; the audio device is otherwise not described to the guest.
- **Networking**: guest sometimes drops its interface; recovery is `ipconfig set en0 DHCP` on
  the guest console.
- **File transfer / IPA install / guest agent**: upstream uses a spare NVMe namespace as a raw
  byte channel (with checksums), a guest agent started by launchd, and the jailbreak bootstrap's
  shell on the serial console. Guest helpers are signed with `ldid` so AMFI in the guest runs them.

## Known issues upstream

From Inferno-iOS `README.md`/`TODO.md`: slow boot (minutes), 3 GiB ceiling, only three panel
sizes, no FairPlay-encrypted App Store apps, audio experimental, network drops, no dependency
resolution in its package manager, `.zst` repository indexes unsupported.

## Branding

ChefKiss's boot splash artwork (`CKQEMUBootSplash@2x.png`) and the name "ChefKiss Inferno" are
not covered by the open-source licence; derivatives must not ship the artwork or imply
endorsement (`ui/icons/CKBrandingNotice.md`). The `ios` fork's tree does not contain the
artwork; VirtualPhone never bundles it (the forbidden-file scanner refuses it) and is not
affiliated with ChefKiss or MakrSas.
