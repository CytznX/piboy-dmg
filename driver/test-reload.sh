#!/bin/bash
# Build xpi_gamecon and cycle it rmmod/insmod a few times, to exercise the timer
# teardown. Runs ON the handheld. Copy it next to the source and run as root:
#
#     sudo ~/piboy-src/test-reload.sh [cycles]
#
# Unloading this module is not a neutral act: it owns the pad EmulationStation
# holds open, the fan, the backlight node piboy-escaped writes, and KEY_POWER. So
# the consumers are stopped first and started again at the end, and if the new
# module will not load the script falls back to the installed one and finally to
# a reboot - because a PiBoy with no xpi_gamecon has no working controls and no
# graceful way to power off, and this may well be running over a network link
# that is about to be the only way back in.
#
# One clean cycle proves little about a race, hence the repeat.
set -u

CYCLES=${1:-5}
SRC=$(cd "$(dirname "$0")" && pwd)
KO=$SRC/xpi_gamecon.ko
LOG=/var/log/xpi-reload-test.log
# Must match dkms-setup.sh - these two have drifted apart once already.
CONSUMERS="piboy-fand piboy-escaped piboy-vold piboy-display piboy-batd"

exec > >(tee -a "$LOG") 2>&1
fail() { echo "FAILED: $*" >&2; exit 1; }

echo "=== $(date -Is)  $(uname -r)  $(uname -m) ==="

[ "$(id -u)" = 0 ] || fail "must be root"

# Something to put back if the fresh build will not load: the installed module
# if there is one, else a copy of the .ko that is working right now. (modinfo -n
# needs root to resolve - as a normal user it prints nothing, which is
# misleading if you check by hand.)
PREV=$SRC/xpi_gamecon.ko.prev
[ -f "$KO" ] && cp -a "$KO" "$PREV"
FALLBACK=$(modinfo -n xpi_gamecon 2>/dev/null || true)
FALLBACK=${FALLBACK:-$PREV}
echo "fallback module: ${FALLBACK:-NONE - a failed load means a reboot}"

echo "--- build ---"
make -C "/lib/modules/$(uname -r)/build" M="$SRC" modules || fail "build"
[ -f "$KO" ] || fail "no $KO after build"
modinfo "$KO" | grep -E '^(filename|vermagic|license)'
echo "timer symbol: $(nm -u "$KO" | grep -i timer | tr -s ' ')"

restore() {
    echo "--- restoring ---"
    lsmod | grep -q '^xpi_gamecon' || insmod "$KO" 2>/dev/null \
        || { [ -f "$FALLBACK" ] && insmod "$FALLBACK"; }
    if ! lsmod | grep -q '^xpi_gamecon'; then
        echo "NOTHING LOADED - rebooting in 10s to get back to a usable device"
        sleep 10
        systemctl reboot
        exit 1
    fi
    systemctl start $CONSUMERS 2>/dev/null
    systemctl start emulationstation 2>/dev/null || true
    echo "restored"
}
trap restore EXIT

echo "--- stopping consumers ---"
systemctl stop emulationstation 2>/dev/null || true
systemctl stop $CONSUMERS 2>/dev/null
# ES can be supervised rather than a unit; make sure nothing still holds the pad.
pkill -x emulationstation 2>/dev/null && sleep 2

# Two marks, because the two passes below read two different streams and a line
# offset taken from one is meaningless applied to the other.
MARK=$(dmesg | wc -l)
MARK_W=$(dmesg --level=err,warn | wc -l)
bad=0
for n in $(seq 1 "$CYCLES"); do
    echo "--- cycle $n/$CYCLES ---"

    # A teardown that livelocks against a re-arming timer shows up as duration,
    # so time the rmmod rather than only checking its exit status.
    t0=$(date +%s%3N)
    if ! timeout 30 rmmod xpi_gamecon; then
        echo "  rmmod FAILED or timed out after 30s  <-- this is the bug"
        bad=1; break
    fi
    t1=$(date +%s%3N)
    echo "  rmmod ok in $((t1 - t0)) ms"

    # Give any stale timer a window to fire against freed memory.
    sleep 1

    if ! insmod "$KO"; then
        echo "  insmod FAILED"
        bad=1; break
    fi
    sleep 2

    ver=$(cat /sys/kernel/xpi_gamecon/version 2>/dev/null)
    pct=$(cat /sys/class/power_supply/xpi-battery/capacity 2>/dev/null)
    mv=$(cat /sys/class/power_supply/xpi-battery/voltage_now 2>/dev/null)
    pad=$(grep -c 'PiBoy DMG Controller' /proc/bus/input/devices)
    echo "  back up: fw=$ver pad=$pad capacity=${pct}% voltage=${mv}uV"
    [ "$pad" -ge 1 ] && [ -n "$ver" ] || { echo "  driver did not come back cleanly"; bad=1; break; }
done

new=$(dmesg | tail -n +$((MARK + 1)))
echo "--- kernel messages from this run ---"
tail -60 <<<"$new"

# Two passes: the text grep catches an oops, and --level catches pr_warn lines
# whose wording contains none of those words (the power_supply parent-device
# complaint is one, and a plain text grep sails straight past it).
echo "--- anything alarming? ---"
hits=$( { grep -inE 'bug|oops|call trace|use-after-free|hung task|general protection' <<<"$new"
          dmesg --level=err,warn | tail -n +$((MARK_W + 1)); } | sort -u )
if [ -n "$hits" ]; then
    echo "$hits"
    echo "^^ review these - some may predate this change"
    bad=1
else
    echo "none"
fi

echo
[ "$bad" = 0 ] && echo "RESULT: $CYCLES cycles clean" || echo "RESULT: FAILED"
exit "$bad"
