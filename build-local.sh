#!/usr/bin/env bash
# Local edit-compile-test loop for kb3lyb-shack (DESIGN §8.2: iterate locally, not
# via GitHub Actions). Generates a Containerfile with the BlueBuild CLI container,
# then builds it with host rootless podman.
#
# Why generate + podman build (not `bluebuild build`): the CLI's build driver
# expects to drive buildah/podman itself, which is awkward to nest under rootless
# podman on this Aurora host. Generating the Containerfile and building it directly
# keeps everything in the host's rootless podman storage.
#
# Why --security-opt label=disable: without it, podman execs the module scripts off
# a read-only bind mount and SELinux denies it ("Permission denied", exit 126).
set -euo pipefail

cd "$(dirname "$0")"
. ./lib.sh

RECIPE="${1:-recipes/recipe.yml}"
# Tag derived from the recipe itself (name + image-version), so the automated
# Fedora bump does not leave this pointing at the previous release. See lib.sh.
TAG="${TAG:-$(recipe_tag "$RECIPE")}"
REGISTRY="${REGISTRY:-ghcr.io}"
NAMESPACE="${NAMESPACE:-kb3lyb}"

echo ">>> Generating Containerfile from ${RECIPE}"
podman run --rm -v "$PWD":/build:Z -w /build ghcr.io/blue-build/cli:latest \
  bluebuild generate --registry "$REGISTRY" --registry-namespace "$NAMESPACE" \
  -o Containerfile "$RECIPE"

echo ">>> Building ${TAG}"
podman build --security-opt label=disable -f Containerfile -t "$TAG" .

echo ">>> Built ${TAG}"
podman images "${TAG%:*}"
