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
# The driver being present is not the same as being able to check it. vainfo needs
# a real GPU, so this build can only guarantee the TOOL exists for the on-machine
# check in SETUP §6.2.
assert "vainfo present (libva-utils) — the only way to verify decode on the box" \
  command -v vainfo
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


# --- The size cuts actually held ---------------------------------------------
# These exist because an exclude glob that dnf silently ignores looks EXACTLY like
# one that worked. 900 MB is worth a check.
refute "proj-data regional grids excluded (764 MB of unused datum grids)" \
  sh -c 'rpm -qa "proj-data-*" | grep -q .'
refute "no General MIDI soundfont on a ham radio PC (142 MB)" \
  rpm -q --quiet fluid-soundfont-gm
# wine-core.i686 was excluded here until 2026-08-26 to save 1.23 GB, on the
# reasoning that new WoW64 covers 32-bit PE. That reasoning was never executed,
# and when it was, it failed: the DRCS25 installer dies in the WoW64 exception
# path, and WINEARCH=win32 — which avoids that path — is refused outright without
# the classic i386-unix loader this package provides. The refute below is
# therefore now an assert. If the RT Systems programmers are ever abandoned for a
# Windows VM, flip this back and drop the package; do not leave 1.23 GB unexamined.
assert "wine 32-bit multilib installed (needed for WINEARCH=win32)" \
  rpm -q --quiet wine-core.i686
# The classic 32-bit host loader — the actual reason the package is here. Checking
# for this rather than the package name keeps the assert honest if Fedora ever
# reshuffles subpackages.
assert "classic i386-unix loader present (WINEARCH=win32 works)" \
  sh -c 'test -d /usr/lib64/wine-wow64/wine/i386-unix || test -d /usr/lib/wine-wow64/wine/i386-unix'
# 32-bit PE support via new WoW64 must ALSO still be present — both paths matter.
assert "wine still runs 32-bit PE via new WoW64" \
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

# cqrlog is deliberately absent (it drags in mariadb-server); assert that, so it
# cannot creep back in as somebody else's dependency without anyone noticing.
refute "cqrlog NOT installed (would pull mariadb-server onto a shack PC)" \
  rpm -q --quiet cqrlog
refute "no mariadb-server in the image" \
  rpm -q --quiet mariadb-server

# --- The ham stack is actually here ------------------------------------------
# A spot-check across every group in common/hamradio.yml, so a dropped or renamed
# package surfaces as a named failure rather than as a missing menu entry weeks
# later. Binaries, not package names: the binary is what the operator needs.
for bin in wsjtx js8call fldigi flrig flmsg flamp qsstv direwolf xastir \
           rigctl rigctld rotctld rtl_test rtl_433 gqrx sdrpp sdrangel \
           klog qlog tqsl gpredict picocom socat; do
  assert "ham binary present: $bin" command -v "$bin"
done

# --- Nextcloud is mounted, not synced ----------------------------------------
# gvfs alone makes davs:// browsable in Thunar but reachable ONLY by GTK apps.
# Every ham GUI here is Qt/FLTK/wx/Java, so without gvfs-fuse projecting the mount
# into /run/user/$UID/gvfs none of them can open a file from Nextcloud — and that
# failure looks like "the file picker is empty", not like a missing package.
assert "gvfs-fuse installed (else GVFS mounts are invisible to non-GTK apps)" \
  rpm -q --quiet gvfs-fuse
assert "gvfs WebDAV backend present" test -x /usr/libexec/gvfsd-dav
assert "rclone present (the mount path that needs no GVFS at all)" \
  command -v rclone

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
# The rules are guesses that fail SILENTLY (niri has no unmatched-rule warning),
# so the tool that turns that silence into output has to actually be present.
assert "window-rule checker present (the rules fail silently without it)" \
  test -x /usr/bin/kb3lyb-check-window-rules

