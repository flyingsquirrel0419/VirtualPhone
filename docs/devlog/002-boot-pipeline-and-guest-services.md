# 002 — Boot pipeline, real-library tests, guest services (v0.2 → v0.7 groundwork)

## Goal

Everything of v0.2 (serial console, QMP, boot phases, kernel log) that can be built and verified
without a phone or Apple files, plus the parts of v0.4–v0.7 that do not depend on a running guest.

## What changed

- **Console and boot phases** (Core): `ConsoleBuffer` (lines split across reads, UTF-8 split
  across reads, ANSI/OSC stripping, capacity), `BootPhaseDetector` (poweredOn → iBoot → kernel →
  launchd → shell, panic from anywhere, warnings such as *Still waiting for root device*, time to
  each phase), `ConsoleLogTailer` (follows the chardev logfile, restarts when it is emptied).
- **QMP** (Core): codec on JSONDecoder (booleans vs numbers portable), synchronous client with
  greeting/negotiation, event collection, timeouts, over a POSIX `TCPConnection` that builds on
  Darwin and Glibc.
- **App**: `GuestConsole` (poll timer on a private queue, publish snapshots, input over the serial
  socket, QMP status), Console tab with input/follow/export, phase badge, overlay timings (phases,
  first frame), guest file status with sizes in settings; the mock runtime writes a fake boot log
  so the whole console path runs without a guest.
- **Real emulator on Linux**: `emulator/scripts/build-host.sh` builds the pinned fork as a shared
  library with clang (plus pinned Nettle and a PIC libyuv from `deps.lock`);
  `tests/emulator/run-real.sh` drives the real library through the bridge on an empty machine and
  checks every state change over QMP. New workflow `emulator-host.yml`.
- **Command-line guard**: `check_abi.py` now also verifies every option, t8030 machine property and
  device that `EmulatorArguments` emits exists in the pinned tree.
- **Guest services** (v0.5–v0.7 groundwork): shell quoting, POSIX `cksum`, `ShellFrame` markers,
  guest command builders, ustar `TarWriter`, IPA → guest tar, `FileTransferServer` for the guest's
  `/dev/tcp/10.0.2.2/PORT` callback, DEFLATE inflater, ZIP reader, IPA inspector; app-side
  `GuestShellSession` and `GuestServices` (reconnect network, send file, install IPA) with menu items.

## Tests

- Swift: 55 XCTests on Linux (was 27).
- Real library: `run-real.sh` PASS locally (Ubuntu 24.04, clang 18): capabilities 0x1ff, QMP
  `running` → `paused` → `running`, touch/button calls safe, framebuffer resize 640×480, stop →
  exit 0, destroy. CI: `emulator-host.yml` run 36227474271 PASS.
- IPA fixtures made by Python's zipfile/zlib (real DEFLATE encoder); tar checked with GNU tar,
  cksum with coreutils `cksum`.
- Physical device and guest: NOT RUN (boot phases, console input, QMP on a phone, network
  recovery, file transfer and IPA install all need a jailbroken guest image).

## Problems found and how they were solved

| Problem | Found by | Fix |
|---|---|---|
| Ubuntu's Nettle 3.9 < fork's `>= 3.10` | host build | build pinned Nettle 3.10.2 into a host prefix |
| `m4` missing for Nettle's assembler sources | host build | added to the host deps |
| libyuv (CMake subproject) static archive not PIC → cannot link into a `.so` | host build (meson) | patch 0002: prefer a pkg-config libyuv; host build provides a PIC one at the pinned commit |
| `qemu_build_not_reached()` compile errors with GCC and clang 18 (only Apple clang proves them dead) | host build | `-fno-inline` for the host build (turns them into runtime asserts) |
| `-nodefaults: invalid option` → `qemu_init` **exit()s the process** | real-library test | the fork trimmed QEMU's options; `check_abi.py` now checks every option the app passes |
| the fork removed QEMU's `none` machine | real-library test | host-only patch restores it; never applied to the iOS library |
| host patch carried the `.vp-patched` marker | CI (`git apply`) | hunk removed; `fetch.sh` refuses patches touching `.vp-*` |
| `fileImporter` clears `isPresented` before its completion | review | the chosen kind is kept in separate state |

## Findings

- **Touch is single-contact.** `hw/input/mt-spi.c` is driven by one QEMU mouse handler (one path,
  make/touching/break). Multi-touch needs the device to report several paths — an emulator patch,
  planned, not started.
- The fork's `mt-spi` hard-codes a y-axis calibration for a 1792-pixel panel.
- The guest bootstrap has no md5/shasum; `cksum` is the common checksum (Inferno-iOS finding).

## Remaining issues

- Kernel boot output on a real guest: NOT RUN (needs the user's guest image and a phone).
- Console-only file transfer (no network) is not implemented; operations say the network is down.
- No NetworkTransport shell yet (the `/dev/tcp` interactive shell); commands go over the console.
