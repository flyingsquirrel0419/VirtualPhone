# 001 — Bootstrap (v0.1)

## Goal

Private repository, Linux bootstrap, upstream survey and pins, CI on Linux and macOS, the
emulator built as an iOS library, a SwiftUI shell app, and an `.ipa` produced automatically as
an Actions artifact. Guest boot is not part of v0.1.

## What changed

- **Upstream decision.** Build the MakrSas/Inferno `ios` fork (ChefKiss Inferno turned into an
  in-process library, with display/input/NCM embed API) at a pinned SHA rather than patching
  ChefKiss master ourselves. Details and the runtime facts learned upstream: docs/UPSTREAM.md.
- **Toolchain.** `macos-26` + Xcode 26.6 pinned. Xcode 27 exists only as the `xcode-27` preview
  image in September 2026, so it is exercised by a non-blocking nightly job instead of gating.
- **Runtime bridge** `app/Runtime/vp_runtime.{h,c}`: the only emulator surface Swift sees.
  Resolves symbols by name, owns the emulator thread and a state machine, reports capabilities.
- **VirtualPhoneCore**: all logic that does not need UIKit, built and tested on Linux.
- **App**: device library, settings, running screen, diagnostics, JIT probe, mock runtime.
- **Pipeline**: linux-ci, ios-build (reusable), release (clean build + gate), nightly,
  dependency-check; forbidden-file/secret scanner, IPA verifier, SBOM, release notes.

## Tests

- Python: 22 tests (lockfile policy, IPA verifier, forbidden scanner incl. the repository itself).
- Swift core: 27 XCTests on Linux (config/migration, packages, argv, coordinates, JIT decision,
  logging, semver).
- C bridge: 4 scenarios against `tests/emulator/mock_qemu.c` with gcc+ASan/UBSan,
  clang+ASan/UBSan, and clang+TSan repeated 100×.
- ABI: `tools/deps/check_abi.py` checks 23 declarations of the pinned emulator against the
  bridge's mirror header.
- Physical device: NOT RUN.

## Problems found and how they were solved

| Problem | Found by | Fix |
|---|---|---|
| Foundation `replaceItemAt` fails on Linux | Swift tests | atomic save via `rename(2)` |
| `"1.2.3-"` parsed as valid semver | Swift tests | keep empty split components |
| Calls through function pointers typed differently from the callee (UB) | clang `-fsanitize=function` | `vp_inferno_abi.h` mirrors the emulator's exact types; CI checks them |
| `wait()` could return before `STOPPED` was published → `destroy()` refused; then (first fix) before the STOPPED callback ran | clang and TSan runs in CI (flaky) | publish STOPPED → deliver callback → signal `done`; 400× stress under TSan and ASan |
| ChefKiss master's `RunState.paused` is 4, the fork's 3 | ABI checker | documented; the checker blocks a silent change on update |
| bash 3.2 on macOS runners has no associative arrays | review | awk lookup in build-ios-deps.sh |
| First push to a new repo does not trigger path-filtered workflows | CI | manual dispatch for the first run |
| `xcodebuild -version \| head -1` aborts xcodebuild with SIGPIPE under pipefail | macOS CI (runner/tool) | read the whole output (`awk 'NR==1'`) |
| `nm \| grep -q` export check could SIGPIPE under pipefail | review | list exports once, grep a here-string |
| meson: `Unable to find CMake` in `hw/display` (libyuv, added to the fork 2026-09-17) | macOS CI (dependency) | cmake in bootstrap + `[cmake]` iOS toolchain section in the cross-file |
| fork's `libyuv.wrap`/`mlib.wrap` track `main`/`master` (not reproducible) | same investigation | patch 0001 pins both; fetch.sh rejects unpinned wraps |
| dylib link: `_libucontext_*` undefined — clang++ links (libyuv is C++) and `cpp_link_args` lacked `-lucontext` | macOS CI (linker) | C++ link args mirror the C ones; clean retry only after a cache hit |
| meson: `Dependency "liblz4" not found` (hw/usb, fork 2026-09-18) | macOS CI (dependency) | LZ4 1.10.0 added to deps.lock and the dependency build; all `required: true` deps of the fork audited — none other missing |

## Result

First green iOS Build: run 36224154220 on commit `ef5424b`. Linux gate (4 jobs) green; macOS:
dependency prefix from cache (built from checksummed tarballs in an earlier run), emulator built
from scratch (cache miss, 1044 ninja steps), app compiled, IPA verified and scanned in CI and
again on Linux after download (`sha256sum -c`, `verify_ipa.py --require-emulator
--require-signature`, `forbidden_scan.py archive`, all 18 bridge symbols exported).
Environment: `macos-26-arm64` 20260907, Xcode 26.6, iOS SDK 26.5, Swift 6.3.3.

Release pipeline exercised with the prerelease tag `v0.1.0-alpha.1` (run 36224493841): tag/VERSION/
CHANGELOG check, Linux gate, macOS build with **no caches** (dependencies and emulator from
scratch), release gate, GitHub prerelease with `VirtualPhone-v0.1.0-alpha.1.ipa`, `SHA256SUMS`,
`SBOM.spdx.json` — re-verified after download.

## Remaining issues

- Guest boot untested (v0.2). The argv follows Inferno-iOS; our own boot verification is next.
- No app icon. CGImage-per-frame display (Metal later, once measured).
- macOS minutes on a private repo are billed at a multiple; caches and path filters keep runs rare.

## Benchmark changes

None measured (no device run).
