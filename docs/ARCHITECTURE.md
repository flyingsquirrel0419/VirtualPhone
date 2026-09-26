# Architecture

```
VirtualPhone.app (one process)
├── SwiftUI: Library → Machine / Settings / Diagnostics        main thread
├── EmulatorController (per running machine)
│     ├── display pump thread: framebuffer → CGImage            "virtualphone.display"
│     └── input: CoordinateMapper → touch / buttons
├── EmulatorRuntime protocol
│     ├── InfernoRuntime ──► C bridge app/Runtime/vp_runtime.c
│     │                        └── dlopen Frameworks/libqemu-aarch64-softmmu.dylib
│     │                              emulator thread: qemu_init → qemu_main_loop → qemu_cleanup
│     └── MockEmulatorRuntime (test pattern, no JIT or guest needed)
└── VirtualPhoneCore (pure Swift, also built and tested on Linux)
      MachineConfiguration · VMPackage · GuestFiles/FirmwareLinks · EmulatorArguments
      CoordinateMapper · DisplayPreset · JITStatus/JITProbe · LogLine · BuildMetadata
```

## Layers and rules

**VirtualPhoneCore** (`app/Sources/Core`) holds every decision that can be made without a phone:
configuration schema and migration, the `.vphone` package format, which guest files are needed and
whether they are usable, the exact emulator command line, touch coordinate mapping, JIT decision
logic, log formatting, version parsing. It imports Foundation only (Linux CI enforces this) and is
a SwiftPM library tested with `swift test`. The app compiles the same files into its own module.

**The C bridge** (`app/Runtime/vp_runtime.h`) is the only surface the app uses to drive the
emulator: `vp_emulator_create/start/pause/resume/reset/stop/wait/destroy`, `set_touch`,
`button_event`, `set_battery`, `framebuffer`, `get_metrics`, `capabilities`. Behind it,
`vp_runtime.c` resolves QEMU and Inferno symbols by name, types every call exactly as the emulator
declares it (`vp_inferno_abi.h`, checked against the pinned tree by `tools/deps/check_abi.py`),
owns the emulator thread, and keeps a state machine
(`idle → starting → running ⇄ paused → stopping → stopped`, or `failed`). Optional features are
reported as capability bits, so an emulator build without, say, pause support degrades instead of
crashing. Swift never sees a QEMU structure.

The bridge is tested on Linux against `tests/emulator/mock_qemu.c`, a stand-in library exporting
the same symbols, under ASan and UBSan with gcc and clang.

**The app** (`app/Sources/App`) is SwiftUI for iOS 16+. `AppModel` lists packages, probes JIT on
every activation (a debugger may attach after launch), and decides readiness before any QEMU call
— because `qemu_init` calls `exit()` on a bad command line, nothing reaches it unvalidated.

## Threads

| Thread | Runs | Never |
|---|---|---|
| main | SwiftUI, published state | waits on the emulator |
| `vp_runtime` emulator thread (8 MB stack) | `qemu_init`, display attach (BQL held), `qemu_main_loop`, `qemu_cleanup`, BQL release | touches UI |
| display pump | `vp_emulator_framebuffer` → one copy into a `CGImage` → main | holds the BQL |
| QEMU's own vCPU/IO threads | guest | — |

Pause uses QEMU's cross-thread vmstop request; resume takes the BQL around `vm_start`; stop and
reset are QEMU's request flags. All are safe from the main thread.

## Display and input

The emulator keeps a damage-tracked copy of console 0; `inferno_display_read` copies changed rows
into the app's buffer (a8r8g8b8). v0.1 wraps each frame in a `CGImage`. A Metal path replaces this
once boot works and frame rate matters (see ROADMAP). Touches are aspect-fit mapped to absolute
guest pixels; a drag that leaves the picture is pinned to its edge. Buttons map to the machine's
F-keys inside the bridge (`vp_button_function_key`).

## Storage

```
Documents/
├── Devices/<Name>.vphone/   config.json, firmware-links.json, disks/ nvram/ state/ logs/ snapshots/
├── InfernoData/             the user's guest files (never copied into a package)
├── AppleSEPROM-Cebu-B1
└── Logs/app.log, app.prev.log
```

`config.json` has a `schema`; older schemas migrate on load, newer ones are refused. Saves are
write-temp-then-`rename(2)`. Unreadable packages are listed as broken rather than hidden. The
emulator's working directory is the package's `state/`, so the USB socket gets a short relative
path (AF_UNIX paths are limited to 104 bytes).

## Extension points

- `EmulatorRuntime` — another backend (e.g. an out-of-process emulator) plugs in here.
- `JITProvider` — instructions per JIT enabler; detection is provider-independent.
- `GuestTransport` (v0.6) — console and network channels to the guest agent.
- `RuntimeButton` / `vp_button` — mute, lock and rotation can be added without changing callers.
