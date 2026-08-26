#!/usr/bin/env bash
# sdrtrunk — trunked-radio decoder. Packaged nowhere: not Fedora, not RPM Fusion,
# not Flathub (all three checked 2026-08-25). Upstream ships a jlink app-image zip
# per platform, which is actually the easy case — it carries its own JRE at
# bin/java, so this pulls in no Java runtime dependency and cannot be broken by a
# system JDK bump.
#
# PINNED VERSION + SHA256, ON PURPOSE. This fetches code over the network into an
# image that gets cosign-signed at the end of the build. An unpinned "latest"
# fetch would mean the signature attests to whatever upstream published that
# morning, which nobody reviewed. Bumping is a one-line edit that shows in a diff.
#
# To bump: change VERSION, run the build, take the sha256 the failure prints, and
# put it in SHA256. Do not skip the verify step — a mismatch here is the only
# thing standing between a compromised release asset and a signed image.
set -euo pipefail

VERSION="0.6.1"
SHA256="1e87c8c8446963df62342c9f895e7669bf0a440f258d6bb1dd94485517cb7174"

ASSET="sdr-trunk-linux-x86_64-v${VERSION}.zip"
URL="https://github.com/DSheirer/sdrtrunk/releases/download/v${VERSION}/${ASSET}"
# /usr/lib/opt, NOT /opt AND NOT /usr/local. Both of those are symlinks into /var
# on this ostree base — verified against sway-atomic:44:
#
#     /opt        -> var/opt
#     /usr/local  -> ../var/usrlocal
#
# /var is machine state, not image content. Writing there during a build appears
# to work, produces no error, and is then DISCARDED when the image is committed —
# so the build goes green and the installed machine has no sdrtrunk. That is the
# worst shape a bug can take here, and it is the default thing to get wrong.
#
# /usr/lib/opt is the image-side location the base already provides for exactly
# this (it exists in the base image), and a tmpfiles.d rule below re-exposes it at
# the conventional /opt/sdrtrunk path on the running system.
DEST="/usr/lib/opt/sdrtrunk"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo ">>> fetching ${ASSET}"
# --retry with backoff: a GitHub release CDN blip should not fail the whole image.
curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$tmp/$ASSET" "$URL"

echo ">>> verifying sha256"
actual=$(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)
if [ "$actual" != "$SHA256" ]; then
  echo "!! sha256 MISMATCH for ${ASSET}" >&2
  echo "!!   expected: ${SHA256}" >&2
  echo "!!   actual:   ${actual}" >&2
  echo "!! Either upstream re-cut the release or the download was tampered with." >&2
  echo "!! Do NOT just paste the new hash in without checking which of those it is." >&2
  exit 1
fi

echo ">>> installing to ${DEST}"
mkdir -p "$tmp/x"
# unzip ships in the sway-atomic base (/usr/sbin/unzip), so it is present in the
# build container; bsdtar is not. Checked, not assumed.
unzip -q "$tmp/$ASSET" -d "$tmp/x"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$tmp/x/sdr-trunk-linux-x86_64-v${VERSION}" "$DEST"
chmod 0755 "$DEST/bin/sdr-trunk" "$DEST/bin/java"

# Upstream ships no .desktop and no icon, so the app is invisible to fuzzel
# without this. StartupWMClass matters under niri: the window rules in
# files/system/etc/niri/config.kdl match sdrtrunk by app-id to open it floating,
# and a Java/Swing window with no explicit class reports something unhelpful.
install -Dm0644 /dev/stdin /usr/share/applications/sdrtrunk.desktop <<DESKTOP
[Desktop Entry]
Type=Application
Name=sdrtrunk
GenericName=Trunked Radio Decoder
Comment=Decode trunked and conventional radio systems from an SDR
Exec=${DEST}/bin/sdr-trunk
Terminal=false
Categories=HamRadio;Network;AudioVideo;
Keywords=SDR;P25;trunking;scanner;radio;
StartupWMClass=io.github.dsheirer.gui.SDRTrunk
DESKTOP

# A wrapper on PATH, so `sdrtrunk` works from a shell and from the .desktop file
# without either hardcoding the /opt layout.
install -Dm0755 /dev/stdin /usr/bin/sdrtrunk <<WRAPPER
#!/usr/bin/sh
exec ${DEST}/bin/sdr-trunk "\$@"
WRAPPER

# Re-expose it at /opt/sdrtrunk on the running system. tmpfiles type L creates the
# symlink at boot, into the /var/opt that ostree owns. Nothing in this image needs
# that path — the wrapper and .desktop both point straight at /usr/lib/opt — but
# sdrtrunk's own docs, and anyone poking at the machine, will look in /opt.
install -Dm0644 /dev/stdin /usr/lib/tmpfiles.d/kb3lyb-sdrtrunk.conf <<TMPFILES
# Compat symlink: /opt is /var/opt (machine state) on ostree, so the real files
# live in /usr/lib/opt and get linked into place at boot.
L /opt/sdrtrunk - - - - ${DEST}
TMPFILES

# Postcondition. If a future base ever stops providing /usr/lib/opt, or the zip
# layout changes, fail the build here rather than shipping a menu entry that
# points at nothing.
[ -x "$DEST/bin/sdr-trunk" ] || { echo "!! sdrtrunk launcher missing after install" >&2; exit 1; }
echo ">>> sdrtrunk ${VERSION} installed"
