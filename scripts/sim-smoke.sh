#!/usr/bin/env bash
# Runs the app in the iOS Simulator on the mock runtime and checks it
# end to end: launch, device creation, mock boot, first frame, console boot
# phases, no crash. Screenshots and logs go to OUT for the CI artifact.
#
#   scripts/sim-smoke.sh            (macOS with Xcode; builds PLATFORM=simulator)
#
# This is not a physical-device test: no JIT, no emulator library, no guest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/build/sim-smoke}"
BUNDLE="${BUNDLE_ID:-dev.virtualphone.app}"
WAIT="${WAIT:-10}"
mkdir -p "$OUT"
touch "$OUT/.started"
UDID=""
diagnose() {
    [ -n "$UDID" ] || return 0
    echo "--- simulator log (last 3 min, VirtualPhone) ---" >&2
    xcrun simctl spawn "$UDID" log show --last 3m --style compact \
        --predicate 'process == "VirtualPhone" OR eventMessage CONTAINS[c] "virtualphone"' > "$OUT/simulator.log" 2>&1 || true
    tail -60 "$OUT/simulator.log" >&2 || true
    find "$HOME/Library/Logs/DiagnosticReports" -name 'VirtualPhone*' -newer "$OUT/.started" -exec cp {} "$OUT/" \; 2>/dev/null || true
    for f in "$OUT"/VirtualPhone*.ips; do [ -f "$f" ] && { echo "--- $f ---" >&2; head -80 "$f" >&2; }; done
}
fail() { echo "sim-smoke: FAIL: $*" >&2; diagnose; exit 1; }

APP="$(PLATFORM=simulator "$ROOT/app/build.sh" | tail -1)"
[ -d "$APP" ] || fail "no app built ($APP)"

# The newest available iOS runtime's first iPhone.
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
d = json.load(sys.stdin)["devices"]
def ver(k):
    m = re.search(r"iOS-(\d+)-(\d+)", k)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
for runtime in sorted((k for k in d if "iOS" in k), key=ver, reverse=True):
    phones = [x for x in d[runtime] if x["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"]); break
')"
[ -n "$UDID" ] || fail "no available iPhone simulator"
xcrun simctl list devices | grep "$UDID" | sed 's/^ */simulator: /'
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

launch() {
    local out
    out="$(xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" "$@" 2>&1)" || { echo "$out" >&2; fail "launch refused"; }
    echo "$out" | awk '{print $NF}'
}
alive() { kill -0 "$1" 2>/dev/null; }

echo "==> screen: auto demo on the mock runtime"
pid="$(launch -VPAutoDemo YES)"
sleep "$WAIT"
alive "$pid" || fail "app exited during the screen run"
xcrun simctl io "$UDID" screenshot "$OUT/machine-screen.png" > /dev/null

echo "==> console: same device, console tab"
pid="$(launch -VPAutoDemo YES -VPShowConsole YES)"
sleep "$WAIT"
alive "$pid" || fail "app exited during the console run"
xcrun simctl io "$UDID" screenshot "$OUT/machine-console.png" > /dev/null
xcrun simctl terminate "$UDID" "$BUNDLE" || true

DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
cp "$DATA/Documents/Logs/app.log" "$OUT/app-console-run.log"
cp "$DATA/Documents/Logs/app.prev.log" "$OUT/app-screen-run.log" 2>/dev/null || true
cp "$DATA/Documents/Devices/Demo iPhone.vphone/config.json" "$OUT/demo-config.json" \
    || fail "the demo device package was not created"
cp "$DATA/Documents/Devices/Demo iPhone.vphone/logs/guest-console.log" "$OUT/" 2>/dev/null || true

check() { # check <file> <text> <what>
    grep -qF "$2" "$1" || fail "$3 (no '$2' in $(basename "$1"))"
    echo "ok: $3"
}
check "$OUT/app-screen-run.log" "Mock machine running" "mock machine reached running"
check "$OUT/app-screen-run.log" "First frame after" "first frame reached the screen"
check "$OUT/app-console-run.log" "Kernel after" "console tail detected the kernel phase"
check "$OUT/app-console-run.log" "Shell ready after" "console tail detected the shell phase"
grep -F "[ERROR]" "$OUT"/app-*.log && fail "errors in the app log"

# A crash anywhere in the run leaves a report behind.
crashes="$(find "$HOME/Library/Logs/DiagnosticReports" -newer "$OUT/.started" -name 'VirtualPhone*' 2>/dev/null || true)"
if [ -n "$crashes" ]; then
    while IFS= read -r f; do cp "$f" "$OUT/" 2>/dev/null || true; done <<<"$crashes"
    fail "crash report(s): $crashes"
fi

python3 -c "import json,sys; c=json.load(open(sys.argv[1])); assert c['schema']==2 and c['protectBaseImage'], c" "$OUT/demo-config.json"
echo "sim-smoke: PASS ($OUT)"
