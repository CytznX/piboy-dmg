#!/bin/bash
# Run "$@" inside a Wayland terminal when this session has no usable tty.
#
# RetroPie's configuration UIs are dialog on a controlling terminal. Under a
# compositor there is no controlling terminal - labwc detaches from the VT - so
# dialog both fails to read input and draws somewhere nobody can see. A terminal
# emulator supplies a pty, which fixes both halves at once.
#
# --term: foot defaults to TERM=foot; forcing a terminfo that is always present
# avoids the tput/dialog breakage seen with TERM=unknown.
#
# Exit 2 (not a hang) when a terminal is needed and unavailable. That is the
# deliberate degradation policy: a caller that cannot show its UI should return
# to the frontend with an error, never sit on a black screen waiting for input
# nobody can give it.
set -u

if { : </dev/tty; } 2>/dev/null; then
    exec "$@"                       # a real tty already - nothing to do
fi

if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    exec "$@"                       # not a compositor session; caller's problem
fi

if ! command -v foot >/dev/null; then
    # "${1:-}": set -u is on, and with no arguments this line would die with
    # "unbound variable" and exit 1 - losing the exit 2 the header promises.
    echo "foot-run: no tty and no terminal emulator - refusing to run '${1:-}'" >&2
    exit 2
fi

# `--` terminates foot's own option parsing, so a command or argument that
# starts with a dash cannot be mistaken for a foot flag. Tested on foot 1.21.0:
# it already stops at the first non-option, so this is belt-and-braces for an
# arbitrary "$@", not a fix for observed breakage.
exec foot --fullscreen --font="monospace:size=10" --term=xterm-256color -- "$@"
