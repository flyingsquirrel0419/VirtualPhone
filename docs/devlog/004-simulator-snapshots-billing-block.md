# 004 — Simulator smoke test, snapshots, CI blocked by billing

## What changed

- `PLATFORM=simulator app/build.sh` builds a simulator `.app` (mock runtime only).
  `-VPAutoDemo YES` / `-VPShowConsole YES` launch arguments boot a demo device unattended.
  `scripts/sim-smoke.sh` + the `simulator` job in `ios-build.yml` launch it, screenshot both
  views and check the app log for the mock boot, first frame and detected boot phases.
- `DeviceSnapshots`: a device's overlay and state copies saved and restored together
  (staged/visible-when-complete, copy-then-swap restore). Settings gain a Snapshots section.

## Results

- Linux: 63 Swift tests, Python, bridge (mock and real library) — PASS locally.
  Snapshot round trip checked with `qemu-io` writes and `qemu-img check`.
- First simulator run (6bb1286): the simulator **refused to open the app**
  (`FBSOpenApplicationServiceErrorDomain code=1`) — cause not yet known. The next commit signs the
  simulator build without the device memory entitlements and dumps the simulator log and crash
  reports on failure. **Not verified**: see below.
- iOS compile of commit `ea19e3d` (snapshot UI, simulator changes): **not verified**.

## Blocker

From `ea19e3d` on, GitHub does not start any job: *"The job was not started because recent
account payments have failed or your spending limit needs to be increased."* The private
repository's Actions allowance is used up (macOS minutes count ten times). Needs the account
owner: fix the payment method or raise the Actions spending limit (Settings → Billing & plans).
After that, re-run `iOS Build` on `main` to verify ea19e3d and the simulator job.
