#!/bin/bash
# Minimal RetroPie build for PiBoy DMG / Trixie aarch64 (source build, no binaries)
cd $HOME/RetroPie-Setup || exit 1
LOG=$HOME/retropie-build.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== RetroPie minimal build START $(date) ==="
echo "platform: $(uname -m)  kernel: $(uname -r)"

for pkg in retroarch lr-nestopia lr-snes9x lr-mgba emulationstation runcommand; do
    echo ""
    echo "########## $pkg — start $(date +%H:%M:%S) ##########"
    S=$(date +%s)
    if sudo ./retropie_packages.sh "$pkg"; then
        R="OK"
    else
        R="FAILED"
    fi
    E=$(date +%s)
    echo "@@@ $R: $pkg  ($(( (E-S)/60 ))m $(( (E-S)%60 ))s)"
    echo "@@@ thermal: $(vcgencmd measure_temp) fan=$(sudo cat /sys/kernel/xpi_gamecon/fan 2>/dev/null)/255 $(vcgencmd get_throttled)"
done

echo ""
echo "=== BUILD END $(date) ==="
echo "--- summary ---"
grep "^@@@ " "$LOG" | grep -E "OK:|FAILED:"
