#!/usr/bin/env bash
# Build a bootable qcow2 from the locally-built image (DESIGN §9.4).
#
# WHY THIS NEEDS ROOT: bootc-image-builder refuses to run under rootless podman
# ("this command must be run in rootful podman") — creating a partitioned,
# SELinux-labeled bootable disk needs loop devices and privileged mounts. QEMU
# boot afterwards does NOT need root (see boot-check.sh), only this build step.
#
# Run it with:   ! sudo bash vm/build-qcow2.sh
set -euo pipefail

cd "$(dirname "$0")/.."
. ./lib.sh
ARCHIVE="$(recipe_archive recipes/recipe.yml)"
IMAGE="localhost/$(recipe_tag recipes/recipe.yml)"
BIIB="quay.io/centos-bootc/bootc-image-builder:latest"

echo ">>> Loading ${IMAGE} into ROOT podman storage from ${ARCHIVE}"
# oci-archive carries the ref; load makes it available to rootful podman.
podman load -i "$ARCHIVE"
podman image exists "$IMAGE" || { echo "!! ${IMAGE} not in root storage after load"; podman images; exit 1; }

echo ">>> Building qcow2 with bootc-image-builder"
mkdir -p vm/output
podman run --rm --privileged --security-opt label=disable \
  -v "$PWD/vm/output":/output \
  -v "$PWD/vm/biib-config.toml":/config.toml:ro \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$BIIB" \
  build --type qcow2 --rootfs xfs "$IMAGE"
  # --rootfs is REQUIRED: the Fedora sway-atomic base is an ostree image and does
  # not declare a DefaultRootFs, so biib errors "missing required info:
  # DefaultRootFs" without it. xfs is only for this test disk; the real install
  # (DESIGN §10) uses btrfs subvols on LUKS, set up at install time, not here.

echo ">>> Done. Artifact:"
find vm/output -name '*.qcow2' -exec ls -lh {} \;
# Make the qcow2 readable/writable by the invoking (non-root) user for QEMU boot.
if [ -n "${SUDO_UID:-}" ]; then
  chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" vm/output
  echo ">>> chowned vm/output back to uid ${SUDO_UID}"
fi
