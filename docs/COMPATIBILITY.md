# Compatibility

| | Supported | Notes |
|---|---|---|
| Virtual device | iPhone 11 (`t8030`, A13) | the only machine; panel presets are render sizes |
| Guest OS | iOS 14.x | per ChefKiss Inferno; newer versions stop in dyld upstream |
| Host OS | iOS / iPadOS 16.0+ | deployment target |
| Host hardware | arm64 iPhone/iPad | more RAM helps; iOS caps an app near 3 GB |
| Accelerator | TCG (multi-threaded) + JIT | no hypervisor for apps on iOS |
| Build | `macos-26-arm64` image 20260907 (macOS 26.6.2), Xcode 26.6, iOS SDK 26.5, Swift 6.3.3 | pinned in deps.lock; Xcode 27 preview checked nightly |

## Input

One touch contact at a time: the emulated multitouch panel is driven by a single pointer
(`hw/input/mt-spi.c`). Pinch and other multi-finger gestures are not available yet.

## Physical device results

| Test | Result |
|---|---|
| App launches | NOT RUN |
| JIT detection | NOT RUN |
| Mock runtime renders, touch/buttons reach it | NOT RUN |
| Inferno initialises / kernel boots / SpringBoard | NOT RUN |
| Console, boot phases, QMP on a phone | NOT RUN |
| Network recovery, file transfer, IPA install | NOT RUN |

## Simulator results

| Test | Result |
|---|---|
| App launch, demo device, mock boot, first frame, console boot phases, no crash (`scripts/sim-smoke.sh`) | PASS (iPhone 17 Pro simulator, iOS 26, run 36239072646) |

## Host (Linux) results

| Test | Result |
|---|---|
| Bridge against the real Inferno library (`tests/emulator/run-real.sh`, empty machine) | PASS locally and in CI (`emulator-host.yml` run 36227474271, ubuntu-24.04, clang 18) |

Report results with the device model, host iOS version, build commit and diagnostics.zip.
