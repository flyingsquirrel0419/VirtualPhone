# Roadmap

Priorities: real iOS boot > stable runtime > usable controls > VM management > performance >
polish. A milestone is done when its criteria are met **on a physical device** where stated;
results that need a phone are recorded as NOT RUN until someone runs them.

## v0.1 — Bootstrap (done)

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
- [x] Metal renderer (opt-in, `-VPRenderer metal` / setting); default stays Core Graphics until measured on a device
- [ ] Device test: SpringBoard visible on a phone (NOT RUN)

## v0.4 — Touch and buttons

- [x] Investigation: the emulated panel (`hw/input/mt-spi.c`) takes one contact — multi-touch needs
      an emulator patch reporting several paths (not started)
- [x] Tap/long-press/drag/swipe via one contact, letterbox mapping, all four buttons with hold times
- [ ] Device test: tap, long press, drag, swipe, buttons (NOT RUN)

## v0.5 — Networking

- [x] *Reconnect Guest Network* (`ipconfig set en0 DHCP` over the console), link status in overlay
- [x] Automatic recovery: a console-side reachability check every minute re-requests an address

## v0.6 — Guest agent and file transfer

- [x] Console command framing (markers survive echo and kernel chatter), exit status, diagnosis
- [x] File transfer to the guest over slirp (`/dev/tcp/10.0.2.2`), cksum on both ends
- [x] Network shell transport (guest bash on a socket via `/dev/tcp`), console fallback;
      tested against a real bash calling back
- [x] Fetch files from the guest (cksum-checked); host battery → guest SMC
- [x] Time zone sync (phone's zone, once per boot)
- [ ] Console-only file transfer when the guest has no network (not implemented)
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
- [x] Snapshots: overlay + state copies saved/restored together, Settings UI (iOS compile not yet
      verified: CI blocked by billing, see devlog 004)
- [ ] Device test: boot from an overlay, reset, clone (NOT RUN)

## v0.9 — Performance and stability

- [x] Two independent review rounds; 26 findings fixed (races, leaks, retries, data safety)
- [x] In-app self-test on the iOS runtime; simulator smoke test in CI
- [x] Host CPU/RAM, FPS, frame counters, phase timings in the overlay
- [ ] Baselines on a named device (docs/PERFORMANCE.md) — NOT RUN

- docs/PERFORMANCE.md baselines vs. candidates on a named device; translator cache tuning; crash
  safety of VM data

## v1.0 — Definition of Done

Status of every item of the project brief's 1.0 checklist. "NOT RUN" means it needs a physical
iPhone with JIT and the user's own guest image; nothing here claims otherwise. 1.0.0 ships as
`v1.0.0-beta.N` until those items are observed; `v1.0.0` is tagged from the same code afterwards.

| Item | Status | Evidence |
|---|---|---|
| Linux clean bootstrap works | done | `scripts/bootstrap-linux.sh`, `scripts/lint.sh` |
| GitHub repository configured | done | public repo, branches main/dev, 6 workflows |
| CI green | done | Linux CI, iOS Build, Simulator smoke, Emulator host test |
| macOS clean build works | done | release builds use no caches |
| IPA generated automatically | done | `ios-build.yml` artifact on every main build |
| Release workflow works | done | v0.1.0-alpha.1, v0.2.0-alpha.1/2 |
| App launches on supported physical iPhone | NOT RUN | launches in the iOS Simulator (smoke test) |
| JIT availability is detected | NOT RUN on device | probe runs in the simulator self-test |
| Virtual T8030 initializes | NOT RUN | real library initialises on Linux (`none` machine); t8030 needs Apple files |
| iOS 14.x guest boots | NOT RUN | console/phase pipeline tested with the mock |
| SpringBoard renders | NOT RUN | framebuffer path (CG and Metal) tested with the mock |
| Touch works | NOT RUN | mapping unit-tested; single contact only (emulator limit) |
| Side/home/volume buttons work | NOT RUN | F-key mapping tested against mock and real library |
| Guest networking works | NOT RUN | recovery commands + auto-recovery implemented |
| Guest shell works | NOT RUN | console framing + network shell tested against real bash |
| Host → guest file transfer works | NOT RUN | transfer server + cksum tested (Linux, simulator self-test) |
| IPA install works for compatible IPA | NOT RUN | inspector, guest tar, install steps tested with fixtures |
| VM configuration persists | done | schema 2 + migration, atomic saves (tests) |
| Multiple VM configs supported | done | library, create/clone/rename/delete (tests, self-test) |
| Clone works | done | package clone incl. overlay state (tests, self-test) |
| Diagnostics work | done in simulator | diagnostics.zip export; not exercised on a device |
| Crash does not silently destroy VM data | done | atomic writes, staged snapshots, unclean-shutdown marker, overlays |
| Proprietary Apple files are not distributed | done | forbidden-file scan on tree, full history and every IPA |
| Third-party licenses documented | done | THIRD_PARTY_NOTICES.md, SBOM per release |
| GitHub Release contains valid IPA | done | verified after download for each release |
| SHA256 published | done | SHA256SUMS per release |
| README installation instructions verified | NOT RUN | needs a sideload onto a phone |
