#!/usr/bin/env bash
# set-timezone.sh — bake America/New_York as the image default.
#
# Fedora's default when nothing sets a zone is UTC, and until now nothing here
# set one, so a fresh install came up on UTC.
#
# That never endangered a log, and it is worth writing down why, because the
# instinct is to assume it did. The kernel clock is a UTC epoch counter;
# /etc/localtime is only a presentation layer over it. "What is UTC right now"
# is answered identically whatever the zone is set to, which is why QLog stores
# every QSO with an explicit +00:00 offset and ADIF export carries bare
# UTC-by-spec QSO_DATE/TIME_ON. What UTC-as-local-zone actually meant is that
# every LOCAL clock on the machine was four hours out — and you stop noticing
# that precisely because the operating is conducted in UTC.
#
# The mirror image IS dangerous and is deliberately not done here: an RTC in
# local time plus a wrong zone yields wrong derived UTC, and then the logs are
# wrong too. Leave `RTC in local TZ: no` alone.
#
# WRITTEN AS A RELATIVE SYMLINK, NOT A COPIED TZif FILE. systemd reports the
# zone NAME by reading this link's target. Copy the file instead and glibc still
# resolves times correctly while `timedatectl status` reports "Time zone: n/a" —
# a half-working state that reads as a systemd bug and is not one. That is also
# why this is a script rather than a file dropped in files/system/etc: it makes
# the symlink-ness a build step that either happens or fails loudly, instead of
# depending on whether the files module's copy dereferences links.
#
# This is the image DEFAULT, not a lock. /etc is 3-way merged across rpm-ostree
# upgrades, so a later `timedatectl set-timezone` on a running machine is a local
# modification and survives.
set -euo pipefail

TZ_NAME="America/New_York"

[[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]] \
  || { echo "set-timezone: no such zone: ${TZ_NAME}" >&2; exit 1; }

ln -snf "../usr/share/zoneinfo/${TZ_NAME}" /etc/localtime
echo "set-timezone: /etc/localtime -> $(readlink /etc/localtime)"
