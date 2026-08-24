#!/bin/bash
# Build the remaining libretro cores, one package at a time.
#
# Resumable by design: each package is installed independently, and already-built
# ones are skipped on a re-run. If power is lost mid-build we keep everything that
# finished, and restarting picks up where it stopped.
cd $HOME/RetroPie-Setup || exit 1
LOG=$HOME/rp-cores.log
exec > >(tee -a "$LOG") 2>&1

# system : package     (only systems with actual ROMs in the backup)
CORES="
lr-pcsx-rearmed
lr-picodrive
lr-genesis-plus-gx
lr-stella
lr-fbneo
lr-mupen64plus-next
lr-melonds
"

echo "=== core build START $(date) ==="
for pkg in $CORES; do
    if [ -d "/opt/retropie/libretrocores/$pkg" ]; then
        echo "@@@ SKIP (already installed): $pkg"
        continue
    fi
    echo ""
    echo "########## $pkg — start $(date +%H:%M:%S) ##########"
    B=$(cat /sys/class/power_supply/xpi-battery/capacity)
    if [ "$B" -lt 15 ]; then
        echo "@@@ ABORT: battery ${B}% - refusing to continue and risk a hard cut"
        break
    fi
    S=$(date +%s)
    if sudo ./retropie_packages.sh "$pkg"; then R=OK; else R=FAILED; fi
    E=$(date +%s)
    echo "@@@ $R: $pkg ($(( (E-S)/60 ))m$(( (E-S)%60 ))s) batt=${B}% temp=$(vcgencmd measure_temp|cut -d= -f2)"
done
echo ""
echo "=== END $(date) ==="
grep -E "^@@@ (OK|FAILED|SKIP)" "$LOG" | tail -20
