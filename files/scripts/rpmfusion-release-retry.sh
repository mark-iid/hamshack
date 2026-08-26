#!/usr/bin/env bash
# Pre-seed the RPM Fusion release RPMs, with retries and a mirror fallback.
# Runs at image build time, IMMEDIATELY BEFORE the codecs dnf module.
#
# WHY THIS EXISTS
#
# The codecs module is the first module in the build and it declares
# `repos: {nonfree: rpmfusion}`. The BlueBuild dnf module implements that by
# fetching two release RPMs straight off the MirrorManager redirector:
#
#     https://mirrors.rpmfusion.org/{free,nonfree}/fedora/
#         rpmfusion-{free,nonfree}-release-$OS_VERSION.noarch.rpm
#
# and handing the URLs to `dnf install`. librepo gets one 30 s connect timeout
# per mirror and no backoff, so a slow or dead mirror fails the ENTIRE image
# before a single package is considered. That is exactly what happened on
# 2026-08-17 (run 32074991347): mirror.fcix.net timed out four times in a row
# and the redirector's other candidate, repos.eggycrew.com, did not resolve at
# all. Nothing was wrong with the recipe; the build simply had no retry.
#
# HOW IT HOOKS IN — this does NOT replace the module's repo handling.
#
# dnf.nu's enable_rpmfusion is guarded on `rpm -q rpmfusion-free-release` (and
# nonfree) and only downloads when the query FAILS. So installing the release
# RPMs here makes that download a no-op, while everything else the module does
# still runs untouched — notably `dnf config-manager setopt
# fedora-cisco-openh264.enabled=1`, which RPM Fusion needs and which is easy to
# lose if you "simplify" this by dropping the `repos:` key from codecs.yml.
# Don't drop it. This script is a fast path, not a replacement.
#
# Consequence worth knowing: if this script somehow fails to install them, the
# module's own fetch is still there as a fallback and the build can still go
# green. That is deliberate — this is belt-and-braces, so it exits nonzero only
# when it is certain it could not do its job.
#
# TWO SOURCES, tried in order per attempt:
#   mirrors.rpmfusion.org   the MirrorManager redirector — normally fastest,
#                           and the source that failed above
#   download1.rpmfusion.org RPM Fusion's own origin host. Not a mirror, so it
#                           is unaffected by any one mirror going bad. Slower
#                           under load, which is why it is second, not first.
#
# GPG: unchanged from the module's behaviour. dnf5 defaults localpkg_gpgcheck
# to false, and a release RPM is signed by a key the rpmdb does not have yet —
# a bootstrap chicken-and-egg that installing from URL has too. What IS added
# is a magic-byte check, so a captive portal or an HTML 404 body cannot be fed
# to `dnf install` as if it were a package.
set -euo pipefail

readonly RETRIES=4
readonly MIRRORS=(
  'https://mirrors.rpmfusion.org'
  'https://download1.rpmfusion.org'
)

# BlueBuild exports OS_VERSION to modules, but fall back to the image's own
# os-release so this still works if run by hand in a debug shell.
version="${OS_VERSION:-}"
if [[ -z $version ]]; then
  # shellcheck disable=SC1091
  version="$(. /usr/lib/os-release && printf '%s' "${VERSION_ID:-}")"
fi
if [[ -z $version ]]; then
  echo 'rpmfusion-release-retry: cannot determine Fedora version' >&2
  exit 1
fi

# Only fetch what is actually missing — same guard the dnf module uses, so a
# rebuild against a warm cache does no network work at all.
scopes=()
rpm -q rpmfusion-free-release    >/dev/null 2>&1 || scopes+=('free')
rpm -q rpmfusion-nonfree-release >/dev/null 2>&1 || scopes+=('nonfree')

if [[ ${#scopes[@]} -eq 0 ]]; then
  echo 'rpmfusion-release-retry: both release packages already present, nothing to do'
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

downloaded=()
for scope in "${scopes[@]}"; do
  rpmfile="rpmfusion-${scope}-release-${version}.noarch.rpm"
  out="$tmp/$rpmfile"
  got=0

  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    for base in "${MIRRORS[@]}"; do
      url="$base/$scope/fedora/$rpmfile"

      if ! curl --fail --location --silent --show-error \
                --connect-timeout 15 --max-time 120 \
                --retry 2 --retry-delay 2 --retry-all-errors \
                --output "$out" "$url"; then
        echo "rpmfusion-release-retry: attempt $attempt failed: $url" >&2
        continue
      fi

      # RPM lead magic is ed ab ee db. Anything else is a mirror serving an
      # error page with a 200, which curl --fail cannot catch.
      if [[ "$(head -c4 "$out" | od -An -tx1 | tr -d ' \n')" != 'edabeedb' ]]; then
        echo "rpmfusion-release-retry: $url returned non-RPM content, discarding" >&2
        rm -f "$out"
        continue
      fi

      echo "rpmfusion-release-retry: fetched $rpmfile from $base"
      got=1
      break 2
    done

    # Linear backoff. The observed failure was a mirror that was slow rather
    # than down, so giving MirrorManager time to hand out a different one is
    # worth more here than hammering immediately.
    if [[ $attempt -lt $RETRIES ]]; then
      sleep $((attempt * 5))
    fi
  done

  if [[ $got -ne 1 ]]; then
    echo "rpmfusion-release-retry: exhausted $RETRIES attempts across ${#MIRRORS[@]} sources for $rpmfile" >&2
    exit 1
  fi

  downloaded+=("$out")
done

dnf install -y "${downloaded[@]}"

# Verify rather than trust the exit code: the whole point is that the codecs
# module's guard sees these as installed, so assert exactly that condition.
for scope in "${scopes[@]}"; do
  if ! rpm -q "rpmfusion-${scope}-release" >/dev/null 2>&1; then
    echo "rpmfusion-release-retry: rpmfusion-${scope}-release still not installed after dnf" >&2
    exit 1
  fi
done

echo "rpmfusion-release-retry: seeded ${scopes[*]} release package(s) for Fedora $version"
