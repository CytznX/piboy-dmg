#!/bin/bash
# Runs INSIDE labwc, as the compositor's -s startup command.
W=/opt/retropie/configs/all/wayland
exec >> /var/log/piboy-wayland.log 2>&1
echo "--- startup $(date -Is) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-UNSET} ---"

# Publish the session environment for the daemons that need to reach this
# compositor from OUTSIDE it. piboy-escaped and piboy-batd run as root out of
# systemd and have no WAYLAND_DISPLAY, so a waybar they started would come up
# blind; statusbar.sh reads this file to fix that. Under XDG_RUNTIME_DIR
# because it is the one place below /run this user can write to.
printf 'WAYLAND_DISPLAY=%s\nXDG_RUNTIME_DIR=%s\nDBUS_SESSION_BUS_ADDRESS=%s\n' \
    "${WAYLAND_DISPLAY:-}" "${XDG_RUNTIME_DIR:-}" "${DBUS_SESSION_BUS_ADDRESS:-}" \
    > "${XDG_RUNTIME_DIR:-/tmp}/piboy-session.env"

# Accepts show/hide/toggle from the ROOT daemons (piboy-escaped, piboy-batd)
# over a FIFO and acts on them here, as the session user, inside the session.
# They must not start waybar themselves - see the FIFO note in statusbar.sh.
"$W/statusbar.sh" listen &

# The status bar. Must not be able to take the session down with it, so it is
# backgrounded and never waited on: if waybar dies you lose the bar, not games.
# Started through statusbar.sh so there is exactly one code path that knows how
# to launch it - the runcommand hooks and the Select hold use the same one.
"$W/statusbar.sh" show &

# Volume overlay - the bar the original PiBoy drew through dispmanx, which full
# KMS took away. Same rule: backgrounded, never fatal.
#
# mako is the renderer and must be up before anything notifies it. Started
# explicitly rather than left to D-Bus activation: activation would not inherit
# WAYLAND_DISPLAY from this session, so mako would start blind and draw nothing.
# The packaged mako.service is enabled but never runs here - it is wanted by
# graphical-session.target, which this session does not reach.
mako -c "$W/mako.ini" &
"$W/piboy-volume-osd.sh" &

# /usr/bin/emulationstation -> emulationstation.sh, whose `while true` loop
# handles /tmp/es-restart. That is what lets ES restart IN PLACE - both its own
# restart menu entry and piboy-display following the HDMI cable - without
# taking labwc down with it. Verified: ES pid changes, labwc and waybar survive.
# The wrapper also sets SDL_VIDEODRIVER=wayland itself when it sees
# WAYLAND_DISPLAY, so nothing here has to.
/usr/bin/emulationstation
echo "--- ES wrapper returned rc=$? at $(date -Is) - ending session ---"

labwc --exit 2>/dev/null || pkill -x labwc
