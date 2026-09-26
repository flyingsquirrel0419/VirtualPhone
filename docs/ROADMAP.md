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
- [ ] CI builds the Inferno dylib and an IPA artifact on the pinned runner  ← verified by the first CI run
- [ ] Physical device: app launches, JIT detected, mock runtime renders (NOT RUN)

## v0.2 — T8030 boot pipeline

Goal: kernel boot output captured.
- Serial console reader (TCP chardev → log view, `guest-console.log` tail in the app)
- QMP client for state queries (`query-status`), clean quit so disks are flushed
- Boot phases in the UI: iBoot → XNU → launchd, from console markers
- Guest file readiness screen with per-file status and sizes
- Device test: kernel log reaches `launchd` on a phone

## v0.3 — SpringBoard

- First frame timing, boot-time metrics (time to Apple logo, to SpringBoard)
- Framebuffer → Metal layer path (replace per-frame CGImage) once measured
- Device test: SpringBoard visible on a phone

## v0.4 — Touch and buttons

- Multi-touch investigation (the embed API is single-touch today)
- Side-button long press, ringer toggle, rotation API stub
- Device test: tap, long press, drag, swipe, all four buttons

## v0.5 — Networking

- NCM link status in the UI, *Reconnect guest network* (`ipconfig set en0 DHCP`), auto-recovery
  on link drop

## v0.6 — Guest agent and file transfer

- `GuestTransport` with `ConsoleTransport` and `NetworkTransport`, fallback between them
- Shell, push/pull with checksums, status, time and battery sync

## v0.7 — IPA installation

- IPA inspector (ZIP central directory, `Payload/*.app`, arch, FairPlay `cryptid`), transfer,
  install, SpringBoard refresh; distinct errors for invalid/encrypted/unsupported/offline/disk full

## v0.8 — VM manager

- qcow2 overlays per device (never write the user's base image), snapshot metadata, restore UI

## v0.9 — Performance and stability

- docs/PERFORMANCE.md baselines vs. candidates on a named device; translator cache tuning; crash
  safety of VM data

## v1.0 — Stable

The Definition of Done list in the project brief, every item checked with evidence.
