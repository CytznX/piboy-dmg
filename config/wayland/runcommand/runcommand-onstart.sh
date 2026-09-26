#!/bin/bash
# Installed as /opt/retropie/configs/all/runcommand-onstart.sh, which runcommand
# calls before launching an emulator (its user_script hook - no patch needed,
# the call site is upstream and was simply unused here).
#
# Hide the status bar for the duration of the game. Two reasons, and the second
# is the bigger one:
#   * the bar is clutter over a game you are actually playing
#   * `layer: overlay` defeats direct scanout, so while the bar is up labwc
#     composites every frame. Measured with a libretro core running: labwc
#     ~11.0% of a core with the bar, ~3.3% without. That is ~7.7% of a core
#     handed back for the whole session.
#
# Args from runcommand are "$1"=system "$2"=emulator "$3"=rom "$4"=command;
# none of them matter here, every launch hides the bar the same way.
exec /opt/retropie/configs/all/wayland/statusbar.sh hide
