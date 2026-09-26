#!/bin/bash
# Show a volume OSD over everything when the hardware wheel moves.
#
# piboy-vold already publishes the wheel position to /run/piboy-volume on every
# change, so nothing new has to read the input device - this just watches that
# file and hands the value to mako, which draws the icon, the percentage and
# the level bar (see mako.ini).
#
# inotifywait in monitor mode (-m), NOT a loop respawning it per event: the
# wheel emits ~25 events a second while turning, and spawning a process per
# event on a battery handheld is the kind of thing that shows up as idle drain.
# piboy-vold rewrites the file in place (O_TRUNC), so close_write fires and the
# watch survives; a rename would need re-watching and it does not do that.
VOL=/run/piboy-volume

# inotifywait needs an existing path, and this file will NOT exist yet: /run is
# tmpfs so it is gone every boot, and piboy-vold only creates it once the wheel
# is TURNED - its startup seed applies the volume deliberately without drawing
# or publishing. This script cannot create it either; it runs as cytzenx and
# /run is root-owned 0755. /etc/tmpfiles.d/piboy-wayland.conf creates it at
# boot, the same way and for the same reason it creates the session log.
#
# Complain rather than exit 0. The original silent `[ -e ] || exit 0` left the
# volume bar dead for an entire session at a time with nothing in any log, and
# it survived a hands-on test only because the feeder had been started by hand
# after the file happened to exist.
if [ ! -e "$VOL" ]; then
    echo "piboy-volume-osd: $VOL missing - is /etc/tmpfiles.d/piboy-wayland.conf installed?" >&2
    exit 1
fi

# Replace the live notification instead of posting a new one per step, or a
# single turn of the wheel stacks a column of them up the screen. -p prints the
# id the server assigned, -r reuses it; replacing an id that has already timed
# out just posts a fresh one, which is exactly what we want.
nid=

ICONS=/opt/retropie/configs/all/wayland/icons

show() {
    local v=$1 icon args
    # Icon tracks the level, the way every other volume OSD does. Absolute paths
    # to OUR copies, not theme names: mako's icon-path only approximates the XDG
    # lookup, and Adwaita's originals are fill="#2e3436" - invisible on a black
    # panel, which looks exactly like a missing icon. See mkvolumeicons.sh.
    # Do not substitute a Unicode speaker glyph; no font here has one (fc-list).
    if   (( v <= 0 ));  then icon=muted
    elif (( v < 34 ));  then icon=low
    elif (( v < 67 ));  then icon=medium
    else                     icon=high
    fi

    args=(-p -a piboy-volume -t 1500 -i "$ICONS/volume-$icon.svg" -h "int:value:$v")
    [[ -n $nid ]] && args+=(-r "$nid")
    nid=$(notify-send "${args[@]}" "$v%" 2>/dev/null) || nid=
}

# `read` not `cat`: bash has no cat builtin, so cat forks a process per event.
# piboy-vold writes a single line, so one read is the value.
inotifywait -q -m -e close_write "$VOL" 2>/dev/null | while read -r _; do
    read -r v < "$VOL" && [[ $v =~ ^[0-9]+$ ]] && show "$v"
done
