# Third-party notices

VirtualPhone's own code is licensed under the GNU General Public License, version 3 or (at your
option) any later version — see [LICENSE](LICENSE). The shipped `.ipa` also contains the
components below. Exact versions and checksums are in [deps.lock](deps.lock); the SBOM attached
to every release (`SBOM.spdx.json`) lists the same.

This file records facts about licences, not legal advice; the maintainers are not lawyers —
check the licence texts themselves before redistributing.

## Emulator

**Inferno (MakrSas `ios` fork of ChefKiss Inferno), derived from QEMU**
Repository: https://github.com/MakrSas/Inferno (branch `ios`, commit in deps.lock)
Upstream: https://github.com/ChefKissInc/Inferno — © ChefKiss and the Inferno team; QEMU © its
many contributors.

- The project as a whole: GNU GPL version 3 (upgraded from QEMU's GPL-2.0-or-later parts under
  GPLv2 §9, per Inferno's `LICENSE`).
- ChefKiss's own code, and the `ios` fork's additions (e.g. `ui/inferno-embed.c`): GNU Affero GPL
  version 3 (or later, per file headers), combined under GPLv3 §13.
- Individual files may carry other compatible licences; see each file's header in the source tree.
- The ChefKiss boot-splash artwork and the "ChefKiss Inferno" name are **not** under these
  licences and are **not** included in VirtualPhone builds (`ui/icons/CKBrandingNotice.md`).

Obligations this implies for anyone distributing the `.ipa` (summary of the licence terms):
provide the complete corresponding source for the GPL/AGPL parts — this repository at the release
tag plus the emulator repository at the pinned commit and `emulator/patches/` — keep copyright and
licence notices intact, and, for AGPL-covered code, offer source to users who interact with it
over a network. A private repository does not remove these obligations once binaries are given to
others.

QEMU's keymaps, when bundled in `qemu-data/keymaps`, come from a stock QEMU build (GPL-2.0-or-later).

## Libraries statically linked into the emulator

| Component | Version | Licence | Source |
|---|---|---|---|
| GLib (with bundled libffi, PCRE2, proxy-libintl) | 2.84.3 | LGPL-2.1-or-later (libffi: MIT, PCRE2: BSD-3-Clause, proxy-libintl: LGPL-2.1-or-later) | https://download.gnome.org/sources/glib/ |
| pixman | 0.44.2 | MIT | https://www.cairographics.org/releases/ |
| libslirp | 4.9.1 | BSD-3-Clause | https://gitlab.freedesktop.org/slirp/libslirp |
| libucontext | 1.3.2 | ISC | https://github.com/kaniini/libucontext |
| LZFSE | 1.0 | BSD-3-Clause | https://github.com/lzfse/lzfse |
| libpng | 1.6.58 | libpng-2.0 (PNG Reference Library License v2) | https://github.com/pnggroup/libpng |
| GMP | 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later | https://gmplib.org |
| Nettle (with Hogweed) | 3.10.2 | LGPL-3.0-or-later or GPL-2.0-or-later | https://www.lysator.liu.se/~nisse/nettle/ |
| libtasn1 | 4.20.0 | LGPL-2.1-or-later | https://www.gnu.org/software/libtasn1/ |
| zlib | 1.3.1 | Zlib | https://zlib.net |

The LGPL libraries are linked statically into a GPL-licensed library, whose complete source is
provided as above, which satisfies the LGPL's relinking provision through the GPL source offer.

## Prior art and adapted code

**Inferno-iOS** — https://github.com/MakrSas/Inferno-iOS — GPL-3.0.
`emulator/scripts/build-ios-deps.sh` and `emulator/scripts/build-ios.sh` are adapted from its
`scripts/build-ios-deps.sh` and `make-cross-file.sh`; the emulator command line in
`app/Sources/Core/EmulatorArguments.swift` and the JIT probing approach follow what it established
on real phones. VirtualPhone is an independent project, not affiliated with or endorsed by
MakrSas or ChefKiss.

## Not included, ever

No Apple IPSW, firmware, SEP firmware or ROM, kernelcache, DeviceTree, trust cache, APTicket,
decryption key, guest filesystem image, signing certificate, provisioning profile or pairing record
is part of this repository or any release. Users prepare guest files from their own legitimate
sources.
