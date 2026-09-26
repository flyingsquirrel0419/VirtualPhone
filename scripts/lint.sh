#!/usr/bin/env bash
# Everything Linux CI checks, runnable locally: scripts/lint.sh [--no-swift]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
step() { echo; echo "==> $*"; }

step "shellcheck"
git ls-files -z '*.sh' | xargs -0 shellcheck -x
step "workflow syntax"
python3 tools/release/check_workflows.py
step "deps.lock"
python3 tools/deps/lockfile.py validate
step "forbidden files and secrets"
python3 tools/release/forbidden_scan.py tree .
step "C formatting"
if command -v clang-format >/dev/null 2>&1; then
    git ls-files -z '*.c' '*.h' | xargs -0 clang-format --dry-run --Werror
else echo "clang-format not installed; skipped"; fi
step "documentation links"
python3 tools/release/check_links.py
step "Python unit tests"
python3 -m unittest discover -s tests/unit/python
step "runtime bridge (mock emulator, ASan/UBSan)"
tests/emulator/run.sh
if [ "${1:-}" != "--no-swift" ] && command -v swift >/dev/null 2>&1; then
    step "Swift core tests"
    swift test
fi
echo; echo "lint: all checks passed"
