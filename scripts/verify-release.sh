#!/usr/bin/env bash
# The release gate for one built .ipa: structure, emulator present, signature,
# version equals the tag, no forbidden files, checksum file valid.
#   scripts/verify-release.sh DIST_DIR TAG
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dist="$1"; tag="$2"
version="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[ "v$version" = "$tag" ] || { echo "tag $tag does not match VERSION $version" >&2; exit 1; }
shopt -s nullglob
ipas=("$dist"/*.ipa)
[ ${#ipas[@]} = 1 ] || { echo "expected exactly one .ipa in $dist, found ${#ipas[@]}" >&2; exit 1; }
python3 "$ROOT/tools/ipa/verify_ipa.py" "${ipas[0]}" --expect-version "$version" --require-emulator --require-signature
python3 "$ROOT/tools/release/forbidden_scan.py" archive "${ipas[0]}"
( cd "$dist" && if command -v sha256sum >/dev/null; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi )
# Nothing but the allowed release assets.
for f in "$dist"/*; do
    case "$(basename "$f")" in
        *.ipa|SHA256SUMS|SBOM.spdx.json|RELEASE_NOTES.md) ;;
        *) echo "unexpected release asset: $f" >&2; exit 1 ;;
    esac
done
echo "verify-release: OK ($tag)"
