# Contributing

## Flow

`feature/*` or `fix/*` branch → PR → Linux CI green → merge to `main` (runs the macOS build) →
tag `vX.Y.Z` to release. `dev` may be used directly during bootstrap. Never start a large feature
while CI is red.

Before pushing: `scripts/lint.sh`.

## Commits

Small, with a scope: `build: add Linux bootstrap script`, `ci: add macOS iOS build job`,
`emulator: expose framebuffer bridge`, `input: map UIKit touches to guest coordinates`.
Not `update`, `fix`, `changes`.

## Updating the emulator or a dependency

One PR, titled `chore: update Inferno to <SHA>` (or the dependency): change `deps.lock` (full SHA /
new SHA-256), run `python3 tools/deps/check_abi.py` against the new tree, rebuild on macOS, and
record boot regressions, patch conflicts and performance in the PR and a devlog entry. Never pin a
branch name or `latest`.

## Emulator patches

Prefer the runtime bridge. When QEMU must change, add a `git format-patch` file to
`emulator/patches/`, list it in `series`, and describe its purpose in `emulator/README.md`.

## Never commit

Apple firmware, IPSWs, kernelcaches, DeviceTrees, SEP files, tickets, guest images, signing
certificates, provisioning profiles, private keys, pairing records, `.env` files. CI rejects them;
do not add them to the allowlist.

## Devlog

After each significant piece of work add `docs/devlog/NNN-topic.md`: goal, what changed, files,
tests, problems and how they were solved, remaining issues, benchmark changes.
