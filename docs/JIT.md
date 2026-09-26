# JIT

## Why the emulator needs it

There is no hypervisor for apps on iOS, so every guest instruction is translated. QEMU's TCG
translates guest arm64 blocks into host arm64 code at runtime and jumps into it. That needs memory
the process can write and then execute.

## What iOS allows

A normal app cannot make memory executable. Two exceptions exist:

1. **`MAP_JIT`** — granted to processes with the JIT entitlement (not available to sideloaded
   apps signed with a free or ordinary developer certificate), and often to debugged processes.
2. **A debugger attached** — the kernel lets a traced process change page protections, which is
   what debuggers need to patch code. `mprotect(RW → RX)` succeeds.

VirtualPhone signs with `get-task-allow` so a debugger may attach.

## How TCG uses it

- `MAP_JIT` available → one RWX translation buffer (`tb-size=N`).
- Only `mprotect` available → the buffer is mapped twice, one writable view and one executable
  view (`split-wx=on`). This is the usual case with StikDebug-style enablers.

The app probes both on every activation (a debugger usually attaches after launch) and passes
`split-wx=on` when needed. Without either, starting would wedge on the first translated block —
it looks like a hang, not an error — so the app refuses and says why.

## States shown in the app

| State | Meaning |
|---|---|
| JIT unavailable | no debugger, no MAP_JIT, no RX permission change |
| JIT requesting | a provider was asked and has not answered yet (reserved for provider integrations) |
| JIT enabled | MAP_JIT or split-wx works; the method is shown |
| JIT verification failed | a debugger is attached but executable memory is still refused, or generated code did not run |

## Providers

VirtualPhone does not depend on one tool. `JITProvider` implementations only carry instructions;
detection is the same for all.

- **StikDebug-compatible**: launch VirtualPhone from the tool with its loopback VPN and your
  pairing file configured; assign its legacy script if it asks.
- **SideStore-compatible**: use the tool's *Enable JIT* on VirtualPhone, then return to the app.
- **External debugger**: Xcode or `lldb` attached over a pairing record.

## Troubleshooting

- Still *unavailable* after enabling: switch back to VirtualPhone, pull down on the device list or
  tap **Check**; the probe re-runs.
- *Verification failed*: the enabler attached but the kernel refuses protection changes — update
  the enabler, reboot the phone, or try another provider.
- The translation cache (Settings → Translator cache) counts against the ~3 GB process limit
  together with guest RAM.
