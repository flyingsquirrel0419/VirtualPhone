# Performance

Every number here names the device, host iOS, build commit and configuration it was measured
with; a change claims an improvement only against a baseline from the same device.

## Metrics

cold boot time · time to Apple logo · time to SpringBoard · FPS · frame time · host RAM
(phys_footprint) · guest RAM · translation cache size · host CPU · disk throughput.

v0.1 exposes in the debug overlay: FPS of frames delivered to the UI, frames presented and display
refreshes per second (from the emulator), uptime, host RAM, translator cache and guest RAM.

## Baselines

| Date | Device | Host iOS | Commit | Config | Result |
|---|---|---|---|---|---|
| — | — | — | — | — | NOT RUN (no physical-device measurement yet) |

Upstream reference (Inferno-iOS, not measured by us): translator cache 64 MB → 8–11 fps,
256 MB → 21–25 fps.
