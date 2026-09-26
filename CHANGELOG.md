# Changelog

All notable changes. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- Serial console (log tailer, console tab with input), boot phase detection with timings, QMP
  client, first-frame time, guest file status in settings.
- Real-library test: the bridge drives the pinned Inferno built for Linux (`emulator-host.yml`).
- Command-line guard: every option/property/device the app passes must exist in the pinned tree.
- Guest services: network recovery, file transfer over slirp with cksum, IPA inspection
  (arch, FairPlay, minimum OS) and installation.
- Per-device qcow2 overlays and state copies (config schema 2), reset, unclean-shutdown warning.
- App icon (original artwork, `tools/icon/make_icon.py`).

## [0.1.0] - 2026-09-26

Bootstrap.

### Added
- Pinned emulator: MakrSas/Inferno `ios` @ b76fa575 (ChefKiss Inferno, QEMU 10.x) and all iOS
  dependencies with SHA-256 checksums (`deps.lock`).
- Runtime bridge `vp_emulator_*` (C) with capability detection, pause/resume/reset/stop, touch,
  buttons, battery, framebuffer and metrics; tested against a mock emulator under ASan/UBSan.
- VirtualPhoneCore: machine configuration (schema 1, migration), `.vphone` packages
  (create/open/list/clone/rename/delete, atomic saves), guest file resolution and checks, emulator
  command line, touch coordinate mapping, JIT decision, logging, build metadata.
- SwiftUI app: device library, create/settings/clone/rename/delete/export, running screen with
  Home/Side/Vol± and debug overlay, JIT status, diagnostics with export, mock runtime.
- CI: Linux CI, macOS iOS build (pinned macOS 26 / Xcode 26.6), release, nightly, dependency check;
  forbidden-file and secret scanner, IPA verifier, SBOM.
- Emulator patch 0001 pins the fork's libyuv and mlib meson subprojects to commits; LZ4 1.10.0
  added to the dependencies; libyuv's CMake build configured for iOS.

### Known issues
- Guest boot not yet verified on a physical device; physical-device tests NOT RUN.
- No app icon. One machine per app launch.
