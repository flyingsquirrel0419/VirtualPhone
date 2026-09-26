# VirtualPhone

**A virtual iPhone 11 that boots a real iOS 14 guest — inside an app on your iPhone.**

VirtualPhone is not app virtualization and not a fake home screen. It runs an emulated Apple
T8030 (A13) machine — iBoot, XNU, launchd, SpringBoard — through
[Inferno](https://github.com/ChefKissInc/Inferno), a QEMU fork, loaded as a library into the app.

> Unofficial. Not affiliated with Apple, ChefKiss or the Inferno-iOS project.
> **No Apple firmware, IPSW, kernel or key is included** in this repository or its releases —
> you prepare the guest from your own sources.

## Current status: v0.1 (bootstrap)

| Milestone | State |
|---|---|
| App launches, VM manager, mock runtime | built in CI; physical-device test **not run** |
| Inferno library built and bundled | built in CI |
| Console, boot phases, QMP; bridge driven against the real Inferno library on Linux | done; phone test **not run** |
| Guest boot / SpringBoard on a phone | not yet verified (needs your guest image) |
| Touch (single contact), buttons, network recovery, file transfer, IPA install | implemented; phone test **not run** |
| Per-device qcow2 overlays (base image never written), reset, clone | implemented; phone test **not run** |

See [docs/ROADMAP.md](docs/ROADMAP.md) and [CHANGELOG.md](CHANGELOG.md).

## Supported

- **Virtual device:** iPhone 11 (T8030/A13), arm64 — only this model.
- **Guest:** iOS 14.x, jailbroken per ChefKiss's Inferno guides.
- **Host:** a modern arm64 iPhone or iPad on iOS 16 or later, with JIT enabled.
- **Panel presets:** iPhone 11 (828×1792), iPhone 8 (752×1336), iPhone SE (640×1136) — render
  sizes of the same iPhone 11 machine, not different hardware.

## Requirements

1. **JIT.** The emulator translates guest code at runtime, which iOS allows only while a debugger
   is attached or with a JIT entitlement. Launch VirtualPhone through a JIT enabler
   (StikDebug-compatible, SideStore-compatible, or an external debugger). The app detects JIT and
   refuses to boot without it rather than hanging. Details: [docs/JIT.md](docs/JIT.md).
2. **Guest files** built from your own IPSW following ChefKiss's guide, plus the jailbreak
   bootstrap. About 9 GB free. Details: [docs/GUEST_IMAGE.md](docs/GUEST_IMAGE.md).
3. **A sideloading tool** that re-signs the `.ipa` (AltStore, SideStore, Sideloadly, …).

## Install

1. Download `VirtualPhone-vX.Y.Z.ipa` and `SHA256SUMS` from Releases (or a CI artifact), and check
   it: `sha256sum -c SHA256SUMS`.
2. Install it with your sideloading tool; it re-signs the ad-hoc signed bundle.
3. Launch it through your JIT enabler. The header shows **JIT enabled** when it worked.

## Create and boot a device

1. **Create** → name it, pick a panel preset.
2. Copy your guest files into *Files → On My iPhone → VirtualPhone → InfernoData* (the folder
   exists after first launch), and `AppleSEPROM-Cebu-B1` next to it. Adjust paths in the device's
   **Settings → Guest files** if yours differ (the trust cache is named after your iOS build).
3. Tap **▶**. If anything is missing — JIT, a file, the emulator library — the app lists it and
   offers the **mock runtime** instead, which boots a test pattern for checking the UI.
4. Running screen: guest display, **Home / Side / Vol+ / Vol−** bar (long-press Side for the
   power-off slider), menu with pause, restart, stop, fullscreen (triple-tap to leave) and a debug
   overlay.

One machine per app launch: QEMU cannot be started twice in one process, so relaunch the app to
boot again.

The **Console** tab shows the guest's serial console with boot phases (iBoot → kernel → launchd →
shell) and lets you type into it. Once the bootstrap's shell is up, the menu offers **Reconnect
Guest Network**, **Send File to Guest…** and **Install IPA…** (checked first: FairPlay-encrypted,
non-arm64 or too-new apps are refused with the reason). New devices boot from their own qcow2
overlay, so your prepared image is never written; *Reset Device State* returns a device to it.

## Known limitations

JIT required · slow boot (minutes) · high RAM use, iOS caps the app near 3 GB · iPhone 11/T8030
only · limited guest iOS versions (14.x) · audio experimental and off by default · no camera,
cellular or Bluetooth · FairPlay-encrypted App Store apps do not run · not every IPA is
compatible · network can drop and needs recovery · one boot per app launch · one touch contact at a time (no pinch yet).

**Performance expectations:** everything is translated (no hypervisor on iOS). Upstream measured
8–11 fps with a 64 MB translation cache and 21–25 fps with 256 MB on a phone. VirtualPhone's own
numbers will be in [docs/PERFORMANCE.md](docs/PERFORMANCE.md) once measured on a device.

## Troubleshooting

- *JIT unavailable* — relaunch through the JIT enabler, then pull to refresh or tap **Check**.
- *Missing guest files* — the alert names each one; a folder or empty file with the right name
  counts as missing (QEMU would otherwise exit and take the app down).
- *The app closed while starting* — read `Logs/app.prev.log` in Files; export
  **Diagnostics → diagnostics.zip** for a bug report (logs and configs only, paths redacted).
- More: [docs/DEBUGGING.md](docs/DEBUGGING.md).

## Building

Linux is the development host; the iOS build runs on GitHub's macOS runners (pinned macOS 26 +
Xcode 26.6). See [docs/BUILDING.md](docs/BUILDING.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License and credits

VirtualPhone is GPL-3.0-or-later ([LICENSE](LICENSE)). The bundled emulator is GPL-3.0 with
AGPL-3.0 parts; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for every component and what
distribution requires.

Inferno is by Visual Ehrmanntraut and the Inferno team at ChefKiss — consider
[supporting them](https://ko-fi.com/chefkiss). The iOS library fork and much of what is known
about running it on a phone come from [MakrSas/Inferno-iOS](https://github.com/MakrSas/Inferno-iOS).
QEMU is the work of very many people.
