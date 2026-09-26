#!/bin/bash
# Show, hide or toggle the waybar status bar.
#
#     statusbar.sh show | hide | toggle | status
#     statusbar.sh listen            (run from startup.sh, inside the session)
#
# One place owns the bar's visibility, because three unrelated things ask for
# it: the runcommand hooks (hide for a game, show on exit), the Select hold in
# piboy-escaped, and piboy-batd when the pack goes critical.
#
# ---------------------------------------------------------------------------
# WHY SIGUSR1 AND NOT START/STOP. This used to kill waybar to hide it, which
# DESTROYS its layer-shell surface - and doing that while a fullscreen emulator
# is running intermittently wedges the emulator for good. Captured live
# 2026-09-26 (/var/log/piboy-freeze/freeze-20260926-112804.*): the game sat
# blocked in ppoll on one fd with nothing queued on any wayland socket, waiting
# for a wl_surface.frame callback that never came, while labwc itself was
# perfectly healthy - still rendering, grim still working, the game's last
# frame still composited on screen. Unrecoverable by any means short of
# SIGKILL. That is labwc 0.20.1 / wlroots 0.20.2 losing track of a fullscreen
# surface when a neighbouring layer surface is destroyed.
#
# SIGUSR1 is waybar's own toggle_visibility: it UNMAPS the surface and keeps
# the client alive, which is a different path in the compositor and does not
# destroy anything. Crucially it costs nothing - measured during a Dreamcast
# game, labwc runs at 10.8% of a core with the bar visible and 3.2% with it
# SIGUSR1-hidden, the same saving killing waybar gave (3.3%). Direct scanout
# comes back either way.
#
# THE PRICE is that SIGUSR1 is a blind toggle - waybar cannot be asked whether
# it is currently visible - so the state is tracked in $STATE. Anything that
# starts waybar must reset that file, because waybar always starts visible;
# ensure_running() does. If some other hand restarts waybar the file can drift,
# and the cure is one `statusbar.sh show`.
# ---------------------------------------------------------------------------
#
# WHY THE FIFO. Two of the three callers are root-side daemons - piboy-escaped
# (User=cytzenx, but a systemd service with no session env) and piboy-batd
# (root). Neither can signal into the session correctly on its own, and the
# first version had them starting waybar directly, which put a GUI client in
# the input daemon's cgroup with its inherited file descriptors. So the session
# owns its own processes: `listen` runs inside the compositor session and the
# daemons just post a word into a FIFO.
set -u

W=/opt/retropie/configs/all/wayland
BAR_USER=cytzenx
BAR_UID=$(id -u "$BAR_USER" 2>/dev/null || echo 1000)
FIFO="/run/user/$BAR_UID/piboy-statusbar"
STATE="/run/user/$BAR_UID/piboy-statusbar.state"

# -x and -u, never -f: an -f match would also match the shell running this
# script. That mistake has cost this project a live EmulationStation session
# and two SSH connections.
bar_pid() { pgrep -x -u "$BAR_USER" waybar 2>/dev/null | head -1; }

cur_state() { [ -r "$STATE" ] && cat "$STATE" 2>/dev/null || echo up; }

ensure_running() {
    [ -n "$(bar_pid)" ] && return 0
    setsid waybar -c "$W/waybar.json" -s "$W/waybar.css" \
        >>/var/log/piboy-wayland.log 2>&1 </dev/null &
    disown 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 0.25
        [ -n "$(bar_pid)" ] && { echo up > "$STATE"; return 0; }
    done
    echo "statusbar: waybar did not start" >&2
    return 1
}

set_vis() {                       # $1 = up | down
    local want=$1 p
    ensure_running || return 1
    [ "$want" = "$(cur_state)" ] && return 0      # already there; do not toggle
    p=$(bar_pid) || return 1
    [ -z "$p" ] && return 1
    kill -USR1 "$p" 2>/dev/null && echo "$want" > "$STATE"
}

do_cmd() {
    case "$1" in
        show)   set_vis up ;;
        hide)   set_vis down ;;
        toggle) if [ "$(cur_state)" = up ]; then set_vis down; else set_vis up; fi ;;
    esac
}

# Anyone not inside the session posts the word and returns immediately; they
# must never block on the compositor.
post() {
    if [ ! -p "$FIFO" ]; then
        echo "statusbar: $FIFO missing - is the Wayland session running?" >&2
        return 1
    fi
    timeout 2 sh -c "printf '%s\n' \"\$1\" > \"\$2\"" _ "$1" "$FIFO"
}

case "${1:-status}" in
    show|hide|toggle)
        # WAYLAND_DISPLAY, *not* the uid. piboy-escaped runs as User=cytzenx -
        # the same uid as the session - but it is a systemd service with no
        # session environment, so a uid test says "act directly" and waybar
        # then starts with no display and dies with "cannot open display".
        # Having the display IS the definition of being inside the session.
        if [ -n "${WAYLAND_DISPLAY:-}" ]; then do_cmd "$1"; else post "$1"; fi ;;

    listen)
        # Runs from startup.sh, inside the session, for the life of the session.
        rm -f "$FIFO"
        mkfifo -m 0600 "$FIFO" || exit 1
        # Hold it open read-write on fd 3: a plain `< fifo` returns EOF every
        # time the last writer closes, which would end the loop after the first
        # command. With a writer of our own permanently attached, it never does.
        exec 3<>"$FIFO"
        while read -r cmd <&3; do
            case "$cmd" in
                show|hide|toggle) do_cmd "$cmd" ;;
                *) echo "statusbar: ignoring '$cmd'" >&2 ;;
            esac
        done ;;

    status)
        # Reports the tracked visibility. "down" with no waybar at all is still
        # down as far as every caller is concerned.
        [ -z "$(bar_pid)" ] && { echo down; exit 0; }
        cur_state ;;

    *)  echo "usage: $0 {show|hide|toggle|status|listen}" >&2; exit 1 ;;
esac
