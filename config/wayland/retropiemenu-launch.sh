#!/bin/bash
# Launch a RetroPie configuration-menu entry with a terminal when one is needed.
#
# The retropie system in es_systems.cfg calls retropie_packages.sh directly and
# never touches runcommand, so the terminal handling patched into runcommand does
# not cover it - without this, every entry hangs the handheld on a black screen.
#
# A wrapper rather than a patch to retropiemenu.sh because sudo's env_reset has
# already stripped WAYLAND_DISPLAY by the time that script runs. Note this is NOT
# merely an environment problem: even with the env intact, retropie_packages.sh
# would still have no controlling terminal and dialog still could not draw. The
# wrapper runs before sudo, as the user, so it can open the terminal and let sudo
# happen inside it - which also keeps the GUI client out of root's hands.
#
# Full reasoning in config/wayland/README.md.
set -u

W=/opt/retropie/configs/all/wayland
exec "$W/foot-run.sh" sudo /home/cytzenx/RetroPie-Setup/retropie_packages.sh \
    retropiemenu launch "$@"
