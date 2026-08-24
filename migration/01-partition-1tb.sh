#!/bin/bash
# Step 1 of the 1TB migration: repartition and format the target card.
#
# *** THIS DESTROYS EVERYTHING ON THE 1TB CARD. ***
#
# INTENT (matters for reviewing the choices below): step 2 is a FILE-LEVEL rsync
# of the working 64-bit Trixie system off the Pi. It is NOT a partclone restore.
# So the mkfs calls here are real work, and the UUIDs printed at the end are the
# ones the card will actually carry.
#
# LAYOUT: we replay the ORIGINAL table captured from this card rather than
# inventing one. That is deliberate and load-bearing:
#   - p2 keeps its original size (1999222784 sectors). A hand-rolled layout that
#     shifted the start made p2 ~263MiB smaller, and partclone refuses to restore
#     into a smaller target - which would have made root.pcl.zstd unrestorable to
#     the very card it came from, right after wiping the only physical copy.
#   - label-id 0xe22bcd10 is preserved, so PARTUUID=e22bcd10-01/-02 keep meaning
#     what they meant. A future restore of Experimental Pi image needs no hand-editing.
#   - p1 stays 256M/type=6/bootable to match. Trixie's boot files use ~49M of it,
#     and the Pi firmware does not care about the MBR type byte.
set -euo pipefail

DEV=/dev/mmcblk0
EXPECT_NAME="${EXPECT_NAME:?set to your card model, e.g. SR01T - see /sys/block/mmcblk0/device/name}"
EXPECT_SERIAL="${EXPECT_SERIAL:?set to your card serial - see /sys/block/mmcblk0/device/serial}"
IMG="$IMAGE_DIR"
TGT=/mnt/tgt

fail() { echo "FAILED: $*" >&2; exit 1; }

unmount_all() {                       # every mountpoint of every partition
    local p mp
    for p in "${DEV}"p*; do
        [ -b "$p" ] || continue
        while read -r mp; do
            [ -n "$mp" ] || continue
            umount "$mp" 2>/dev/null || udisksctl unmount -b "$p" >/dev/null 2>&1 || true
        done < <(findmnt -rno TARGET --source "$p" 2>/dev/null || true)
    done
}
assert_unmounted() {
    local p r
    for p in "${DEV}"p*; do
        [ -b "$p" ] || continue
        r=$(findmnt -rno TARGET --source "$p" 2>/dev/null || true)
        [ -z "$r" ] || fail "$p still mounted at: $r"
    done
}

# --- identity ---------------------------------------------------------------
SYS=/sys/block/$(basename "$DEV")/device
NAME=$(cat "$SYS/name" 2>/dev/null || echo "?")
SER=$(cat "$SYS/serial" 2>/dev/null || echo "?")
[ "$NAME" = "$EXPECT_NAME" ] && [ "$SER" = "$EXPECT_SERIAL" ] \
    || fail "wrong card: expected $EXPECT_NAME/$EXPECT_SERIAL, found $NAME/$SER"

# --- prove the backup is intact, not merely present -------------------------
# This is the last gate before a one-way door, so verify checksums rather than
# eyeballing a file size. A truncated archive passes a size check and then fails
# to decompress, long after the source is gone.
echo "=== verifying backup against MANIFEST (reads 23G, takes a few minutes) ==="
[ -s "$IMG/MANIFEST.txt" ] || fail "no MANIFEST.txt"
( cd "$IMG" && sha256sum -c <(grep -E "^[0-9a-f]{64}" MANIFEST.txt) ) \
    || fail "backup checksum mismatch - REFUSING to wipe the source"
echo "  backup verified"

# --- target must be idle ----------------------------------------------------
unmount_all
assert_unmounted

echo "target confirmed: $NAME $SER on $DEV ($(lsblk -bdno SIZE "$DEV" | numfmt --to=iec))"
echo "*** wiping in 5s - Ctrl-C to abort ***"; sleep 5

# --- partition: replay the captured original table --------------------------
echo "=== partitioning (restoring the original table) ==="
sfdisk "$DEV" < "$IMG/partition-table.sfdisk" || fail "sfdisk"
partprobe "$DEV" || true
udevadm settle || true
sleep 2

# udisks may auto-mount the new filesystems the instant they appear; the earlier
# unmount proved nothing about partitions that did not exist yet.
unmount_all
assert_unmounted
lsblk -o NAME,SIZE,TYPE "$DEV"

# --- format -----------------------------------------------------------------
echo "=== formatting ==="
mkfs.vfat -F 32 -n bootfs "${DEV}p1" >/dev/null || fail "mkfs.vfat"
echo "  p1 FAT32 ok"
# lazy_itable_init=0: do the inode-table work here rather than leaving the
# handheld to finish it in the background during its first boot.
mkfs.ext4 -F -L rootfs -E lazy_itable_init=0,lazy_journal_init=0 "${DEV}p2" >/dev/null \
    || fail "mkfs.ext4"
echo "  p2 ext4 ok"

unmount_all
assert_unmounted

# --- mount ------------------------------------------------------------------
echo "=== mounting at $TGT ==="
mkdir -p "$TGT"
mount "${DEV}p2" "$TGT"
mkdir -p "$TGT/boot/firmware"          # Trixie layout; step 2 copies a Trixie system
mount "${DEV}p1" "$TGT/boot/firmware"
findmnt -no SOURCE,TARGET,FSTYPE --target "$TGT"
findmnt -no SOURCE,TARGET,FSTYPE --target "$TGT/boot/firmware"
df -h "$TGT" | tail -1

echo "=== identifiers for step 3 (cmdline.txt / fstab) ==="
blkid "${DEV}p1" "${DEV}p2"
echo "=== DONE - target ready at $TGT ==="
