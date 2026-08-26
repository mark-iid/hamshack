#!/usr/bin/env bash
# Reconcile the build container's group numbering against the pinned GIDs in
# /usr/lib/sysusers.d/00-kb3lyb-gids.conf, and restamp anything already written
# with the old numbers.
#
# Read that file first — it carries the full explanation. In short: a chgrp
# records a number, these groups are dynamically allocated, and the build
# container and the installed machine allocate them in different orders. Files in
# /usr therefore end up owned by a group that means something else on the laptop.
#
# MUST RUN:
#   * AFTER the `files` module, which is what installs the pin file this reads.
#   * AFTER every dnf module, so all the packages that create these groups have
#     already run their sysusers scriptlets.
#   * (The laptop image also runs kismet-suid-scope.sh, which chgrps to `kismet`
#     by name. That script is not in this image — kismet is a wireless tool and
#     this is a wired desktop — but the ordering rule stands for anything that
#     resolves a group by name. It has to
#     resolve to the pinned number, not the one the container happened to pick.
#
# It hard-fails rather than no-ops if the pin file is missing, for the same reason
# every other script here does: a silent skip reproduces the "built green, did
# nothing" failure mode this repo keeps having to dig out of.
set -uo pipefail

PIN_FILE=/usr/lib/sysusers.d/00-kb3lyb-gids.conf

[ -r "$PIN_FILE" ] || {
  echo "pin-gids: $PIN_FILE missing — the files module must run before this script" >&2
  exit 1
}
command -v groupmod >/dev/null 2>&1 || {
  echo "pin-gids: groupmod not available" >&2
  exit 1
}

rc=0
changed=0

# `g <name> <gid>` lines only; ignore comments and any other sysusers directive.
while read -r kind name want _rest; do
  [ "$kind" = "g" ] || continue
  case "$want" in ''|*[!0-9]*) continue ;; esac

  have=$(getent group "$name" | cut -d: -f3)

  if [ -z "$have" ]; then
    # Not created in this build. Nothing is stamped with it either, so there is
    # nothing to reconcile — the pin file will still fix the number on the
    # installed system if the group appears there.
    echo "pin-gids: group '$name' not present in this build, skipping"
    continue
  fi

  if [ "$have" = "$want" ]; then
    echo "pin-gids: $name already $want"
    continue
  fi

  # Refuse to move a group onto a number something else already holds — that
  # would silently create two names for one GID, which is the class of problem
  # this script exists to remove.
  clash=$(getent group "$want" | cut -d: -f1)
  if [ -n "$clash" ] && [ "$clash" != "$name" ]; then
    echo "pin-gids: REFUSING to move $name -> $want; gid $want is held by '$clash'" >&2
    rc=1
    continue
  fi

  if ! groupmod -g "$want" "$name"; then
    echo "pin-gids: groupmod -g $want $name failed" >&2
    rc=1
    continue
  fi

  # groupmod only rewrites /etc/group. Anything already written to disk with the
  # OLD number keeps it, so restamp those explicitly. /usr is where it matters;
  # /etc is included because the factory copy of /etc is built here too (the
  # mosquitto config was a live instance of this).
  n=$(find /usr /etc -xdev -gid "$have" -print 2>/dev/null | wc -l)
  if [ "$n" -gt 0 ]; then
    find /usr /etc -xdev -gid "$have" -exec chgrp -h "$want" {} + 2>/dev/null
  fi
  echo "pin-gids: $name $have -> $want (restamped $n file(s))"
  changed=$((changed + 1))
done < "$PIN_FILE"

# The fonts module runs as the build user and leaves its own uid/gid on what it
# unpacks (observed: the Nerd Fonts tree at gid 1001). Nothing in a system image
# should carry a login-range gid; it resolves to nothing at all on the laptop.
strays=$(find /usr -xdev -gid +999 -print 2>/dev/null | wc -l)
if [ "$strays" -gt 0 ]; then
  find /usr -xdev -gid +999 -exec chgrp -h 0 {} + 2>/dev/null
  echo "pin-gids: reset $strays file(s) owned by a build-user gid to root"
fi

echo "pin-gids: done ($changed group(s) renumbered)"
exit "$rc"
