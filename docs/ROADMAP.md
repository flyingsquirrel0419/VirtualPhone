# Roadmap

Priorities: real iOS boot > stable runtime > usable controls > VM management > performance >
polish. A milestone is done when its criteria are met **on a physical device** where stated;
results that need a phone are recorded as NOT RUN until someone runs them.

## v0.1 — Bootstrap (current)

- [x] Upstream surveyed and pinned (docs/UPSTREAM.md, deps.lock)
- [x] Linux bootstrap, lint, unit tests, bridge tests with mock emulator
- [x] Runtime bridge API (`vp_emulator_*`) with capability detection
- [x] SwiftUI shell: device library, create/clone/rename/delete/settings/export, running screen,
      buttons, debug overlay, diagnostics export, JIT detection, mock runtime
- [x] Linux CI, macOS iOS build, release, nightly, dependency-check workflows
- [x] CI builds the Inferno dylib and an IPA artifact on the pinned runner (run 36224154220,
      commit ef5424b: `VirtualPhone-<sha>.ipa`, 4.3 MB, emulator 12.3 MB, arm64, ad-hoc signed)
- [ ] Physical device: app launches, JIT detected, mock runtime renders (NOT RUN)

## v0.2 — T8030 boot pipeline

Goal: kernel boot output captured.
- [x] Serial console: chardev logfile tailer, console tab, input over the serial socket
- [x] QMP client (`query-status`), status in the debug overlay
- [x] Boot phases iBoot → kernel → launchd → shell (+ panic, warnings, timings) from console markers
- [x] Guest file readiness with per-file status and sizes
- [x] Bridge driven against the real Inferno library on Linux, state checked over QMP
- [x] Every option/property/device of the command line checked against the pinned tree
- [ ] Device test: kernel log reaches `launchd` on a phone (NOT RUN — needs the user's guest image)

## v0.3 — SpringBoard

- [x] First-frame time recorded (overlay, BOOT log)
- [ ] Framebuffer → Metal layer path, once a device measurement shows the CGImage path limits FPS
- [ ] Device test: SpringBoard visible on a phone (NOT RUN)

## v0.4 — Touch and buttons

- [x] Investigation: the emulated panel (`hw/input/mt-spi.c`) takes one contact — multi-touch needs
      an emulator patch reporting several paths (not started)
- [x] Tap/long-press/drag/swipe via one contact, letterbox mapping, all four buttons with hold times
- [ ] Device test: tap, long press, drag, swipe, buttons (NOT RUN)

## v0.5 — Networking

- [x] *Reconnect Guest Network* (`ipconfig set en0 DHCP` over the console), link status in overlay
- [ ] Automatic recovery on link drop (needs a device to observe the drop signature)

## v0.6 — Guest agent and file transfer

- [x] Console command framing (markers survive echo and kernel chatter), exit status, diagnosis
- [x] File transfer to the guest over slirp (`/dev/tcp/10.0.2.2`), cksum on both ends
- [ ] NetworkTransport interactive shell, pull from guest UI, console-only fallback transfer
- [ ] Device test (NOT RUN)

## v0.7 — IPA installation

- [x] IPA inspector: ZIP, `Payload/*.app`, Info.plist, Mach-O arches, FairPlay `cryptid`, minimum OS
- [x] Guest tar from the IPA, transfer, install steps (`mount -uw /`, `tar`, `chown/chmod`, `uicache`)
- [x] Distinct failures: invalid, encrypted, unsupported arch, newer iOS, guest offline, network
      down, disk full, step failure
- [ ] Device test (NOT RUN)

## v0.8 — VM manager

- [x] Create, clone, rename, delete, settings, export configuration (v0.1)
- [x] qcow2 v3 overlay per device (written by VirtualPhone, checked with `qemu-img check`/`qemu-io`
      on Linux: writes land in the overlay, the base image stays byte-identical)
- [x] Per-device copies of the guest's mutable state, created and reset together with the overlay
      (disk and SEP replay counters never diverge); relative backing path survives container moves
- [x] Config schema 2 with migration (existing devices keep booting the shared image)
- [ ] Snapshots (metadata, restore UI) — after overlays are proven on a device
- [ ] Device test: boot from an overlay, reset, clone (NOT RUN)

## v0.9 — Performance and stability

- docs/PERFORMANCE.md baselines vs. candidates on a named device; translator cache tuning; crash
  safety of VM data

## v1.0 — Stable

The Definition of Done list in the project brief, every item checked with evidence.
