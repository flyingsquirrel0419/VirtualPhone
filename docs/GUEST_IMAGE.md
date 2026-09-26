# Preparing the guest

VirtualPhone ships no Apple software. You build the guest yourself from an iPhone 11 iOS 14.x IPSW
you are entitled to use, following ChefKiss's guides:

- Inferno setup: https://chefkiss.dev/guides/inferno/
- Jailbreak bootstrap (required — the guest shell, file transfer and network recovery depend on
  it): https://chefkiss.dev/guides/inferno-post-setup/jailbreak-bootstrap/

## Files the machine needs

Copy them into the app's Documents (Files → On My iPhone → VirtualPhone). Default layout:

```
AppleSEPROM-Cebu-B1
InfernoData/root.qcow2                (or root — the raw image)
InfernoData/firmware  syscfg  ctrl_bits  nvram  effaceable  panic_log  sep_nvram  sep_ssc
InfernoData/root_ticket.der
InfernoData/sep-firmware.n104.RELEASE.new.img4
InfernoData/Restore/kernelcache.release.iphone12b
InfernoData/Restore/Firmware/<build>.dmg.trustcache
InfernoData/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p
```

Prefer **`root.qcow2`**: the raw image is nominally ~34 GB holding ~9 GB and relies on being
sparse, which copying to a phone loses.

The trust cache is named after your iOS build's root filesystem DMG; set its path in the device's
**Settings → Guest files** if it is not `038-44135-124.dmg.trustcache`. Paths there are relative to
Documents (data folder, SEP ROM) or to the data folder (the rest), or absolute.

## Checks VirtualPhone makes

Before starting, every file must be a regular, non-empty file. A folder or an empty file with the
right name is reported as missing — QEMU would otherwise call `exit()` inside the app.

## Keep it out of the repository

`.gitignore` ignores these names, and `tools/release/forbidden_scan.py` fails CI and releases on
IPSWs, IMG4 payloads, kernelcaches, DeviceTrees, SEP files, tickets, disk images, provisioning
profiles, keys and pairing records — by name, by content signature and by size. Never add them to
the allowlist.
