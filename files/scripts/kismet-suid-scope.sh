#!/usr/bin/env bash
# DESIGN §1: narrow kismet's setuid-root capture helpers to the `kismet` group.
# Runs at image build time, AFTER the dnf module that installs kismet.
#
# Fedora's kismet rpm ships its capture helpers setuid root AND world-executable:
#
#     0104755 root:root   kismet_cap_linux_wifi, _linux_bluetooth, _nrf_51822,
#                         _nrf_52840, _nrf_mousejack, _nxp_kw41z, _ti_cc_2531,
#                         _ti_cc_2540, _rz_killerbee, _hak5_wifi_coconut
#
# so installing the package hands EVERY local uid a setuid-root binary that
# manipulates network interfaces. The rpm even ships /usr/lib/sysusers.d/kismet.conf
# (contents: `g kismet -`) to create the group these should be gated on, and then
# never gates them on it. The niche helpers ARE locked down correctly
# (0104550 root:root — _sdr_rtl433, _sdr_rtladsb, _radiacode_usb, _serial_radview,
# _freaklabs_zigbee), which is what makes the 4755 set look like packaging
# oversight rather than intent.
#
# This rewrites the world-executable ones to 4750 root:kismet — setuid PRESERVED
# (the helpers genuinely need it; kismet's non-root model is built on them), group
# kismet may execute, everyone else may not. That is upstream kismet's own
# recommended layout.
#
# NOT 0750: dropping the setuid bit would leave the helpers unable to open a
# monitor-mode interface at all, and kismet would silently capture nothing.
#
# The already-restrictive 0104550 root:root helpers are left ALONE. They are
# root-only today, which is stricter than what this script applies, and they drive
# hardware this laptop does not have (RTL-SDR dongles, Radiacode, zigbee radios).
#
# Discovery is done by querying the rpm rather than hardcoding the list, so a
# Fedora version bump that adds or renames a helper is still covered.
#
# RUNTIME STEP THIS CANNOT DO: your account must join the group before kismet is
# usable as a non-root user —
#
#     sudo usermod -aG kismet "$USER"     # then log out and back in
#
# The image has no user to enroll (Atomic creates the account at install time), so
# that stays a per-machine action. See SETUP.
#
# ALTERNATIVE, if you would rather have zero setuid surface: chmod 0750 root:root
# instead and always run kismet under sudo. That is strictly more locked down; it
# just gives up the non-root workflow.
set -euo pipefail

# Fail loudly rather than no-op. Module order is build order, and a silent skip
# here would reproduce exactly the "built green, did nothing" failure mode the
# files-module ordering bug caused (see the note in recipes/recipe.yml).
if ! rpm -q kismet >/dev/null 2>&1; then
  echo "kismet-suid-scope: kismet is not installed — module ordering is wrong" >&2
  exit 1
fi

# The rpm has no scriptlets (verified with `rpm -qp --scripts`), so nothing has
# created the group yet; the sysusers.d file is only processed at boot on a real
# system. Create it now, at build time, from the packaged definition itself.
if ! getent group kismet >/dev/null; then
  systemd-sysusers /usr/lib/sysusers.d/kismet.conf
fi
getent group kismet >/dev/null || { echo "kismet-suid-scope: group kismet missing" >&2; exit 1; }

shopt -s nullglob
scoped=0

while IFS= read -r f; do
  # Only regular files that are setuid AND other-executable. This is the exact
  # 4755 set; the 4550 root-only helpers have no other-execute bit and are skipped.
  [[ -f $f ]] || continue
  [[ -u $f ]] || continue
  perm=$(stat -c '%a' "$f")
  [[ $(( 8#$perm & 8#0001 )) -ne 0 ]] || continue

  chgrp kismet "$f"
  chmod 4750 "$f"
  echo "kismet-suid-scope: $f -> $(stat -c '%a %U:%G' "$f")"
  scoped=$(( scoped + 1 ))
done < <(rpm -ql kismet | grep -E '/usr/bin/kismet_cap_')

# A future rpm that ships everything correctly gated would legitimately scope 0
# files. Report it instead of failing, but make it visible in the build log so the
# change is noticed rather than assumed.
if [[ $scoped -eq 0 ]]; then
  echo "kismet-suid-scope: no world-executable setuid helpers found — upstream may have fixed this; re-check the rpm"
else
  echo "kismet-suid-scope: scoped $scoped helper(s) to 4750 root:kismet"
fi
