# Networking

Two separate things:

- **Guest internet.** The emulated iPhone's USB port is switched into CDC-NCM mode by the
  emulator's `apple-ncm-host` device (MakrSas fork), which acts as the USB host inside the app
  and sends the traffic out through slirp (`-netdev user`). No companion VM, no host network
  configuration. Enabled per device (*Settings → Network*).
- **Host ↔ guest control.** The serial console (TCP chardev on 127.0.0.1) and, later, the guest
  agent. The USB socket is a bare file name in the package's `state/` folder, because AF_UNIX
  paths are limited to 104 bytes and app container paths are longer.

Status: v0.1 passes the network arguments and reports `inferno_net_link_up()` in the debug
overlay. *Reconnect guest network* (runs `ipconfig set en0 DHCP` in the guest) and automatic
recovery on link drop are v0.5. Upstream reports the guest occasionally drops its interface after
use; that recovery is the known workaround.
