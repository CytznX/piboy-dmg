#!/bin/bash
# Capture the original PiBoy DMG card (Experimental Pi's RetroPie 4.8.12 / Raspbian buster).
#
# The card's *contents* are never modified: no image is written back to it. Note
# that unmounting does write to the card (journal close, superblock update) - it
# is not untouched at the block level, but its filesystems are left consistent.
#
# This is a one-shot capture of an irreplaceable card, so it fails loudly rather
# than reporting a success it cannot prove.
set -euo pipefail

OUT="$IMAGE_DIR"
DEV=/dev/mmcblk0
COMP=zstd
OWNER=$USER
EXPECT_NAME="${EXPECT_NAME:?set to your card model, e.g. SR01T - see /sys/block/mmcblk0/device/name}"
EXPECT_SERIAL="${EXPECT_SERIAL:?set to your card serial - see /sys/block/mmcblk0/device/serial}"

SYS=/sys/block/$(basename "$DEV")/device      # derived from $DEV, not hardcoded
LOG=$OUT/capture.log

# Root-owned leftovers in a user's home are hostile on every path, not just success.
trap 'chown -R "$OWNER:$OWNER" "$OUT" 2>/dev/null || true' EXIT

fail() { echo "FAILED: $*" >&2; exit 1; }

mounted_targets() {                            # every mountpoint of a partition
    findmnt -rno TARGET --source "$1" 2>/dev/null || true
}

# --- identity guard -------------------------------------------------------
NAME=$(cat "$SYS/name" 2>/dev/null || echo "?")
SER=$(cat "$SYS/serial" 2>/dev/null || echo "?")
[ "$NAME" = "$EXPECT_NAME" ] && [ "$SER" = "$EXPECT_SERIAL" ] \
    || fail "wrong card: expected $EXPECT_NAME/$EXPECT_SERIAL, found $NAME/$SER"
echo "target confirmed: $NAME $SER on $DEV"

# --- refuse to clobber an existing good capture ---------------------------
for f in "$OUT/boot.pcl.$COMP" "$OUT/root.pcl.$COMP"; do
    [ -e "$f" ] && fail "$f already exists - move it aside rather than overwrite the only copy"
done

# --- unmount, and verify it actually happened -----------------------------
echo "=== unmounting (imaging a mounted fs gives an inconsistent snapshot) ==="
for p in "${DEV}p1" "${DEV}p2"; do
    while read -r mp; do
        [ -n "$mp" ] || continue
        umount "$mp" 2>/dev/null || udisksctl unmount -b "$p" >/dev/null 2>&1 || true
    done < <(mounted_targets "$p")
done
for p in "${DEV}p1" "${DEV}p2"; do
    remaining=$(mounted_targets "$p")
    [ -z "$remaining" ] || fail "$p still mounted at: $remaining"
done
echo "  both partitions unmounted"

# --- capture --------------------------------------------------------------
# Written to .part and renamed only on proven success, so an aborted run can
# never be mistaken for a finished image.
echo "=== 1/3 partition table ==="
sfdisk --dump "$DEV" > "$OUT/partition-table.sfdisk.part" || fail "sfdisk"
mv "$OUT/partition-table.sfdisk.part" "$OUT/partition-table.sfdisk"
echo "  ok"

capture() {   # $1=partclone binary  $2=source partition  $3=output name  $4=label
    local bin=$1 src=$2 base=$3 label=$4
    local -a st
    echo "=== $label ==="
    set +e
    "$bin" -c -s "$src" -o - 2>>"$LOG" | "$COMP" > "$OUT/$base.part"
    st=("${PIPESTATUS[@]}")
    set -e
    [ "${st[0]}" -eq 0 ] || fail "$bin exited ${st[0]} - see $LOG"
    [ "${st[1]}" -eq 0 ] || fail "$COMP exited ${st[1]}"
    # A compressor produces a valid empty stream from zero input, so size is the
    # only thing that distinguishes "compressed nothing" from a real capture.
    local sz; sz=$(stat -c%s "$OUT/$base.part")
    [ "$sz" -gt 1048576 ] || fail "$base is only $sz bytes - no real data captured"
    mv "$OUT/$base.part" "$OUT/$base"
    echo "  ok: $(du -h "$OUT/$base" | cut -f1)"
}

# partclone.vfat, not partclone.dd: dd-mode is a raw whole-partition copy and
# does not accept -c, whereas the vfat backend walks the FAT and copies only
# allocated clusters - same treatment as the root filesystem.
capture partclone.vfat "${DEV}p1" "boot.pcl.$COMP" "2/3 boot partition (256M, ~49M used)"
capture partclone.ext4 "${DEV}p2" "root.pcl.$COMP" "3/3 root filesystem (939G partition, ~35G used)"

# --- manifest -------------------------------------------------------------
{
    echo "PiBoy DMG original card image"
    echo "captured: $(date -Iseconds)"
    echo "card: $NAME serial $SER (SanDisk 1TB, mfg $(cat "$SYS/date" 2>/dev/null || echo '?'))"
    echo "contents: RetroPie 4.8.12 on Raspbian 10 (buster), 32-bit"
    echo "compressor: $COMP"
    echo "restore: target partition must be >= the original 939G"
    echo ""
    sha256sum "$OUT/boot.pcl.$COMP" "$OUT/root.pcl.$COMP" "$OUT/partition-table.sfdisk"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
echo "=== DONE $(date +%H:%M:%S) ==="