# Every command the niri config spawns or binds must actually exist. Generalised
# from the greetd defect above: baked config that names a binary is a promise,
# and nothing else in the build checks the promise is kept. A missing spawn here
# is quieter than the greeter was — the session still starts, you just silently
# have no bar, no notifications, or no polkit agent.
missing_spawn=""
for _c in $(grep -oE 'spawn-at-startup "[^"]+"|spawn "[^"]+"' /etc/niri/config.kdl 2>/dev/null \
            | sed 's/spawn-at-startup "//; s/spawn "//; s/"$//' | sort -u); do
  case "$_c" in
    -*|"") continue ;;
  esac
  if [ -x "$_c" ] || command -v "$_c" >/dev/null 2>&1; then :; else
    missing_spawn="$missing_spawn $_c"
  fi
done
if [ -z "$missing_spawn" ]; then
  pass "every command the niri config spawns exists"
else
  fail "niri config spawns missing command(s):$missing_spawn"
fi
# GREETD IS LOGIN-CRITICAL AND THIS CHECK USED TO BE TOO SHALLOW.
#
# It asserted only that /etc/greetd/config.toml mentions tuigreet. It did NOT
# check that the command the config actually EXECUTES exists. On 2026-08-26 that
# gap shipped a real defect to real hardware: the config was copied from the
# laptop image, it invokes /usr/bin/kb3lyb-greeter, and that script was never
# copied across. The build was green, every other postcondition passed, and the
# installed machine booted to:
#
#     /bin/sh: line 1: /usr/bin/kb3lyb-greeter: No such file or directory
#
# with no way to log in graphically. Asserting a config's CONTENT while ignoring
# the binary it POINTS AT is precisely the class of bug this file exists to catch.
#
# So: parse the command out of the config and verify it is executable.
# The greeter is niri + gtkgreet, not tuigreet — see the config header for why.
assert_file_has "greetd runs the niri greeter config" \
  /etc/greetd/config.toml 'niri --config /etc/niri/greeter.kdl'
assert "greeter niri config present"     test -r /etc/niri/greeter.kdl
assert "greeter stylesheet present"      test -r /etc/greetd/gtkgreet.css
assert "gtkgreet installed"              command -v gtkgreet
# The whole reason for the Wayland greeter: it must confine itself to one output.
# If this line is ever lost the greeter silently returns to both monitors.
assert_file_has "greeter config turns the secondary output off" \
  /etc/niri/greeter.kdl 'off'
# The greeter config names connectors. niri IGNORES an output block for a
# connector that is not present, so a stale name here fails silently — exactly
# how the old DP-1/DP-2 placeholders survived until the machine existed.
assert_file_has "greeter config names the real primary connector" \
  /etc/niri/greeter.kdl 'HDMI-A-1'
# tuigreet + its wrapper stay as the documented fallback. A fallback that needs a
# rebuild to reach is not a fallback.
assert "tuigreet fallback still installed"        command -v tuigreet
assert "kb3lyb-greeter fallback still installed"  test -x /usr/bin/kb3lyb-greeter
# Parses the FIRST word of the command, which is the executable whether the line
# is a bare path (kb3lyb-greeter) or a command with arguments (niri --config ...).
GREET_CMD=$(sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*"\([^ "]*\).*/\1/p' \
  /etc/greetd/config.toml | head -1)
if [ -n "$GREET_CMD" ] && { [ -x "$GREET_CMD" ] || command -v "$GREET_CMD" >/dev/null 2>&1; }; then
  pass "greetd's session command exists and is executable ($GREET_CMD)"
else
  fail "greetd command '$GREET_CMD' is MISSING — the machine will not reach a login screen"
fi
assert "tuigreet binary present (the greeter wrapper execs it)" \
  command -v tuigreet
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

# --- Kernel arguments --------------------------------------------------------
# consoleblank is the only karg this image sets, and it is easy to lose in a
# refactor because nothing else references it.
assert_file_has "console blanking karg present (greeter would otherwise sit lit)" \
  /usr/lib/bootc/kargs.d/00-kb3lyb.toml 'consoleblank=1200'

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
