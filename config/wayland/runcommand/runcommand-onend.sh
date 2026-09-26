#!/bin/bash
# Installed as /opt/retropie/configs/all/runcommand-onend.sh, called by
# runcommand after the emulator exits - including when it exits badly, which is
# why restoring the bar lives here rather than anywhere clever.
#
# statusbar.sh show is idempotent: if the bar is somehow already up (the player
# un-hid it mid-game with the Select hold, or piboy-batd forced it back on a
# critical battery) this does nothing rather than starting a second waybar.
exec /opt/retropie/configs/all/wayland/statusbar.sh show
