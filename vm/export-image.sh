#!/usr/bin/env bash
# Refresh vm/<image-name>.oci from the CURRENT locally-built image (rootless).
# build-qcow2.sh and build-iso.sh load the disk from this archive; run this first
# whenever the image has been rebuilt, or the disk will be built from a stale image.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./lib.sh

IMAGE="${IMAGE:-localhost/$(recipe_tag recipes/recipe.yml)}"
ARCHIVE="$(recipe_archive recipes/recipe.yml)"

podman image exists "$IMAGE" || { echo "!! $IMAGE not in local storage — build it first (./build-local.sh)"; exit 1; }
echo ">>> exporting $IMAGE -> $ARCHIVE (rootless)"
rm -f "$ARCHIVE"
skopeo copy "containers-storage:$IMAGE" "oci-archive:$ARCHIVE:$IMAGE"
echo ">>> done: $(ls -lh "$ARCHIVE" | awk '{print $5}')"
echo ">>> next (needs sudo — biib is rootful):"
echo "      sudo bash vm/build-qcow2.sh    # qcow2 for VM boot"
echo "      sudo bash vm/build-iso.sh      # Anaconda installer ISO"
