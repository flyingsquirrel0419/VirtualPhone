# Compatibility

| | Supported | Notes |
|---|---|---|
| Virtual device | iPhone 11 (`t8030`, A13) | the only machine; panel presets are render sizes |
| Guest OS | iOS 14.x | per ChefKiss Inferno; newer versions stop in dyld upstream |
| Host OS | iOS / iPadOS 16.0+ | deployment target |
| Host hardware | arm64 iPhone/iPad | more RAM helps; iOS caps an app near 3 GB |
| Accelerator | TCG (multi-threaded) + JIT | no hypervisor for apps on iOS |
| Build | macOS 26 runner, Xcode 26.6, iOS SDK 26.x | pinned in deps.lock; Xcode 27 preview checked nightly |

## Physical device results

| Test | Result |
|---|---|
| App launches | NOT RUN |
| JIT detection | NOT RUN |
| Mock runtime renders, touch/buttons reach it | NOT RUN |
| Inferno initialises / kernel boots / SpringBoard | NOT RUN |

Report results with the device model, host iOS version, build commit and diagnostics.zip.
