#!/bin/bash
# Verify step 2 actually copied everything, before we commit to the new card.
#
# Counting files by hand does not settle this: an unprivileged scan cannot see
# inside root-only directories, so the numbers never reconcile. rsync itself is
# the authority - run the same transfer with -n and see what it still wants to do.
#
# A perfectly empty result is NOT expected. The Pi is running, so logs, journal
# files and caches have moved on since the copy started. What matters is that
# nothing SUBSTANTIVE is missing: no binaries, no config, no units, no home data.
set -euo pipefail

PI="$PI_USER@$PI_HOST"
KEY="$SSH_KEY"
TGT=/mnt/tgt
OUT="$IMAGE_DIR"/verify-diff.txt
OWNER=$USER
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

trap 'chown "$OWNER:$OWNER" "$OUT" 2>/dev/null || true' EXIT
fail() { echo "FAILED: $*" >&2; exit 1; }

findmnt -no SOURCE --target "$TGT" >/dev/null 2>&1 || fail "$TGT is not mounted"
findmnt -no SOURCE --target "$TGT/boot/firmware" >/dev/null 2>&1 || fail "$TGT/boot/firmware is not mounted"

echo "=== dry-run compare (metadata only, no data moves) ==="
# Same flags and excludes as step 2, so a difference here means a real difference.
rsync -aHAX --numeric-ids -n --itemize-changes \
    -e "$SSH" --rsync-path="sudo rsync" \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*'  --exclude='/tmp/*' --exclude='/mnt/*' \
    --exclude='/media/*' --exclude='/lost+found' \
    --exclude='/swapfile' --exclude='/var/swap' \
    --exclude='/boot/firmware/*' \
    "$PI:/" "$TGT/" > "$OUT" 2>&1 || fail "rsync dry-run"

TOTAL=$(wc -l < "$OUT")

# Churn we expect from a live system, and do not care about.
VOLATILE='^[^ ]+ (var/log/|var/cache/|var/tmp/|var/lib/systemd/|var/lib/NetworkManager/|var/lib/dhcpcd|var/lib/bluetooth/|var/spool/|home/[^/]+/\.cache/|home/[^/]+/\.local/share/Trash/|etc/machine-id|root/\.cache/)'
# Lines starting with a bare '.' and only permission/time flags are metadata-only.
SUBSTANTIVE=$(grep -Ev "$VOLATILE" "$OUT" | grep -E '^(>f|<f|cd|cL|hf|\*deleting)' || true)

echo "  total differences: $TOTAL   (full list: $OUT)"
echo "=== differences that are NOT expected live-system churn ==="
if [ -z "$SUBSTANTIVE" ]; then
    echo "  none - every real file, symlink and directory is present and identical"
else
    echo "$SUBSTANTIVE" | head -60 | sed 's/^/  /'
    n=$(echo "$SUBSTANTIVE" | wc -l)
    (( n > 60 )) && echo "  ... and $((n-60)) more (see $OUT)"
    echo ""
    echo "  ^ review these before running step 3."
fi
