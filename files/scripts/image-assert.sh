#!/usr/bin/env bash
# Postconditions for the built image. Runs LAST, after every other module.
#
# WHY THIS EXISTS. A green build proves the recipe depsolved. It does not prove
# the image is the one we meant to build. The laptop repo this was forked from had
# already shipped three defects a depsolve gate cannot see (files-module ordering
# reverting baked config; `unrar` silently degrading when modules were reordered;
# a flatpak override that segfaulted an app). Every check below corresponds to a
# hazard documented in prose somewhere in this repo. Prose cannot fail a build.
#
# This image adds three hazards of its own, and they are the interesting ones:
#
#   * chirp+wx vs chirp. The GUI is in the +wx subpackage. Install plain `chirp`
#     and the build is green, dnf is happy, and there is no CHIRP window on the
#     machine — only /usr/bin/chirpc.
#   * wine without i686. On Fedora 44 the `wine` metapackage resolves x86_64-only.
#     Wine would be installed, the build green, and every 32-bit RT Systems
#     programmer would fail at launch.
#   * /opt is a symlink to /var/opt. Anything sdrtrunk's installer writes there
#     is discarded when the image is committed — no error, no sdrtrunk.
#
# WHAT THIS CANNOT CATCH. Everything here runs inside the build container, so it
# only sees build-time truth. Anything re-resolved on the installed system —
# numeric uid/gid above all, which is what a chgrp actually records — can be right
# here and wrong on the machine. Those checks belong host-side. Likewise nothing
# here can prove a radio is reachable; see SETUP §6 for the on-machine checklist.
#
# Style: this does NOT `set -e`. Every assertion runs so one build reports every
# problem, and the script exits nonzero at the end if any failed.
set -uo pipefail

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
# Non-fatal. For conditions that are real but not ours to fix, where failing the
# build would only teach everyone to ignore the output.
warn() { printf '  warn %s\n' "$1" >&2; }

# assert <description> <command...> — passes when the command succeeds.
assert() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

# refute <description> <command...> — passes when the command FAILS. A separate
# helper rather than a leading `!`, which is shell syntax and not a command, so it
# cannot survive being passed through "$@".
refute() { if "${@:2}"; then fail "$1"; else pass "$1"; fi; }

# assert_file_has <description> <file> <extended-regex>
assert_file_has() {
  if [ -r "$2" ] && grep -Eq "$3" "$2"; then pass "$1"; else fail "$1 ($2)"; fi
}

# assert_file_has <description> <file> <extended-regex>
assert_file_has() {
  if [ -r "$2" ] && grep -Eq "$3" "$2"; then pass "$1"; else fail "$1 ($2)"; fi
}

echo "image-assert: checking postconditions"

# --- Codecs: the INTEL path, not the laptop's AMD one ------------------------
# ffmpeg must be RPM Fusion's, and the VA-API driver must be intel-media-driver.
# The second check is the one that matters: mesa-va-drivers-freeworld would also
# install cleanly and would do nothing at all on Coffee Lake graphics.
assert "ffmpeg (RPM Fusion) installed"          rpm -q --quiet ffmpeg
assert "intel-media-driver installed"           rpm -q --quiet intel-media-driver
assert "iHD VA-API driver present" \
  test -e /usr/lib64/dri/iHD_drv_video.so
refute "mesa-va-drivers-freeworld NOT installed (AMD driver, wrong machine)" \
  rpm -q --quiet mesa-va-drivers-freeworld

# --- CHIRP: the GUI, not just the CLI ----------------------------------------
# The single easiest mistake in this image. `chirp` gives chirpc; the wxPython
# GUI at /usr/bin/chirp belongs to chirp+wx.
assert "chirp GUI binary present (chirp+wx, not plain chirp)" \
  test -x /usr/bin/chirp

# --- Wine: 32-bit runtime actually present -----------------------------------
# `dnf install wine` on Fedora 44 pulls x86_64 only. Without the i686 side, every
# 32-bit RT Systems installer dies at launch. Check for the real artifact — the
# 32-bit wine loader — rather than for the package name, so this stays true even
# if Fedora reshuffles subpackages.
assert "wine installed"                          rpm -q --quiet wine
# The i686 package's distinguishing contribution is the 32-bit UNIX loader at
# /usr/lib/wine-wow64/wine/i386-unix. Do NOT check for i386-windows: the x86_64
# package ships that too (new WoW64), so it would pass with i686 absent and the
# check would assert nothing. Path verified by rpm -ql inside the built image.
if [ -d /usr/lib/wine-wow64/wine/i386-unix ]; then
  pass "wine classic 32-bit host loader present (i386-unix)"
else
  fail "wine i386-unix loader MISSING — wine-core.i686 did not install"
fi
assert "wine new-WoW64 32-bit PE support present" \
  test -e /usr/lib64/wine-wow64/wine/i386-windows/ntdll.dll

