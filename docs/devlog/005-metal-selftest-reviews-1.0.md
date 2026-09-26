# 005 — Metal, in-app self-test, two review rounds, 1.0.0 beta

## What changed

- Metal renderer (opt-in via `-VPRenderer metal` or the setting): three textures, uploads only
  into one the GPU is not sampling, aspect-fit identical to `CoordinateMapper`. Core Graphics
  stays the default until a device measurement says otherwise.
- `-VPSelfTest YES` runs seven checks inside the iOS process (JIT probe, transfer round trip with
  POSIX cksum, TCP listener, console tailer, overlay/state/snapshot/clone, Metal upload, QMP codec).
  The simulator smoke test runs it after the screen, console and Metal launches.
- Background upkeep once the guest shell is up: time zone from the phone, a console-side
  reachability check that re-requests an address when the guest network is gone.
- Ring/silent switch (F2), host CPU in the overlay, the running machine owned by `AppModel` with a
  banner back to it.

## Reviews

Two independent review passes produced 26 findings; all are fixed (c7482ad, f56b6f7). The ones
that mattered most: pause/resume/stop racing on the bridge (now one `control` mutex, lock order
control → BQL → state lock, TSan-clean), a failed start that left the QEMU thread behind,
retries after a timeout that could run a command twice, a network shell that stayed dead after
the guest lost its network, and fetch/restore paths that could lose a file on failure.

## Bug found after the reviews

The second-round Metal change left `draw(in:)` taking its non-recursive lock twice: the first
draw would hang the main thread. CI passed anyway because the smoke test only read controller
logs ("First frame after" is logged before drawing). Fixed in dcfdfda; the renderer now logs its
first completed draw and the smoke test requires that line.

A third review pass (c7482ad..dcfdfda) confirmed the round-2 fixes and found two more:
- With all three Metal textures busy, `upload` dropped the frame, and the emulator reports a
  frame only once, so a screen that then went static kept showing the frame before. `upload` now
  says whether it took the frame and the display pump offers a declined one again.
- Upkeep treated a console that did not answer within 20 s as "network down" and reset the
  guest's network each minute under load. Only a ping that ran and failed triggers recovery now.

## Results

- Linux: lint, 64 Swift tests, Python tests, bridge tests under ASan/UBSan/TSan (0 reports),
  real-library bridge test — PASS.
- macOS CI: iOS build, IPA verification, simulator smoke — see the run for the tagged commit.
- Physical device: **NOT RUN**. Guest boot: **NOT RUN** (needs the user's own Apple files).

## Release

`v1.0.0-beta.1` is a prerelease. `v1.0.0` is tagged only once the device items of the checklist
in docs/ROADMAP.md have been observed on a phone.
