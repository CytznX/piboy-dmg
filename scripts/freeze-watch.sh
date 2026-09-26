#!/bin/bash
# Watch for an emulator stalling, and dump everything the moment it does.
#
# Written because the in-game freeze could not be reproduced deliberately:
# exclusive zone (real, fixed), idle blanking, no-bar starvation, the auto-hide
# race at launch, the volume OSD over fullscreen, and a SIGKILLed predecessor
# were each tested and each came back healthy. So stop guessing and instrument.
#
# OBSERVATION ONLY. It never signals anything, never touches the compositor and
# is not installed as a service - run it from a shell while playing:
#
#     scripts/freeze-watch.sh            # watches until Ctrl-C
#
# THE DETECTOR. A stalled emulator is unambiguous by CPU: a healthy libretro
# core sits at 30% (mgba) to 50% (flycast) of a core, and a wedged one blocked
# on a frame callback sits at ~0.3%. It stays in state S and its main thread
# stays in poll_schedule_timeout either way, so process state and wchan are
# useless on their own - CPU is the signal. Three consecutive quiet samples,
# so a pause menu or a loading screen cannot trip it.
set -u

THRESH=3.0          # percent of a core, below which the emulator is doing nothing
NEED=3              # consecutive quiet samples before we call it a freeze
PERIOD=5            # seconds between samples
OUT=${1:-/var/log/piboy-freeze}

HZ=$(getconf CLK_TCK)
mkdir -p "$OUT" 2>/dev/null || { echo "cannot write $OUT" >&2; exit 1; }

cpu_of() {  # average CPU% of $1 over $PERIOD
    local p=$1 a b
    a=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null) || return 1
    sleep "$PERIOD"
    b=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null) || return 1
    awk -v a="$a" -v b="$b" -v hz="$HZ" -v s="$PERIOD" \
        'BEGIN{printf "%.1f",(b-a)/s/hz*100}'
}

emulator_pid() {
    # The libretro frontend and the common standalones, by exact name.
    pgrep -x retroarch 2>/dev/null | head -1 && return
    pgrep -x -f 'flycast|ppsspp|redream|alephone' 2>/dev/null | head -1
}

dump() {
    local pid=$1 stamp f
    stamp=$(date +%Y%m%d-%H%M%S)
    f="$OUT/freeze-$stamp.txt"
    {
        echo "=== FREEZE CAPTURED $(date -Is)  pid=$pid"
        echo "--- cmdline";      tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null; echo
        echo "--- started";      ps -o lstart= -p "$pid" 2>/dev/null
        echo "--- process state: $(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)"
        echo "--- threads (tid state wchan)"
        for t in /proc/$pid/task/*; do
            printf "  %s %s %s\n" "$(basename "$t")" \
                "$(awk '{print $3}' "$t/stat" 2>/dev/null)" \
                "$(cat "$t/wchan" 2>/dev/null)"
        done
        echo "--- what is it waiting on (fds of the main thread)"
        ls -l "/proc/$pid/fd" 2>/dev/null | grep -E 'wayland|socket|dri|input' | head -20
        echo "--- compositor"
        local lab; lab=$(pgrep -x labwc | head -1)
        echo "  labwc pid=$lab cpu=$(cpu_of "$lab")%"
        echo "  waybar running: $(pgrep -xc waybar)   mako: $(pgrep -xc mako)"
        echo "  bar: $(/opt/retropie/configs/all/wayland/statusbar.sh status 2>/dev/null)"
        echo "--- DRM"
        for c in /sys/class/drm/card*-DPI-1; do
            echo "  $c enabled=$(cat "$c/enabled" 2>/dev/null) dpms=$(cat "$c/dpms" 2>/dev/null)"
        done
        echo "  panel flags=$(cat /sys/kernel/xpi_gamecon/flags 2>/dev/null) bl_power=$(cat /sys/class/backlight/piboy/bl_power 2>/dev/null)"
        echo "--- last 40 session-log lines (xkb noise stripped)"
        grep -av 'xkbcomp\|XKEYBOARD\|Warning:\|not fatal\|keycodes above' \
            /var/log/piboy-wayland.log 2>/dev/null | tail -40
        echo "--- piboy-escaped (bar toggles, blanking) last 15"
        journalctl -u piboy-escaped -n 15 --no-pager -o short-iso 2>/dev/null
        echo "--- runcommand log"
        tail -30 /dev/shm/runcommand.log 2>/dev/null
    } > "$f" 2>&1
    WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0} \
    XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000} \
        grim "$OUT/freeze-$stamp.png" 2>/dev/null
    echo "FREEZE CAPTURED -> $f"
}

echo "watching for a stalled emulator (<${THRESH}% for $((NEED*PERIOD))s); Ctrl-C to stop"
quiet=0; last=; dumped=
while :; do
    pid=$(emulator_pid)
    if [ -z "$pid" ]; then quiet=0; last=; sleep "$PERIOD"; continue; fi
    [ "$pid" != "$last" ] && { quiet=0; dumped=; last=$pid; echo "$(date +%T) watching pid $pid"; }

    c=$(cpu_of "$pid") || { quiet=0; continue; }
    if awk -v c="$c" -v t="$THRESH" 'BEGIN{exit !(c<t)}'; then
        quiet=$((quiet + 1))
        echo "$(date +%T)  ${c}%  quiet $quiet/$NEED"
        # Dump ONCE per wedged process. Without this it re-detects every few
        # seconds and buries the first (most useful) capture under a pile of
        # identical ones - observed: 12 reports for a single freeze.
        if [ "$quiet" -ge "$NEED" ] && [ "$dumped" != "$pid" ]; then
            dump "$pid"; dumped=$pid
        fi
    else
        [ "$quiet" -gt 0 ] && echo "$(date +%T)  ${c}%  recovered"
        quiet=0
    fi
done
