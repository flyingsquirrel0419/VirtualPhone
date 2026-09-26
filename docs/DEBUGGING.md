# Debugging

## Logs

- `Documents/Logs/app.log` — this run, `[HH:MM:SS.mmm][CATEGORY][LEVEL] message`, categories
  APP VM QEMU BOOT DISPLAY INPUT JIT NETWORK GUEST IPA STORAGE. The emulator's full argv is
  logged at start under QEMU.
- `Documents/Logs/app.prev.log` — the previous run; read it after a crash or a `qemu_init` exit.
- `Devices/<name>.vphone/logs/guest-console.log` — the guest's serial console (iBoot, XNU).
- **Diagnostics → Export** writes `diagnostics.zip`: those logs (container path redacted),
  device configs, host/JIT summary. No guest files.

## Without a phone

- UI: start any device with **Start demo (mock runtime)**, or build UI-only with
  `REQUIRE_EMULATOR=0 app/build.sh`.
- Bridge: `tests/emulator/run.sh` drives the real `vp_runtime.c` against a mock emulator.
- Command line: `EmulatorArguments` is unit-tested; the argv the phone would use can be printed
  from a test.

## Common failures

| Symptom | Likely cause |
|---|---|
| App disappears right after Start | `qemu_init` called `exit()` — file missing/empty/a folder, or an option the build does not know. See `app.prev.log`. |
| Hangs on first boot with no console output | JIT not actually usable; re-check the badge, try another provider |
| "Start: this process already ran a machine" | QEMU cannot run twice per process: relaunch the app |
| Emulator library missing | UI-only build; use a CI artifact from `ios-build.yml` |
| Guest never finishes boot at a custom width | framebuffer row not a multiple of 16 bytes — use a preset |

## CI failures

Classify before re-running (source, dependency, runner image, Xcode, cache, network, upstream,
signing, linker, test). The build summary lists macOS, Xcode, SDK and emulator commit. A failed
emulator build on a cached tree is retried clean automatically; a checksum mismatch in
`build-ios-deps.sh` means an upstream tarball changed — investigate, do not just update the hash.
