#!/bin/bash
# Step 3 of the 1TB migration: point the copied system at the card it now lives on.
#
# The rsync in step 2 copied /etc/fstab and cmdline.txt verbatim, so they still
# name the 32GB card's PARTUUIDs (2b36ac92-*). Left alone the Pi drops to an
# initramfs prompt on first boot: the firmware finds kernel+cmdline fine (it
# reads the FAT partition it booted from, by position), but the kernel then
# looks for a root device that is not in this machine.
#
# Entries are matched by MOUNTPOINT, not by substituting the old UUID string.
# A blind s/old/new/ cannot tell p1's entry from p2's, so if the two were ever
# swapped or a third entry appeared it would map them wrong and still "succeed".
#
# Idempotent, and safe to re-run: it derives the new values from blkid each time.
set -euo pipefail

DEV=/dev/mmcblk0
TGT=/mnt/tgt
EXPECT_NAME="${EXPECT_NAME:?set to your card model, e.g. SR01T - see /sys/block/mmcblk0/device/name}"
EXPECT_SERIAL="${EXPECT_SERIAL:?set to your card serial - see /sys/block/mmcblk0/device/serial}"

fail() { echo "FAILED: $*" >&2; exit 1; }

# --- identity: never rewrite a system on a card we did not build -------------
SYS=/sys/block/$(basename "$DEV")/device
NAME=$(cat "$SYS/name" 2>/dev/null || echo "?")
SER=$(cat "$SYS/serial" 2>/dev/null || echo "?")
[ "$NAME" = "$EXPECT_NAME" ] && [ "$SER" = "$EXPECT_SERIAL" ] \
    || fail "wrong card: expected $EXPECT_NAME/$EXPECT_SERIAL, found $NAME/$SER"

# --- preconditions -----------------------------------------------------------
findmnt -no SOURCE --target "$TGT" >/dev/null 2>&1 || fail "$TGT is not mounted"
findmnt -no SOURCE --target "$TGT/boot/firmware" >/dev/null 2>&1 \
    || fail "$TGT/boot/firmware is not mounted"

# Running this while step 2 is still copying would be undone by the copy itself.
pgrep -f "rsync.*$TGT" >/dev/null 2>&1 && fail "step 2 rsync is still running - wait for it"

FSTAB=$TGT/etc/fstab
CMDLINE=$TGT/boot/firmware/cmdline.txt
[ -f "$FSTAB" ]   || fail "$FSTAB missing - did step 2 finish?"
[ -f "$CMDLINE" ] || fail "$CMDLINE missing - did step 2's boot pass run?"

P1=$(blkid -s PARTUUID -o value "${DEV}p1") || fail "no PARTUUID on ${DEV}p1"
P2=$(blkid -s PARTUUID -o value "${DEV}p2") || fail "no PARTUUID on ${DEV}p2"
[ -n "$P1" ] && [ -n "$P2" ] || fail "empty PARTUUID"
echo "target: p1=$P1  p2=$P2"

# --- back up the originals ---------------------------------------------------
for f in "$FSTAB" "$CMDLINE"; do
    [ -f "$f.premigrate" ] || cp -a "$f" "$f.premigrate"
done
echo "  originals saved as *.premigrate"

# --- fstab: rewrite by mountpoint -------------------------------------------
awk -v p1="$P1" -v p2="$P2" '
    /^[[:space:]]*#/ || NF < 2 { print; next }
    $2 == "/"              { $1 = "PARTUUID=" p2 }
    $2 == "/boot/firmware" { $1 = "PARTUUID=" p1 }
    { print }
' "$FSTAB" > "$FSTAB.new" || fail "awk on fstab"
# Column alignment is cosmetic, but fstab is a file humans edit under pressure.
column -t "$FSTAB.new" > "$FSTAB.tmp" && mv "$FSTAB.tmp" "$FSTAB.new"
mv "$FSTAB.new" "$FSTAB"
echo "=== fstab ==="; sed 's/^/  /' "$FSTAB"

# --- cmdline.txt: replace the root= token only -------------------------------
# cmdline.txt must stay ONE line - the firmware reads the first line only, and a
# stray newline silently truncates every parameter after it.
sed -i -E "s#root=PARTUUID=[0-9a-fA-F-]+#root=PARTUUID=${P2}#" "$CMDLINE" || fail "sed on cmdline"
[ "$(wc -l < "$CMDLINE")" -le 1 ] || fail "cmdline.txt gained a newline"
echo "=== cmdline.txt ==="; sed 's/^/  /' "$CMDLINE"

# --- prove it: no stale references, and the new ones resolve to this card ----
grep -q "root=PARTUUID=${P2}" "$CMDLINE" || fail "cmdline.txt has no root=PARTUUID=$P2"
grep -qE "^PARTUUID=${P2}[[:space:]]+/[[:space:]]" "$FSTAB" || fail "fstab root entry not rewritten"
grep -qE "^PARTUUID=${P1}[[:space:]]+/boot/firmware" "$FSTAB" || fail "fstab boot entry not rewritten"

# Anything still naming a PARTUUID that is not on this card would fail at boot.
STALE=$(grep -hoE 'PARTUUID=[0-9a-fA-F]{8}-[0-9]{2}' "$FSTAB" "$CMDLINE" | sort -u \
        | grep -v -e "$P1" -e "$P2" || true)
[ -z "$STALE" ] || fail "stale PARTUUID still referenced: $STALE"
echo "  no stale PARTUUIDs in fstab or cmdline"

# Experimental Pi overlay lines live in config.txt; a truncated copy boots to a black
# screen, so confirm the long-line workaround survived the copy.
CFG=$TGT/boot/firmware/config.txt
if [ -f "$CFG" ]; then
    if grep -q '^dtoverlay=vc4-kms-dpi-generic' "$CFG" && grep -q '^dtparam=vactive=480' "$CFG"; then
        echo "  DPI panel overlay present and split into dtparam= lines"
    else
        echo "WARNING: DPI overlay lines look wrong in $CFG - check before booting" >&2
    fi
    LONG=$(awk 'length > 98 && !/^[[:space:]]*#/ {print FNR": "length" chars"}' "$CFG")
    [ -z "$LONG" ] || echo "WARNING: config.txt lines over 98 chars (firmware truncates): $LONG" >&2
fi

sync
echo "=== DONE - card is bootable. Shut down, move it to the PiBoy, power on. ==="
