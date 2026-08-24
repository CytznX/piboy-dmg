#!/bin/bash
# Remove the build artifacts and dead files left on the PiBoy by the 64-bit port.
#
# Prints what it would do and exits; pass --yes to actually delete.
#
# NOT touched, deliberately:
#   ~/piboy-src              the sources of record (driver, daemons, unit files)
#   ~/ports-launchers-backup pre-edit copies of the ports launchers
#   ~/RetroPie               26G of roms and BIOS
#   the journal              58M, and the only record of the two unexplained
#                            shutdowns; persistence was hard-won, leave it alone
#   one .ko rollback         a known-good module binary, useful if a rebuild is
#                            ever impossible on the device itself
set -u
GO=0; [ "${1:-}" = "--yes" ] && GO=1
K=/lib/modules/$(uname -r)/extra
run() { if (( GO )); then eval "$@"; else echo "    would run: $*"; fi; }

if pgrep -f 'retropie_packages|build-ports.sh' >/dev/null; then
    echo "REFUSING: a RetroPie build is still running - its source tree is in"
    echo "RetroPie-Setup/tmp and clearing that now would break the build."
    exit 1
fi

before=$(df -B1 --output=used / | tail -1)
(( GO )) || echo "=== DRY RUN (pass --yes to delete) ==="

echo "=== 1. archive build logs and one-shot scripts, then remove originals ==="
cd ~ || exit 1
LOGS="build-ports build-ports.log build-frotz.log restore-roms.log rp-cores.log
      rp-cores.out rp-build.log rp-build.out rp-build2.log rp-build2.out
      retropie-build.log retropie-build2.log bitrate-sweep.sh rp-build.sh
      rp-build2.sh rp-cores.sh build-ports.sh"
present=$(for f in $LOGS; do [ -e "$f" ] && printf '%s ' "$f"; done)
if [ -n "$present" ]; then
    run "tar czf ~/piboy-src/session-logs-20260823.tar.gz $present 2>/dev/null"
    run "rm -rf $present"
else
    echo "    (already clean)"
fi

echo "=== 2. superseded driver build trees (source is saved in ~/piboy-src) ==="
for d in ~/xpi_build ~/xpi_build_psy ~/piboy-vold; do
    [ -e "$d" ] && run "rm -rf $d" || echo "    (absent: $d)"
done

echo "=== 3. stale module backups, keeping .pre-keypower as a rollback ==="
for f in "$K/xpi_gamecon.ko.nopsy" "$K/xpi_gamecon.ko.prev-subsystems"; do
    [ -e "$f" ] && run "sudo rm -f $f" || echo "    (absent: $(basename "$f"))"
done

echo "=== 4. orphan /home/pi ==="
if id pi >/dev/null 2>&1; then
    echo "    a 'pi' user EXISTS - leaving /home/pi alone"
elif [ -d /home/pi ]; then
    run "sudo rm -rf /home/pi"
else
    echo "    (absent)"
fi

echo "=== 5. dead swapfile ==="
if grep -q '/var/swap' /proc/swaps 2>/dev/null; then
    echo "    /var/swap IS IN USE - refusing to delete"
elif [ -e /var/swap ]; then
    run "sudo rm -f /var/swap"        # 2.0G; zram0 provides swap instead
else
    echo "    (absent)"
fi

echo "=== 6. RetroPie build scratch and apt cache ==="
run "sudo rm -rf ~/RetroPie-Setup/tmp/build"
run "sudo apt-get clean"

if (( GO )); then
    sync
    after=$(df -B1 --output=used / | tail -1)
    echo "=== reclaimed $(numfmt --to=iec $((before-after))) ==="
    df -h / | tail -1
else
    echo "=== dry run only - nothing was deleted ==="
fi
