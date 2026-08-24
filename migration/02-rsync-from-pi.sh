#!/bin/bash
# Step 2 of the 1TB migration: copy the working 64-bit Trixie system off the Pi.
#
# File-level, not block-level: only ~5.7G of real data moves, and the target
# filesystem is already sized for the 1TB card. Safe to re-run - rsync resumes.
#
# Two passes, because the boot partition is FAT and cannot hold unix ownership
# or permissions; a single -aHAX pass over it produces a flood of chown/chmod
# errors and a non-zero exit that hides real problems.
set -euo pipefail

PI="$PI_USER@$PI_HOST"
KEY="$SSH_KEY"
TGT=/mnt/tgt
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

fail() { echo "FAILED: $*" >&2; exit 1; }

# --- preconditions ----------------------------------------------------------
findmnt -no SOURCE --target "$TGT" >/dev/null 2>&1 || fail "$TGT is not mounted (run step 1)"
findmnt -no SOURCE --target "$TGT/boot/firmware" >/dev/null 2>&1 \
    || fail "$TGT/boot/firmware is not mounted (run step 1)"
[ -r "$KEY" ] || fail "ssh key not readable: $KEY"
$SSH "$PI" true 2>/dev/null || fail "cannot reach the Pi at $PI"
$SSH "$PI" 'sudo -n true' 2>/dev/null || fail "no passwordless sudo on the Pi"
echo "preconditions ok - target mounted, Pi reachable"

echo "=== source size ==="
$SSH "$PI" 'df -h / | tail -1'

# --- pass 1: root filesystem ------------------------------------------------
# --numeric-ids so uids/gids are copied verbatim rather than remapped through
# this laptop's /etc/passwd, which has different accounts.
echo "=== 1/2 root filesystem ==="
rsync -aHAX --numeric-ids --info=progress2 --no-inc-recursive \
    -e "$SSH" --rsync-path="sudo rsync" \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*'  --exclude='/tmp/*' --exclude='/mnt/*' \
    --exclude='/media/*' --exclude='/lost+found' \
    --exclude='/swapfile' --exclude='/var/swap' \
    --exclude='/boot/firmware/*' \
    "$PI:/" "$TGT/" || fail "rootfs rsync"
echo "  rootfs copied"

# --- pass 2: boot partition (FAT: no perms/ownership) -----------------------
echo "=== 2/2 boot partition ==="
rsync -rlt --info=progress2 \
    -e "$SSH" --rsync-path="sudo rsync" \
    "$PI:/boot/firmware/" "$TGT/boot/firmware/" || fail "boot rsync"
echo "  boot copied"

# --- recreate the virtual-filesystem mountpoints we excluded ----------------
for d in proc sys dev run tmp mnt media; do mkdir -p "$TGT/$d"; done
chmod 1777 "$TGT/tmp"
echo "=== mountpoints recreated ==="

sync
echo "=== sizes ==="
df -h "$TGT" "$TGT/boot/firmware" | tail -2
echo "=== DONE - now run step 3 to fix PARTUUIDs ==="
