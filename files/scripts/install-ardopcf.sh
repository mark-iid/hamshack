#!/usr/bin/env bash
# ardopcf — the ARDOP soundcard modem, for Pat/Winlink over HF.
#
# WHY THIS IS HERE AND NOT IN THE RECIPE: packaged nowhere for Fedora. Checked
# 2026-08-26; the only distro packaging found anywhere was Clear Linux's, which
# builds from the upstream source tarball. Upstream ships a prebuilt Linux x86_64
# binary, so there is nothing to compile and nothing to depsolve — same situation
# as install-pat.sh.
#
# WHY ardopcf AND NOT VARA: this is the native option. VARA HF/FM are closed-source
# Windows-only builds that have to run under Wine; ardopcf is open source and runs
# natively. Both are configured in Pat (SETUP §6.9) and they are not exclusive —
# ardopcf costs nothing to have present, and it is the fallback if the Wine side of
# VARA ever breaks.
#
# UPSTREAM IS `pflarue/ardop`, note the spelling — `pflarr` is a different thing and
# does not exist. The GitHub search for "ardopcf" does NOT surface the canonical
# repo, which is how that typo survives; the Clear Linux spec is what names it.
#
# PINNED VERSION + SHA256 for the same reason as install-pat.sh and
# install-sdrtrunk.sh: this pulls code off the network into an image that gets
# cosign-signed afterwards, and an unpinned fetch makes that signature attest to
# something nobody reviewed.
#
# To bump: change VERSION, build, take the sha256 the failure prints, verify it is a
# legitimate new release rather than a re-cut of the old one, then update SHA256.
set -euo pipefail

VERSION="1.0.4.1.3"
SHA256="caf256ca1138ea992323bf8c6729a06aaaacb1b62181d0a7b2abba3dffaa9ad8"

# Upstream publishes the bare binary as a release asset, not a tarball. The name
# encodes host arch and word size; amd64_Linux_64 is this machine.
ASSET="ardopcf_amd64_Linux_64"
URL="https://github.com/pflarue/ardop/releases/download/${VERSION}/${ASSET}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo ">>> fetching ${ASSET}"
curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$tmp/$ASSET" "$URL"

echo ">>> verifying sha256"
actual=$(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)
if [ "$actual" != "$SHA256" ]; then
  echo "!! sha256 MISMATCH for ${ASSET}" >&2
  echo "!!   expected: ${SHA256}" >&2
  echo "!!   actual:   ${actual}" >&2
  exit 1
fi

echo ">>> installing /usr/bin/ardopcf"
install -Dm0755 "$tmp/$ASSET" /usr/bin/ardopcf

# Dynamically linked against libasound (ALSA). alsa-lib is already in the base
# image — verified present, all deps resolving, 2026-08-26 — so nothing is added
# to the recipe for this. If a future base drops it, ardopcf fails at RUN time
# with a loader error rather than at build time, hence the assert below.
[ -x /usr/bin/ardopcf ] || { echo "!! /usr/bin/ardopcf missing after install" >&2; exit 1; }
[ -e /usr/lib64/libasound.so.2 ] || {
  echo "!! libasound.so.2 absent — ardopcf will not start. Add alsa-lib to the recipe." >&2
  exit 1
}

# Deliberately NOT run here: ardopcf's only non-serving mode is `-H`/help, and the
# normal invocation opens ALSA devices and binds TCP ports, neither of which exists
# in a build container. The existence + linkage checks above are the real
# postcondition.
#
# NOT a system service, for the same reason as Pat's web UI: it is started per
# operating session against a specific soundcard and rig, e.g.
#     ardopcf 8515 <capture-device> <playback-device>
# and Pat connects to it on localhost:8515 (see the `ardop` block in
# ~/.config/pat/config.json). PTT goes through the shared rigctld, NOT through
# ardopcf's own serial PTT — one owner for the CAT port (SETUP §6.5).
echo ">>> ardopcf ${VERSION} installed"
