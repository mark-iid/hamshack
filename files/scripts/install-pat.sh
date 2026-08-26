#!/usr/bin/env bash
# Pat — the Winlink client. Packaged nowhere for Fedora: upstream ships .deb,
# .tar.gz, macOS .pkg and Windows .zip, and no RPM (checked against the v1.0.0
# release assets, 2026-08-25). It is a single static Go binary, so the tarball is
# genuinely the right way in — there is nothing to depsolve.
#
# PINNED VERSION + SHA256 for the same reason as install-sdrtrunk.sh: this pulls
# code off the network into an image that gets cosign-signed afterwards, and an
# unpinned fetch makes that signature attest to something nobody reviewed.
#
# To bump: change VERSION, build, take the sha256 the failure prints, verify it is
# a legitimate new release rather than a re-cut of the old one, then update SHA256.
set -euo pipefail

VERSION="1.0.0"
SHA256="331e4700c9e8b44098d7173e448da53204f59720c6c19ebc903685666aa377f7"

ASSET="pat_${VERSION}_linux_amd64.tar.gz"
URL="https://github.com/la5nta/pat/releases/download/v${VERSION}/${ASSET}"

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

echo ">>> installing /usr/bin/pat"
mkdir -p "$tmp/x"
# The tarball was cut on a Mac and carries AppleDouble junk (._pat and friends)
# plus com.apple.provenance xattrs, which make GNU tar noisy. Extract only the
# binary and ignore the rest rather than unpacking the whole thing.
tar -xzf "$tmp/$ASSET" -C "$tmp/x" --no-same-owner --warning=no-unknown-keyword
install -Dm0755 "$tmp/x/pat_${VERSION}_linux_amd64/pat" /usr/bin/pat

# Pat's own `pat http` web UI is the normal way to drive it, started per-user on
# demand — deliberately NOT a system service. It holds the operator's Winlink
# credentials and needs their $HOME; running it as a system daemon would mean
# either baking a callsign into the image or inventing a service account for a
# single-operator machine. Start it from a terminal, or add a user unit in
# dotfiles where the callsign belongs.

[ -x /usr/bin/pat ] || { echo "!! /usr/bin/pat missing after install" >&2; exit 1; }
# Deliberately NOT `pat version`: that subcommand creates/opens its DataDir under
# $HOME before printing anything, which fails in the build container. The
# existence + exec check above is the real postcondition.
echo ">>> pat ${VERSION} installed"
