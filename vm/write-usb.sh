#!/usr/bin/env bash
# Write the installer ISO to a USB stick. Run with sudo.
#
#     sudo bash vm/write-usb.sh /dev/sdX
#
# This is the single most destructive command in this repo: it overwrites the
# target device unconditionally. Everything below exists to make it hard to point
# at the wrong one. The guards are not paranoia — on this machine /dev/sda is a
# 1 TB disk holding /var/mnt/data, one letter away from the intended target.
set -euo pipefail
cd "$(dirname "$0")/.."

ISO="vm/output/bootiso/install.iso"
DEV="${1:-}"

[ -n "$DEV" ]   || { echo "!! usage: sudo bash vm/write-usb.sh /dev/sdX" >&2; exit 1; }
[ -f "$ISO" ]   || { echo "!! $ISO missing — run: sudo bash vm/build-iso.sh" >&2; exit 1; }
[ -b "$DEV" ]   || { echo "!! $DEV is not a block device" >&2; exit 1; }

# Guard 1: whole disk only. Writing an ISO to a PARTITION produces a stick that
# looks written and will not boot.
case "$DEV" in *[0-9]) echo "!! $DEV looks like a partition; pass the whole disk (/dev/sdb, not /dev/sdb1)" >&2; exit 1;; esac

# Guard 2: must be USB. This is what stops a typo from reaching an internal disk.
TRAN=$(lsblk -dno TRAN "$DEV")
[ "$TRAN" = "usb" ] || { echo "!! $DEV is transport '$TRAN', not usb — refusing" >&2; exit 1; }

# Guard 3: nothing on it may be mounted. Catches the data drive directly: its
# partition is mounted at /var/mnt/data, so this refuses before anything is written.
MOUNTED=$(lsblk -no MOUNTPOINT "$DEV" | grep -v '^$' || true)
[ -z "$MOUNTED" ] || { echo "!! $DEV has mounted filesystems, refusing:"; echo "$MOUNTED"; exit 1; }

# Guard 4: refuse anything big enough to be a data disk rather than a stick.
SIZE=$(lsblk -dnbo SIZE "$DEV")
[ "$SIZE" -le $((256*1000*1000*1000)) ] || { echo "!! $DEV is $((SIZE/1000000000)) GB — too large to be the intended USB stick; refusing" >&2; exit 1; }

echo ">>> TARGET: $DEV"
lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL,SERIAL "$DEV"
echo ">>> SOURCE: $ISO ($(du -h "$ISO" | cut -f1))"
echo
echo ">>> Everything on $DEV will be DESTROYED."
read -r -p ">>> Type the device name again to confirm: " CONFIRM
[ "$CONFIRM" = "$DEV" ] || { echo "!! mismatch, aborting"; exit 1; }

echo ">>> writing (this takes a while for 6.2 GB)"
dd if="$ISO" of="$DEV" bs=4M status=progress conv=fsync oflag=direct
sync
echo ">>> verifying the first 6 GB read back identical"
ISOSUM=$(sha256sum "$ISO" | cut -d' ' -f1)
DEVSUM=$(head -c "$(stat -c%s "$ISO")" "$DEV" | sha256sum | cut -d' ' -f1)
if [ "$ISOSUM" = "$DEVSUM" ]; then
  echo ">>> OK — $DEV matches the ISO. Bootable installer ready."
else
  echo "!! MISMATCH — the write did not land correctly. Do NOT boot this stick." >&2
  echo "!!   iso: $ISOSUM" >&2
  echo "!!   dev: $DEVSUM" >&2
  exit 1
fi
