#!/bin/bash
# Step 4 of the 1TB migration: put the ROMs and BIOS files back.
#
# THIS RUNS ON THE PIBOY, not on the laptop - the USB stick and the card are
# both attached to the Pi, so this is a local disk-to-disk copy. Pushing 26G
# over the network instead would take hours; here it is limited only by USB.
#
# Deliberately NOT restored: retropie-configs.tar.gz and home-pi-dotfiles.tar.gz.
# Those came off 32-bit RetroPie on buster and name emulator binaries and paths
# that do not exist in this build; dropping them in wholesale replaces a working
# configuration with one that points at nothing. Cherry-pick from them by hand
# later if a specific per-game setting is worth recovering.
set -euo pipefail

USB=/dev/sda1
MNT=/mnt/usb
DEST=$HOME/RetroPie
VERIFY=1

usage() { echo "usage: $0 [--skip-verify]"; exit 2; }
for a in "$@"; do
    case "$a" in
        --skip-verify) VERIFY=0 ;;
        *) usage ;;
    esac
done

fail() { echo "FAILED: $*" >&2; exit 1; }

# Extracting as root would leave every ROM owned by root, and EmulationStation
# runs as this user - it could read them but never write a gamelist or scrape.
[ "$(id -u)" -ne 0 ] || fail "run this as your normal user, not with sudo"
sudo -n true 2>/dev/null || fail "need passwordless sudo to mount the stick"

[ -b "$USB" ] || fail "$USB not present - is the stick plugged in?"

# Mount read-only: the stick is the only copy of these ROMs until they land.
sudo mkdir -p "$MNT"
mountpoint -q "$MNT" || sudo mount -o ro "$USB" "$MNT" || fail "cannot mount $USB"
trap 'sudo umount "$MNT" 2>/dev/null || true' EXIT

# Newest backup if the stick ever holds more than one.
B=$(ls -1d "$MNT"/piboy-backup-* 2>/dev/null | sort | tail -1) || true
[ -n "${B:-}" ] && [ -d "$B" ] || fail "no piboy-backup-* directory on the stick"
echo "restoring from: $(basename "$B")"

[ -d "$B/roms" ] || fail "$B/roms missing"

# --- space check ------------------------------------------------------------
# The rom tars are uncompressed, so their size is very close to the extracted
# size; BIOS.tar.gz is gzipped but small enough that its slack does not matter.
NEED=$(du -sb "$B/roms" "$B/BIOS.tar.gz" 2>/dev/null | awk '{s+=$1} END{print s}')
mkdir -p "$DEST/roms"
AVAIL=$(df -B1 --output=avail "$DEST" | tail -1)
echo "need $(numfmt --to=iec "$NEED"), free $(numfmt --to=iec "$AVAIL")"
(( AVAIL > NEED + 2147483648 )) || fail "not enough free space (want need+2G)"

# --- verify the archives before trusting them -------------------------------
# MD5SUMS paths are relative to the backup root, so check from there.
if (( VERIFY )); then
    echo "=== verifying checksums (reads 26G - several minutes) ==="
    [ -f "$B/MD5SUMS" ] || fail "no MD5SUMS to verify against"
    ( cd "$B" && md5sum -c --quiet MD5SUMS ) || fail "checksum mismatch - do NOT trust this backup"
    echo "  all archives verified"
else
    echo "=== skipping checksum verification (--skip-verify) ==="
fi

# --- BIOS -------------------------------------------------------------------
# psx, segacd, nds and neogeo are all non-functional without these.
echo "=== BIOS ==="
tar -xf "$B/BIOS.tar.gz" -C "$DEST"
echo "  ok: $(du -sh "$DEST/BIOS" | cut -f1)"

# --- roms, one system at a time so a single bad tar does not lose the rest ---
echo "=== roms ==="
failed=()
for t in "$B"/roms/*.tar; do
    [ -e "$t" ] || continue
    sys=$(basename "$t" .tar)
    printf '  %-16s %6s  ' "$sys" "$(du -h "$t" | cut -f1)"
    if tar -xf "$t" -C "$DEST/roms"; then echo "ok"; else echo "FAILED"; failed+=("$sys"); fi
done
sync

# --- report -----------------------------------------------------------------
echo "=== restored ==="
du -sh "$DEST/roms" | sed 's/^/  total: /'
df -h "$DEST" | tail -1 | sed 's/^/  card:  /'

# A rom directory with no installed emulator is invisible in EmulationStation.
# Better to say so now than to have someone hunt for a missing system later.
echo "=== systems with roms but no emulator installed ==="
none=1
for d in "$DEST"/roms/*/; do
    sys=$(basename "$d")
    # ignore directories that only contain the placeholder readme
    [ -n "$(find "$d" -type f ! -name '*.txt' -print -quit 2>/dev/null)" ] || continue
    if [ ! -f "/opt/retropie/configs/$sys/emulators.cfg" ]; then
        echo "  $sys ($(du -sh "$d" | cut -f1)) - install a core for it, or it will not appear"
        none=0
    fi
done
(( none )) && echo "  (none - every system with roms has an emulator)"

if (( ${#failed[@]} )); then
    echo "!! these tars failed to extract: ${failed[*]}" >&2
    exit 1
fi
echo "=== DONE - reboot or restart EmulationStation to pick up the new systems ==="
