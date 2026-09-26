# 003 — Overlays, transports, battery, icon, 0.2.0-alpha

## Goal

Finish what v0.6–v0.8 need that does not depend on a running guest, and ship an alpha a
tester can install on a phone.

## What changed

- **qcow2 overlays** (`QCOW2Overlay`, `DeviceState`): each new device boots from its own overlay
  with a relative backing path, plus per-device copies of the guest's mutable files; reset removes
  both together. Config schema 2 (`protectBaseImage`), migrated devices keep the old behaviour.
- **Transports**: `TCPListener`; `NetworkShellTransport` (guest bash on a socket through slirp);
  `FallbackTransport` (network first, console otherwise). `GuestServices` uses it for every
  command, and gained *Fetch File from Guest*.
- **Battery**: the phone's level and charging state go to the guest's SMC through the bridge.
- **Unclean shutdown**: `state/running` marker; a device whose marker survived is flagged.
- **Icon**: original artwork rendered by `tools/icon/make_icon.py`, compiled by actool.

## Tests

- Swift: 62 on Linux. The overlay is checked with `qemu-img check/info` and written through with
  `qemu-io` (base image byte-identical afterwards) — locally and in the Linux CI container.
- The network shell is tested against a real bash connecting back over `/dev/tcp`.
- Physical device and guest: NOT RUN.

## Decisions

- New devices protect the base image by default: a broken overlay fails to boot but cannot damage
  the user's image, the safer failure. Existing devices are not switched silently.
- 0.2.0 is published as `v0.2.0-alpha.1` (prerelease): its milestone criterion — a kernel log on a
  phone — has not been observed.
