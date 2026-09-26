#!/bin/bash
# Switch the boot path between the Wayland session and plain KMS EmulationStation.
#     sudo switch.sh wayland | kms | status
set -u
W=/opt/retropie/configs/all/wayland
A=/opt/retropie/configs/all/autostart.sh

case "${1:-status}" in
    # `|| exit 1` on the copies: without sudo, or on a read-only filesystem, cp
    # prints its own error and the next statement would otherwise announce a
    # switch that did not happen. That matters most on the kms branch, which is
    # the one you reach for when the compositor is broken and the rollback has
    # to actually take.
    wayland) cp "$W/autostart-wayland.sh" "$A" || exit 1; echo "boot path -> WAYLAND (labwc + waybar)" ;;
    kms)     cp "$W/autostart-kms.sh"     "$A" || exit 1; echo "boot path -> KMS (plain EmulationStation)" ;;
    status)
        if grep -q labwc "$A" 2>/dev/null; then echo "boot path: WAYLAND"; else echo "boot path: KMS"; fi
        exit 0 ;;
    *) echo "usage: $0 {wayland|kms|status}" >&2; exit 1 ;;
esac
echo "takes effect on the next reboot."
