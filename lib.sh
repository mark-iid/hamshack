# lib.sh — helpers shared by build-local.sh and the vm/ scripts.
# Sourced, not executed. Every caller cds to the repo root first.

# One top-level scalar field out of a BlueBuild recipe:  recipe_field <file> <key>
# Anchored at column 0 so it only ever matches the recipe's own header, never an
# indented module key.
recipe_field() {
  sed -n "s/^$2:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$1" | head -1
}

# The localhost image ref a recipe builds to: <name>:<image-version>.
#
# DERIVED, NEVER HARDCODED. The Fedora bump is automated
# (.github/workflows/fedora-version-bump.yml) and rewrites `image-version` in
# recipes/ and nothing else. A tag hardcoded here would keep saying 44 while the
# recipe built 45 — so the local build would tag new bits with the old version,
# and the vm/ scripts would go looking for that tag and either use a lying name or
# pick up a genuinely stale image still in podman storage. That would land on the
# one build that matters most: the VM validation of a major version bump, before
# the laptop is allowed anywhere near it.
recipe_tag() {
  _rt_name=$(recipe_field "$1" name)
  _rt_ver=$(recipe_field "$1" image-version)
  if [ -z "$_rt_name" ] || [ -z "$_rt_ver" ]; then
    echo "lib.sh: could not read name/image-version from $1" >&2
    return 1
  fi
  printf '%s:%s\n' "$_rt_name" "$_rt_ver"
}

# The OCI archive vm/ round-trips the image through: vm/<name>.oci.
#
# DERIVED FOR THE SAME REASON AS recipe_tag, plus one more. In the repo this was
# forked from the three vm/ scripts each spelled this name as a literal, so
# renaming the image silently split them: export-image.sh would write the new
# name while build-qcow2.sh went looking for the old one and either failed or —
# worse — found a genuinely stale archive from a previous image and built a disk
# from it. Read the name from the recipe and that class of bug cannot occur.
recipe_archive() {
  _ra_name=$(recipe_field "$1" name)
  if [ -z "$_ra_name" ]; then
    echo "lib.sh: could not read name from $1" >&2
    return 1
  fi
  printf 'vm/%s.oci\n' "$_ra_name"
}
