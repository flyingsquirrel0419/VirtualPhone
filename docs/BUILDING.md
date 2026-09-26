# Building

Linux is the primary development environment. Only the steps that need Apple's SDK run on
macOS — in CI on GitHub's `macos-26` runner with Xcode 26.6 (pinned in `deps.lock`).

## Linux

```bash
scripts/bootstrap-linux.sh     # shellcheck, clang-format, build tools; checks gh auth
scripts/lint.sh                # everything Linux CI runs
```

`scripts/lint.sh` runs: shellcheck, workflow policy, `deps.lock` validation, the forbidden-file and
secret scan, clang-format, documentation links, Python unit tests, the runtime bridge against the
mock emulator (ASan/UBSan), and `swift test` when Swift is installed.

Useful pieces on their own:

```bash
swift test                                    # VirtualPhoneCore
tests/emulator/run.sh                         # C bridge (CC=clang for clang)
emulator/scripts/fetch.sh /tmp/inferno        # pinned emulator + patches
python3 tools/deps/check_abi.py /tmp/inferno  # bridge ABI vs pinned emulator
python3 tools/ipa/verify_ipa.py X.ipa --require-emulator --require-signature
python3 tools/release/forbidden_scan.py archive X.ipa
```

## macOS (CI or a Mac)

```bash
scripts/bootstrap-macos.sh     # selects the pinned Xcode, installs meson ninja pkg-config autotools qemu
scripts/build-ios.sh           # fetch emulator → iOS deps → dylib → app → dist/VirtualPhone-<ver>.ipa
```

Stages, each runnable alone:

| Step | Script | Output |
|---|---|---|
| Emulator source | `emulator/scripts/fetch.sh` | `emulator/src` at the pinned SHA, patches applied |
| iOS dependencies | `emulator/scripts/build-ios-deps.sh` | `prefix/` (static libs), stamped with the `deps.lock` hash |
| Emulator library | `emulator/scripts/build-ios.sh` | `build/emulator/libqemu-aarch64-softmmu.dylib`, exports checked |
| App | `app/build.sh` | `dist/VirtualPhone-<ver>.ipa`, verified and scanned |

`REQUIRE_EMULATOR=0 app/build.sh` builds a UI-only IPA (mock runtime) in about a minute — handy
for UI work and used for the non-blocking Xcode 27 preview job.

App build environment: `PRODUCT_NAME`, `BUNDLE_ID` (default `dev.virtualphone.app`), `CHANNEL`,
`BUILD_NUMBER`, `EMULATOR_DYLIB`, `QEMU_KEYMAPS`, `OUT_DIR`. No Xcode project: `swiftc` compiles
`app/Sources/Core` and `app/Sources/App` into one module with the C bridge linked in.

## CI

| Workflow | When | What |
|---|---|---|
| `linux-ci.yml` | every push and PR | lint, policy, scans, unit tests, bridge tests, Swift tests, emulator pin/patch/ABI check |
| `ios-build.yml` | push to `main` (app/emulator paths), `v*-rc*` tags, manual | Linux CI, then macOS build → `VirtualPhone-<sha>` artifact (IPA + SHA256SUMS) |
| `release.yml` | tag `vX.Y.Z[-alpha.N/-beta.N]` | tag/VERSION/CHANGELOG check, clean macOS build without caches, release gate, GitHub Release |
| `nightly.yml` | daily if `main` changed | nightly artifact (never a Release), Xcode 27 preview UI build (non-blocking) |
| `dependency-check.yml` | weekly, on `deps.lock` PRs | pinned tarballs still match; upstream drift report |

Caches: the dependency prefix is keyed on macOS major, Xcode version, the `deps.lock` hash and the
deps script; the emulator build tree on Xcode, emulator commit, lock hash and patches. A build that
fails on a cached emulator tree retries clean. Releases never use caches.

macOS runner minutes are billed at a multiple on private repositories, which is why macOS jobs do
not run on PRs and why both caches exist.