# --- Out-of-repo installs landed in the IMAGE, not in /var -------------------
# /opt is a symlink to /var/opt on this ostree base, so an install that targets it
# vanishes at commit time with no error. Assert the real image-side path.
assert "sdrtrunk installed under /usr/lib/opt (NOT /opt, which is /var/opt)" \
  test -x /usr/lib/opt/sdrtrunk/bin/sdr-trunk
assert "sdrtrunk ships its own JRE (no system JDK dependency)" \
  test -x /usr/lib/opt/sdrtrunk/bin/java
assert "sdrtrunk desktop entry present (else it is invisible to fuzzel)" \
  test -r /usr/share/applications/sdrtrunk.desktop
assert "sdrtrunk /opt compat symlink is a tmpfiles rule, not a build-time write" \
  test -r /usr/lib/tmpfiles.d/kb3lyb-sdrtrunk.conf
refute "nothing was written into /var/opt at build time" \
  test -e /var/opt/sdrtrunk
assert "pat (Winlink) installed"                 test -x /usr/bin/pat

# --- The ham stack is actually here ------------------------------------------
# A spot-check across every group in common/hamradio.yml, so a dropped or renamed
# package surfaces as a named failure rather than as a missing menu entry weeks
# later. Binaries, not package names: the binary is what the operator needs.
for bin in wsjtx js8call fldigi flrig flmsg flamp qsstv direwolf xastir \
           rigctl rigctld rotctld rtl_test rtl_433 gqrx sdrpp sdrangel \
           cqrlog klog qlog tqsl gpredict picocom socat; do
  assert "ham binary present: $bin" command -v "$bin"
done

# --- Session -----------------------------------------------------------------
assert "niri installed"                          rpm -q --quiet niri
# Not optional on this machine: fldigi is FLTK/X11 and chirp+wx is wxPython.
# Without xwayland-satellite they have no X server to open on.
assert "xwayland-satellite installed (fldigi and chirp are X11 clients)" \
  rpm -q --quiet xwayland-satellite
assert "baked niri config survived the module ordering" \
  test -r /etc/niri/config.kdl
assert_file_has "niri config carries the floating window rules for ham apps" \
  /etc/niri/config.kdl 'open-floating'
assert_file_has "greetd configured as the display manager" \
  /etc/greetd/config.toml 'tuigreet'
assert "Symbols Nerd Font installed for waybar" \
  sh -c 'ls /usr/share/fonts/nerd-fonts/*Symbols* >/dev/null 2>&1 || fc-list 2>/dev/null | grep -qi "symbols nerd font"'

# --- Laptop-only things this recipe does not ADD -----------------------------
# NOTE WHAT THESE DO AND DO NOT CLAIM. An earlier version of this file asserted
# that fprintd and brightnessctl were ABSENT, on the reasoning that a desktop has
# neither a fingerprint reader nor a backlight. Both assertions failed on the
# first full build, and they were the wrong checks: BOTH PACKAGES SHIP IN THE
# sway-atomic BASE IMAGE. Verified directly against an untouched
# quay.io/fedora-ostree-desktops/sway-atomic:44.
#
# So their presence is not recipe drift and there is nothing here to fix —
# stripping base packages to satisfy a check would be worse than the check. What
# is worth asserting is the thing this recipe actually controls: that it does not
# LAYER the fingerprint auth stack on top, since fprintd-pam plus the authselect
# wiring is what would put pam_fprintd into the PAM stack of a machine with no
# reader.
# fprintd-pam is in the base too. Checking for the PACKAGE was wrong twice over;
# what matters is whether pam_fprintd is REFERENCED BY THE PAM STACK, because that
# is what would make a machine with no reader prompt for a finger and stall. The
# base ships the package and wires nothing — verified against untouched
# sway-atomic:44 — and this recipe adds no authselect step, unlike the laptop's.
# Assert the behaviour, not the inventory.
refute "pam_fprintd not wired into the PAM stack (no reader on this machine)" \
  grep -rqs pam_fprintd /etc/pam.d/

# --- Update strategy ---------------------------------------------------------
assert_file_has "rpm-ostreed stages updates rather than applying them" \
  /etc/rpm-ostreed.conf '^AutomaticUpdatePolicy=stage'

# --- Pinned GIDs -------------------------------------------------------------
# rtl-sdr's udev rules use GROUP="rtlsdr", a dynamically allocated group. Read
# the sysusers file for the full account.
PIN_FILE=/usr/lib/sysusers.d/00-kb3lyb-gids.conf
assert "pinned-GID file present"                 test -r "$PIN_FILE"
assert_file_has "rtlsdr GID is pinned"           "$PIN_FILE" '^g[[:space:]]+rtlsdr[[:space:]]+[0-9]+'

echo
if [ "$fails" -gt 0 ]; then
  echo "image-assert: $fails postcondition(s) FAILED" >&2
  exit 1
fi
echo "image-assert: all postconditions passed"
