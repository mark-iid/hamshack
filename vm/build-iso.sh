#!/usr/bin/env bash
# Build an Anaconda INSTALLER ISO from the image (DESIGN §9.8 / §10). Rootful:
# bootc-image-builder refuses rootless (loop devices / SELinux labeling).
#
#   bash vm/export-image.sh          # refresh the archive from the current image
#   sudo bash vm/build-iso.sh        # then build the ISO
#
# IMPORTANT (DESIGN §10): this is an Anaconda INSTALLER, not a live desktop. Boot
# it to *install* onto a target disk; first boot of the installed system is the
# final niri desktop.
#
# ⚠️  --type anaconda-iso IS UNATTENDED BY DEFAULT. With no kickstart it installs
# to the FIRST DISK IT FINDS with no prompt and no encryption — it WILL silently
# wipe a drive (this is not hypothetical; it already destroyed one machine's
# internal NVMe). We force an INTERACTIVE install by passing vm/iso-config.toml
# (an empty [customizations.installer.kickstart]); Anaconda then stops at its hub
# so you pick the disk, btrfs-on-LUKS partitioning, and user account yourself.
# NEVER build this ISO without that config mounted. Partitioning/LUKS/user are
# chosen interactively; no test-user is baked in (unlike the throwaway qcow2).
# Confirm the target disk by serial/size before proceeding — that selection is
# the dangerous step (DESIGN §10).
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

ARCHIVE="$(recipe_archive recipes/recipe.yml)"
IMAGE="localhost/$(recipe_tag recipes/recipe.yml)"
BIIB="quay.io/centos-bootc/bootc-image-builder:latest"

[ -f "$ARCHIVE" ] || { echo "!! $ARCHIVE missing — run: bash vm/export-image.sh"; exit 1; }

echo ">>> loading $IMAGE into root podman storage"
podman load -i "$ARCHIVE"
podman image exists "$IMAGE" || { echo "!! $IMAGE not loaded"; podman images; exit 1; }

CONFIG="vm/iso-config.toml"
[ -f "$CONFIG" ] || { echo "!! $CONFIG missing — refusing to build an UNATTENDED disk-wiping ISO without the interactive-install config"; exit 1; }

echo ">>> building anaconda-iso (INTERACTIVE — via $CONFIG)"
mkdir -p vm/output
# --rootfs is still required at manifest time (sway-atomic base declares no
# DefaultRootFs). It sets the default for automatic partitioning only; pick
# btrfs-on-LUKS interactively in Anaconda's custom partitioning (DESIGN §10).
# The $CONFIG mount (empty installer kickstart) is what makes Anaconda interactive
# instead of silently wiping the first disk — see the header note.
podman run --rm --privileged --security-opt label=disable \
  -v "$PWD/vm/output":/output \
  -v "$PWD/$CONFIG":/config.toml:ro \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$BIIB" \
  build --type anaconda-iso --rootfs xfs "$IMAGE"

echo ">>> done. Artifact:"
find vm/output -name '*.iso' -exec ls -lh {} \;
if [ -n "${SUDO_UID:-}" ]; then
  chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" vm/output
  echo ">>> chowned vm/output back to uid ${SUDO_UID}"
fi
